# SQLite — Design

Status: implemented, as described here; `docs/stdlib.md` is the reference.
§12 records the spike that preceded it, and §15 what implementing it
changed. Checking SQL at compile time is a separate design,
`docs/design/sqlite_checked.md`.

`import sqlite;` gives a Goose program SQLite: open a database, run SQL with
bound parameters, read rows straight into Goose values, transactions,
backups. It is built the way `physics` and `gfx` are, with SQLite's
amalgamation in the place of Box3D or SDL3:

    Goose program --extern fn--> gs_sql_* (goose_sqlite, native C) --> SQLite (static)

SQLite does all the database work. The layer between it and Goose is glue
of a few hundred lines. Goose cannot call `sqlite3_*` directly, for three
reasons:

* **Pointers:** an `extern fn` cannot hold or return a pointer such as a
  `sqlite3 *` or `sqlite3_stmt *` (spec §7.10), so connections and
  statements become checked integer handles.
* **Callbacks:** C cannot call a Goose function, so `sqlite3_exec`'s
  callback, custom SQL functions and hooks are out, and rows are pulled with
  `step` instead.
* **Borrowed memory:** a column's text lives in SQLite's memory only until
  the next step, so it is copied into Goose storage through a builder
  (`gs_bld_append`).

---

## 0. Summary

| Usual binding | This design |
|---|---|
| Connection and statement objects with destructors | `Db` and `Stmt` are generation-checked **handles** into the layer's slot tables. A stale handle is a misuse that aborts, never a crash (§3) |
| Prepare, bind, step, finalize by hand | `exec` / `query` / `each` take the SQL and its parameters as arguments, or as a `Param` array when the count is known only at run time. Statements come from a **per-connection cache** keyed by SQL text and are never finalized by the program (§3, §4) |
| Row objects or reflection-driven mapping | A **trailing block** builds each row's value, and `query` constructs it **in place** in the result array (§5) |
| Exceptions or `Result` | SQLite outcomes are values: a trailing `bool`, with `code(db)` and `error(db)`. Misuse aborts (§6) |
| `with db.transaction():` / RAII guard | `transaction(db) { tx => … }`. Leaving the block early is detected through a **token** and rolled back at the connection's next use (§7) |
| One connection shared by threads | A connection belongs to the thread that opened it, and **`thread_fn`s may use the module**, unlike every other native layer (§8) |

---

## 1. What it looks like

```goose
import std;
import sqlite;

struct User { id: i64, name: u8[], score: f64 }

fn main() {
    let db, ok = sqlite::open("app.db");
    if !ok { abort(str("open: ", sqlite::error(db))); }

    sqlite::exec(db, """
        create table if not exists users(
            id integer primary key, name text not null, score real)
        """);
    sqlite::exec(db, "insert into users(name, score) values (?, ?)", "alice", 9.25);

    if !sqlite::exec(db, "insert into users(score) values (?)", 1.0) {
        print("rejected: ", sqlite::error(db));   // NOT NULL constraint failed: users.name
    }

    // Each row is built straight into `users`: no row objects, no copy.
    let users = sqlite::query(db, "select id, name, score from users where score > ?", 5.0) { r =>
        User { id: sqlite::int(r, 0), name: sqlite::text(r, 1), score: sqlite::real(r, 2) }
    };
    for u in users { print(u.id, " ", u.name, " ", u.score); }

    // Commits if the block yields true. Leaving it early rolls back.
    sqlite::transaction(db) { tx =>
        sqlite::exec(tx, "update users set score = score + 1");
        sqlite::exec(tx, "delete from users where score > ?", 100.0)
    };

    var total = 0.0;
    sqlite::each(db, "select score from users") { r => total += sqlite::real(r, 0); };

    sqlite::close(db);
}
```

Calls are qualified (`sqlite::exec(db, …)`), not `db.exec(…)`: UFCS looks
only in the caller's namespace (`docs/design/namespaces.md`). §13 has the
open question.

---

## 2. How it is built

* **SQLite** is the official amalgamation (`sqlite3.c`, `sqlite3.h`,
  public domain), vendored into `third_party/sqlite/` at a pinned release
  with a README naming the version and its SHA3 checksum. SQLite is not
  distributed as a git repository, so this is a copy and not a submodule.
* **`cmake/sqlite.cmake`** builds SQLite and the layer, `goose_sqlite`
  (`src/sqlite/`), into one static archive. As for gfx and physics, the
  archive is linked into `goose` for JIT runs, and its link inputs go to
  `build/sqlite/<config>/link-{cc,msvc}.rsp` for `goose --sqlite-link`.
  Outside Windows that means the archive plus `-lm -pthread`.
* **Compile options**, chosen for an embedded, statically linked library:
  `SQLITE_THREADSAFE=2` (multi-thread mode: connections are not shared
  across threads, which the layer enforces, §8), `SQLITE_DQS=0`,
  `SQLITE_DEFAULT_MEMSTATUS=0`, `SQLITE_DEFAULT_FOREIGN_KEYS=1`,
  `SQLITE_DEFAULT_WAL_SYNCHRONOUS=1`, `SQLITE_OMIT_LOAD_EXTENSION`,
  `SQLITE_OMIT_DEPRECATED`, `SQLITE_ENABLE_FTS5`, `SQLITE_ENABLE_RTREE`,
  `SQLITE_ENABLE_MATH_FUNCTIONS`. JSON is built in.
* **The compiler's side** follows physics: codegen notes calls with the C
  prefix `gs_sql_` in `NativeLayers`, a JIT run registers the layer's
  symbols with `tcc_add_symbol` (`AddSqliteSymbols`), and a compiler
  without the layer refuses the run. `gs_sql_` is **not** added to the
  `thread_fn` check in `src/typecheck.h` (§8).
* **Opting out**: `-DGOOSE_SQLITE=OFF` or a checkout without
  `third_party/sqlite`. Programs still typecheck and generate C, and only
  running one in-process fails: "this compiler was built without SQLite".
* **API check**: `src/sqlite/sqlite_api.h` lists every function once
  (`GS_SQL_API`) and every constant, and `test/api_check.py` checks
  `stdlib/sqlite.goose` against it, as it does for gfx and physics.

Why vendor rather than link the system `libsqlite3`: Windows has none,
versions and compile options differ between systems (and with them FTS5,
JSON and foreign-key defaults), and the JIT needs the symbols in the
compiler process. A `GOOSE_SQLITE_SYSTEM=ON` option that links the
system's copy is cheap to add later.

---

## 3. Handles and lifetimes

```goose
struct Db   { h: u64, token: i64 = 0 }   // token: §7
struct Stmt { h: u64 }
struct Row  { h: u64 }                   // only valid inside the block given it
```

* **Slot tables with generations**, as gfx and physics have. A handle is
  `generation << 32 | slot`. Every entry point checks it before SQLite sees
  it, so a statement used after `close` is a misuse and not a
  use-after-free. Handles are flat (16 bytes at most, all integer
  eightbytes), so they pass by value under the TinyCC ABI rule in
  `physics.md`.
* **The program never finalizes a statement.** `exec`, `query` and `each`
  take SQL text. The layer keeps a per-connection cache keyed by that text
  (bounded, 128 by default, LRU, never evicting a statement mid-step) and
  resets and clears a cached statement when it hands it out. The usual
  binding failure, a leaked `sqlite3_stmt` holding a lock, then needs a
  cache entry that is never reused, and `close` finalizes everything the
  connection owns.
* **`prepare(db, sql) -> Stmt, bool`** is there for hot loops and for
  named parameters. It returns the same cached statement, with `bind`,
  `step`, `reset` and the `Row` accessors on it. There is still no
  `finalize`. `forget(db, sql)` drops a cache entry for programs that
  generate SQL text without bound.
* **`close(db)`** finalizes the connection's statements, rolls back an open
  transaction, and frees the slot. The generation bump makes every copy of
  the handle stale.

---

## 4. Parameters

Parameters come in two forms. Both bind through the same `bind` overload
set, and both are checked against the statement's parameter count.

| SQL | Form | Example |
|---|---|---|
| Written in the source | **arguments**, typed at compile time | `exec(db, sql, 1, name, 2.5)` |
| Built at run time (`IN (…)` lists, query builders, bulk inserts) | **a `Param` array** | `exec_params(db, sql, ps)` |

### 4.1 Arguments

There are no variadic functions and no tuples, so each entry point is a set
of generic overloads, one per parameter count:

```goose
fn exec<A, B>(db: Db, sql: const u8[:], a: A, b: B) -> bool {
    let s, ok = prep(db, sql);
    if !ok { return false; }
    bind(s, 1, a); bind(s, 2, b);
    return run(s);
}
```

The overloads are generated, 0 to 16 parameters. The cap is not a design
limit, only the point where hand-written arguments stop being readable.
SQL that needs more parameters uses the array form.

`bind` is a **trait-like overload set** (stdlib_design §2.4): `i64`, `f64`,
`bool` (0/1), `const u8[:]` (TEXT), `Blob { bytes: const u8[:] }`
(BLOB, since a `u8[:]` alone means text), `Null`, and `Param`. Each
argument picks its overload at compile time, so binding costs no dispatch.
A generic body resolves `bind` in its definition's namespace, so a program
adds its own types by qualifying the declaration:

```goose
enum Color { Red, Green }
fn sqlite::bind(s: sqlite::Stmt, i: i64, c: Color) -> bool {
    return sqlite::bind(s, i, match c { Red => "red", Green => "green" });
}
sqlite::exec(db, "insert into t values (?)", Color.Green);
```

### 4.2 Parameter arrays

```goose
enum Param { Null, Int { v: i64 }, Real { v: f64 }, Text { s: const u8[:] }, Blob { b: const u8[:] } }

fn exec_params(db: Db, sql: const u8[:], ps: const Param[:]) -> bool
fn query_params<F>(db: Db, sql: const u8[:], ps: const Param[:])     // T[>..], bool
fn each_params<F>(db: Db, sql: const u8[:], ps: const Param[:]) -> bool
fn one_params<F>(db: Db, sql: const u8[:], ps: const Param[:])       // T, bool
```

`Param` is a fixed-mode ADT. Its `Text` and `Blob` borrow a slice, so
building the array copies no strings, and it can be a local, a `[>..]`
grown in a loop, or a slice of either. The wrapper binds each element
through `bind(s, i, p: Param)`, a `match`. The array is the shape for SQL
assembled from data:

```goose
var sql: u8[>..] = [];
var ps: sqlite::Param[>..] = [];
format(sql, "select name from users where id in (");
for id, i in ids {
    if i > 0 { sql.push(','); }
    sql.push('?');
    ps.push(sqlite::Param.Int { v: id });
}
sql.push(')');
let names = sqlite::query_params(db, sql, ps) { r => sqlite::text(r, 0) };
```

Its costs, which are why it is the second form and not the only one:

* **Every element names its variant**, since a Goose array holds one type.
  `[sqlite::Param.Int { v: 1 }, sqlite::Param.Text { s: name }]` is what
  `exec(db, sql, 1, name)` reads as.
* **A mixed literal needs a declared type.** An array literal takes its
  element type from its first element, so passed directly it fails with
  `expected a value of type sqlite::Param.Int, got sqlite::Param.Text`.
  It has to go through an annotated local, `let ps: sqlite::Param[] = [...]`
  (§12).
* **A program's own types convert** to `Param` with a function of their
  own (`fn param(c: Color) -> sqlite::Param`), instead of joining `bind`.

### 4.3 Both forms

* Text and blobs are bound `SQLITE_TRANSIENT`: SQLite copies them. Spec
  §7.10 forbids C to keep a borrowed argument past the call, and a cached
  statement outlives the call. That is one copy of each parameter, which
  is also what any binding that does not pin its arguments pays.
* `?NNN`, `:name` and `@name` parameters work through `prepare` plus
  `param_index(s, ":name") -> i64`. The convenience forms are positional.
* Binding too few or too many parameters is a misuse (§6). SQLite would
  silently bind NULL to the missing ones.

---

## 5. Rows

| Function | Returns | Use |
|---|---|---|
| `query(db, sql, args…) { r => T }` | `T[>..], bool` | every row, each built in place in the result |
| `each(db, sql, args…) { r => … }` | `bool` | stream rows without collecting them |
| `one(db, sql, args…) { r => … }` | `bool, bool`: whether there was a row, whether the statement ran | a lookup by key; the block gets the first row |
| `scalar_int` / `scalar_real` / `scalar_text` | `i64 / f64 / u8[]`, `bool` | `select count(*)` |

Each one also has a `_params` form taking a `const Param[:]` (§4.2).

The block is a static function value (spec §7.6), so `query` compiles to the
step loop it looks like, and `out.push(F(row))` constructs the user's value
directly at the end of the result (§7.3). A `User { name: u8[] }` row costs
one copy of the name out of SQLite's buffer into its final place.

Accessors on `Row`, with SQLite's own conversions (an integer column read
with `real` is converted, as `sqlite3_column_double` does):

```goose
fn int(r: Row, i: i64) -> i64          // NULL reads as 0
fn real(r: Row, i: i64) -> f64
fn text(r: Row, i: i64) -> u8[]        // copied; fits u8[], u8[varint] and u8[..k] fields
fn text_into(r: Row, i: i64, out: u8[>..]&)   // append to a builder instead
fn blob(r: Row, i: i64) -> u8[]
fn blob_into(r: Row, i: i64, out: u8[>..]&)
fn is_null(r: Row, i: i64) -> bool
fn column_type(r: Row, i: i64) -> i32  // INTEGER, FLOAT, TEXT, BLOB, NULL
fn column_count(r: Row) -> i32
fn column_name(r: Row, i: i64) -> u8[]
fn value(r: Row, i: i64) -> Value..
```

* **NULL** has no Goose value type (no `Option<T>`, stdlib_design §2.2).
  Reading NULL gives the type's zero, `is_null` tells the cases apart, and
  `int_or(r, i, default)` covers the common case.
* **`Value`** is a variable-mode ADT, for tools that do not know the schema
  (a REPL, a CSV export):
  `enum Value { Null, Int { v: i64 }, Real { v: f64 }, Text { s: u8[] }, Blob { b: u8[] } }`.
  Being variable-mode, an `Int` takes 9 bytes and not the size of the
  largest text.
* **Columns are by index.** Without reflection there is nothing to map
  names onto struct fields, and the block that builds the struct is that
  mapping. `column_index(r, "name")` exists for SQL whose shape is not
  known in advance.
* An out-of-range column index is a misuse.

---

## 6. Errors

Two classes, as in gfx and physics:

* **Outcomes**: a constraint violation, `SQLITE_BUSY`, a syntax error in
  SQL built at run time, a full disk, a corrupt file. These are values.
  Every fallible call returns `bool` last (`query` returns `T[>..], bool`),
  and `code(db) -> i32` (`CONSTRAINT`, `BUSY`, …), `extended_code(db)`,
  `error(db) -> u8[>..]` (SQLite's message) and `error_offset(db)` (where
  in the SQL a syntax error is) describe the last failure on that
  connection. To fail across many frames, use `return … from` (spec §7.9):

  ```goose
  fn load(db: sqlite::Db) -> Level, bool {
      let rooms = rooms_of(db);        // deep inside: if !ok { return default<Level>(), false from load; }
      …
  }
  ```

* **Misuse**: a stale or foreign handle, a connection used from a thread
  that did not open it, a column or parameter index out of range, the wrong
  number of parameters, a transaction handle used after its block. The
  layer refuses the call and counts it, and the Goose wrapper aborts at
  once with the layer's reason (`goose runtime error: sqlite: …`). Physics
  defers its aborts to the next `step()` because its calls are hot and
  numerous; SQLite calls are neither, and an immediate abort points at the
  line responsible.

`SQLITE_BUSY` is handled by `busy_timeout` (§9), not a callback.

---

## 7. Transactions and leaving a block early

A Goose block's `return` returns from the **enclosing named function**,
unwinding the higher-order function that called the block without running
anything after `F(…)` (spec §7.6, §7.9). There are no destructors or
`defer` either. So a naive

```goose
fn transaction<F>(db: Db) -> bool { exec(db, "begin"); let c = F(db); exec(db, if c { "commit" } else { "rollback" }); c }
```

leaves the transaction open when the block returns early. Every later
statement on the connection then runs inside it, and is lost when something
eventually rolls back. The design detects this instead:

* `transaction(db) { tx => … }` asks the layer to begin, receives a
  nonzero **token**, and gives the block `tx`, a `Db` carrying that token.
  The block yields `true` to commit and `false` to roll back.
* Every entry point passes its `Db`'s token. While a transaction is
  outstanding, a call carrying any other token comes from **outside the
  block**. The only way that happens is the block having been left (or
  §7.1's mistake), so the layer **rolls the transaction back first** and
  then runs the call in autocommit, as the program meant.
* `transaction(tx) { inner => … }` nests as a `SAVEPOINT`, with a token of
  its own: each level has one. A call carrying an outer level's token while
  inner levels are open means their blocks were left, so those savepoints
  are rolled back and the outer transaction goes on. That covers an inner
  transaction in a function of its own, which a `return` leaves while the
  outer block continues.
* `transaction` itself ends with the token it started with. If it is no
  longer current, the transaction was already rolled back underneath it,
  which is a misuse.

The resulting semantics are those of an exception leaving a Python
`with db:`: **leaving early means rollback**. The rollback is lazy: it
happens at the connection's next use, or at `close`. Until then the
connection keeps whatever locks the transaction took, which matters only
to other connections to the same file. `sqlite::settle(db)` forces it, for
a program that leaves early and then waits.

### 7.1 The one mistake this cannot tell from leaving

Using the **outer** `db` inside the block, instead of `tx`, looks exactly
like having left it. The layer rolls back, and the block's next use of `tx`
(or the commit at its end) carries a dead token and aborts with "the
transaction was rolled back because `db` was used inside its
`transaction()` block; use the block's handle". The mistake is never
silent. Naming the block parameter `db` (`transaction(db) { db => … }`)
shadows the outer handle and makes it impossible; the documentation will
recommend that spelling.

### 7.2 Streaming cursors

`each` has the same problem in a milder form. A block that returns early
leaves its statement mid-step, holding a read snapshot. The statement is
reset when the cache next hands it out, at `settle`, at the end of the next
transaction, and at `close`. In WAL mode (the default, §9) an open read
snapshot does not block writers. It only stops a checkpoint from getting
past it. `query` and `one` reset before returning, so they leave nothing
open unless their row block itself returns early.

Both problems would go away with a language feature: a way for a
higher-order function to run code when the block it called is left by
`return … from`. §13 has it as the first open question. The token scheme
does not depend on it.

---

## 8. Threads

Every other native layer is main-thread only, because its library is (SDL
windowing, Box3D world creation). SQLite is not, and databases are a
natural thing to give a worker, so **`thread_fn`s may use `sqlite`**:

* The layer's slot tables are process-wide and guarded by a mutex held only
  for a handle lookup. SQLite's own locking (`SQLITE_THREADSAFE=2`)
  covers the rest.
* **A connection belongs to the thread that opened it.** Handles are flat
  `u64`s, so a program could send one through a queue (spec §11.2). Using
  it from another thread is a misuse. Multi-thread mode makes sharing a
  connection unsafe, and the rule keeps the language's "nothing shared"
  model true of databases too.
* The idiom is a connection per worker. With WAL that means any number of
  readers and one writer at a time, `busy_timeout` serializing writers.
  A single writer worker fed by a typed queue of flat commands is the
  pattern for write-heavy programs, and a sample will show it.

---

## 9. Opening

```goose
struct OpenDef {
    read_only: bool = false,
    create: bool = true,
    wal: bool = true,              // journal_mode=WAL on a file database
    busy_timeout_ms: i32 = 5000,
    foreign_keys: bool = true,
    statement_cache: i32 = 128,
}
fn open(path: const u8[:], def: OpenDef = OpenDef {}) -> Db, bool
```

As in physics, the definition struct's field defaults are the
recommendation, so `sqlite::open("app.db")` is a well-configured
connection. `":memory:"` and `""` (a private temporary file) work as in
SQLite, and `wal` is ignored for them. Pragmas not covered by `OpenDef` are
`exec(db, "pragma …")`.

Also exposed, since none of them needs a callback: `changes`,
`total_changes`, `last_rowid`, `in_transaction`, `interrupt` (from the
connection's own thread, between steps), `backup(src, dst_path) -> bool`
(the online backup API, run to completion), `serialize(db, out: u8[>..]&)`
and `deserialize(db, bytes)` for in-memory images, `version()`,
`memory_used()` and `set_soft_heap_limit()`.

---

## 10. Memory

SQLite allocates for itself: page cache, statements, schema. That memory is
outside Goose's stacks, as Box3D's is, and `set_soft_heap_limit` bounds it.
**No Goose value ever points into it.** Every column is copied into Goose
storage before the call that read it returns, and every parameter is copied
by SQLite when bound. So the stack invariant and spec §9 hold, and stepping
a statement or closing a connection cannot invalidate a Goose reference.

A program's data can go into SQLite whole. A structure built from relative
references (spec §3.9) is already position-independent bytes, so `to_bytes`
gives a BLOB and `from_bytes` verifies it on the way back
(`docs/design/serialization.md`). A level, a scene graph or a parse tree
then becomes one row, with no schema to write for it.

---

## 11. Not exposed

Everything that needs C to call Goose: custom SQL functions, aggregates and
collations, the commit, update and WAL hooks, the authorizer, the progress
handler, and custom busy handlers (`busy_timeout` covers the common case).
Also left out: `sqlite3_exec` with a callback (`exec_script(db, sql)` runs
several statements that return no rows), loadable extensions, virtual
tables written in Goose, the session extension, UTF-16 APIs, and the
deprecated APIs. Incremental BLOB I/O (`sqlite3_blob_*`) is not a callback
problem and is the first follow-up.

---

## 12. Spike: what was checked

A toy layer (about 120 lines of C over macOS's system `libsqlite3`, passed
with `--include` and linked with `-lsqlite3`) and a cut-down
`stdlib/sqlite.goose` (open, close, `exec` and `query` with 0 to 2
parameters, `exec_params`, `each`, `transaction`, the `Row` accessors,
tokens) were built `--standalone` with the current compiler and run:

* **Generic parameter binding works** for string literals, a `u8[]`
  variable, integer and float literals, through the `bind` overload set.
* **Rows build in place**: the `query` block above produced a `User[>..]`
  whose `u8[]` names came straight from SQLite.
* **SQLite errors come back as values**: `NOT NULL constraint failed:
  users.name` and `incomplete input` printed from `error(db)`.
* **Early exit from a transaction**: a `return false` inside the block left
  the transaction open (`in_transaction` true). The next `query` from
  outside carried token 0, the layer rolled back first, the row count was
  the pre-transaction one, and `in_transaction` was false. The committed
  path afterwards committed both inserts.
* **Extension**: a user's `fn sqlite::bind(s, i, c: Color)` was picked up
  by the library's generic `exec`.
* **Misuse**: `exec` on a closed handle aborted with
  `goose runtime error: sqlite: misuse (stdlib/sqlite.goose:40)`.
* **Parameter arrays**: `exec_params` took a `const Param[:]` with
  `Text` borrowing a `u8[]` variable, and bound an `IN (?,?,?)` list built
  from a run-time array into a `Param[>..]`.

What the spike changed in the design:

* `text` returns **`u8[]`, not `u8[>..]`**. A block returning a resizable
  cannot be collected (`array elements may not be resizable`), so
  `query(db, sql) { r => sqlite::text(r, 0) }` failed with the
  stdlib-style `u8[>..]` result. `u8[]` lands in the same fields and also
  works as an element. `text_into` keeps the builder form.
* An array of such rows is iterated, not indexed (spec §3.3). `one` and
  the `scalar_*` functions exist so a single-row read does not need an
  array at all.
* A mixed `Param` literal passed straight to `exec_params` failed
  (`expected a value of type sqlite::Param.Int, got sqlite::Param.Text`).
  The literal takes its type from its first element, so it needs an
  annotated local (§4.2, §13).
* Calls are qualified: `db.exec(…)` did not resolve (§13).
* A JIT run needs the real layer registered with TinyCC. The spike's
  `--include` header was compiled against the host's headers, which TinyCC
  does not have.

---

## 13. Open questions

1. **Exit hooks for higher-order functions.** If a function could run
   code when a block it called is left by `return … from`, a "finally" for
   the hidden propagate path that already exists (spec §7.9), `transaction`
   and `each` could clean up immediately and §7's tokens would only catch
   misuse. gfx render passes and ui begin/end pairs have the same shape.
   This is narrower than the cleanup question in
   `owning_dynamic_data.md`: it involves no resource values, copies or
   aggregates, only one function's frame.
2. **UFCS into a value's namespace.** `db.exec(sql)` instead of
   `sqlite::exec(db, sql)`. `namespaces.md` leaves associated-namespace
   lookup for later. This library and physics would both read better with
   it.
3. **Compile-time SQL checking**, and row decoding and row types derived
   from it: explored in `docs/design/sqlite_checked.md`. A natural second
   step, not part of v1.
4. **Accessor names.** `int` / `real` / `text` follow SQLite's type names,
   while `i64` / `f64` / `str` would follow Goose's. The proposal picks
   SQLite's because the SQL beside them uses those words.
5. **An implicit conversion into `Param`.** If an array literal took its
   element type from its destination, or a program could declare that a
   type converts to an ADT, `exec_params(db, sql, [1, name, 2.5])` would
   be as short as the argument form. Then a single array form could
   replace the generated overloads.

---

## 14. Plan

1. Vendor the amalgamation into `third_party/sqlite/` and add
   `cmake/sqlite.cmake`, the opt-out, the link files and `--sqlite-link`.
2. Write the layer (`src/sqlite/`): handle tables with generations and the
   thread owner, the statement cache, bind/step/column, error state,
   tokens, `OpenDef`, backup and serialize. `sqlite_api.h` and
   `api_check.py` coverage.
3. Hook up the compiler: the `gs_sql_` prefix in `NativeLayers`,
   `AddSqliteSymbols` for the JIT, the "built without SQLite" refusal.
4. Write `stdlib/sqlite.goose` from the spike outward, and document it in
   `docs/stdlib.md`.
5. Add tests in `test/sqlite/`, AOT at -O0 and -O2 and through TinyCC:
   types and NULLs, parameters 0 to 16 and user `bind` overloads, `Param` arrays (built in loops, borrowed text, run-time `IN` lists), `query` /
   `each` / `one`, errors and codes, transactions (commit, rollback, nested
   savepoints, early exit, the outer-handle mistake aborting), the
   statement cache under eviction, misuse aborts (stale handle, wrong
   thread, index range, parameter count), two `thread_fn` workers on one
   WAL file, backup and serialize round trips, and a `from_bytes` BLOB
   round trip.
6. Add `samples/NN_sqlite_*.goose`: a small inventory tool, and the
   single-writer worker fed by a queue.

---

## 15. What implementing it changed

* **`one` returns `bool, bool`**, whether there was a row and whether the
  statement ran, and gives the row to its block. A generic function cannot
  name its block's result type, so it has no `T` to return when there is
  no row. A checked statement knows the type (`sqlite_checked.md`), and its
  `one<T>` returns the row.
* **Indices are `i64`** and `bind` returns `bool`, so `sqlite::int(r, i)`
  takes a loop variable without a cast. The layer still takes `i32`.
* **Each nesting level has its own token** (§7). An inner transaction left
  early is rolled back alone when the outer block next uses the
  connection.
* **`transaction` is `BEGIN IMMEDIATE`**: a writer waits for the write lock
  up front, under `busy_timeout`, instead of failing on its first write
  when another connection got there first. `read_transaction` is the
  deferred form, for a consistent snapshot. A transaction begun with SQL
  (`exec(db, "begin")`) stays SQL's: `transaction()` inside one is a
  misuse, since the tokens could not account for it.
* **The layer keeps each connection's last failure itself.** A failed
  `COMMIT` is rolled back so the connection is in autocommit after the
  block whatever happened, and that rollback would otherwise replace
  SQLite's message for the commit.
* **A statement is one statement.** SQL with a second statement after the
  first fails to prepare, with its offset, instead of SQLite's silent
  ignoring of the rest. `exec_script` runs several.
* **Nested `each` over the same SQL** gets a second cached statement, so
  the cache may hold several copies of one SQL. Eviction drops the least
  recently used statement that is not mid-step, and only then one that is.
  That one is an `each` left early, or an outer `each` that has not stepped
  for a cache's worth of statements, whose next step is then a misuse
  rather than a wrong row.
* **Builders.** The layer appends to a Goose `u8[>..]` the way the
  runtime's `gs_bld_append` does, from its own declaration of the
  header-and-stack pair (`gs_sql_builder`). `api_check.py` maps `u8[>..]&`
  to it.
* **The argument-count overloads are generated** by
  `scripts/sqlite_arity.py` into a marked region of `stdlib/sqlite.goose`,
  0 to 16 parameters for `exec`, `query`, `each`, `one` and the three
  scalars. The test suite checks the region is current.
* **Misuse messages name the layer's entry point**: `exec` on a closed
  connection reports `sqlite::prepare`, the call that found the handle
  stale. The abort's location is the module's `check()`, since the C side
  has no Goose line to report.
* **Platforms**: built and tested on macOS (Apple clang). The JIT does not
  run on macOS in this repository (TinyCC has no system headers there), so
  the TinyCC runs of these tests happen on the Linux and Windows CI.
