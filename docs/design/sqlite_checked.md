# Checked SQL — Design

Status: implemented, as described here, all three layers. It extends
`docs/design/sqlite.md` (open question 3 there); `docs/stdlib.md` is the
reference. §8 records the probe of what SQLite itself can tell a compiler
about a query, which the design rests on, and §13 what implementing it
changed.

The unchecked API of `sqlite.md` finds a misspelled column, a wrong
parameter count or a row read into the wrong field when the statement runs.
This design moves those errors to compile time for SQL written in the
source, and lets the compiler write the row decoding, and optionally the
row type, that the program now writes by hand.

---

## 0. Summary

The compiler already links SQLite (the layer is in `goose` for JIT runs,
`sqlite.md` §2). So it can do what a person checking a query would do:
create the schema in an in-memory database, prepare the statement, and ask
SQLite what it found. That covers more than it might seem:

| SQLite reports, per statement | Which gives the compiler |
|---|---|
| a prepare error and its byte offset | syntax errors, unknown tables and columns, at the line and column of the literal |
| `sqlite3_bind_parameter_count` / `_name` | the number of arguments, and named parameters to match against struct fields |
| `sqlite3_column_count` / `_name` | the shape of a row |
| `sqlite3_column_decltype` / origin table and column | each direct column's declared type, and with it `NOT NULL` |
| `sqlite3_stmt_readonly` | whether the statement can change the database |

Built on that, in three layers, each usable without the next:

1. **Checked statements.** A statement declared once with
   `sqlite::statement(SCHEMA, "…")` is prepared at compile time. Errors
   point into the SQL. Calls check their argument count (§3).
2. **Rows into a struct you declare.** `sqlite::rows<User>(db, stmt, args…)`
   matches `User`'s fields to the result columns by name and checks their
   types and nullability. The compiler derives the decoder, as it derives
   `format` and `from_bytes` structurally today (§4).
3. **Generated row types.** `type UserRow = sqlite::row_type(stmt);`
   declares a struct with one field per column (§5).

The schema is declared in the program as migrations. The compiler checks
against it, and at run time the same value migrates the database and checks
that the file still matches what the program was compiled for (§2, §7).

**Recommendation:** build layers 1 and 2 first. Layer 1 alone catches most
mistakes. Layer 2 removes the hand-written decoding block, and keeps the
row's type in the source, where the program chooses `u8[..24]` or `u8[]`,
`i32` or `i64`. Layer 3 is a convenience on top, and the only one that
needs a new kind of type expression.

---

## 1. What it looks like

```goose
import std;
import sqlite;

// The schema, as migrations: checked at compile time, applied at run time.
let SCHEMA = sqlite::schema("""
    create table users(
        id integer primary key, name text not null,
        email text, score real not null default 0) strict;
    """, """
    create table posts(
        id integer primary key, user_id integer not null references users(id),
        title text not null, body text) strict;
    """);

// Statements are declared once, and prepared by the compiler.
let users_above = sqlite::statement(SCHEMA, "select id, name, email, score from users where score > ?");
let add_user    = sqlite::statement(SCHEMA, "insert into users(name, email) values (:name, :email) returning id");
let post_counts = sqlite::statement(SCHEMA, """
    select u.name as "name!", count(p.id) as "posts: integer!" from users u
    left join posts p on p.user_id = u.id group by u.id
    """);

struct User { id: i64, name: u8[], email: sqlite::Nullable<u8[]>, score: f64 }
struct NewUser { name: u8[], email: sqlite::Nullable<u8[]> }
type PostCount = sqlite::row_type(post_counts);       // { name: u8[], posts: i64 }

fn main() {
    let db, ok = sqlite::open("app.db", SCHEMA);       // migrates, then verifies (§7)
    if !ok { abort(str("open: ", sqlite::error(db))); }

    let id, added = sqlite::one<i64>(db, add_user, NewUser { name: "alice", email: sqlite::none<u8[]>() });
    let users, ok2 = sqlite::rows<User>(db, users_above, 5.0);
    let counts, ok3 = sqlite::rows<PostCount>(db, post_counts);
    for c in counts { print(c.name, ": ", c.posts); }
}
```

What the compiler rejects in it:

```
app.goose:16: error: sqlite: no such column: nam
app.goose:31: error: sqlite::rows: users_above takes 1 parameter, given 2
app.goose:31: error: sqlite::rows: column email can be NULL (users.email); declare field
    email as sqlite::Nullable<u8[]>, or select coalesce(...) as "email!" if it never is
app.goose:31: error: sqlite::rows: User has no field for column score (fields match columns
    by name: rename the field, alias the column, or leave it out of the select); a struct
    that matches it: struct User { id: i64, name: u8[], email: sqlite::Nullable<u8[]>, score: f64 }
```

(Each is a fixture in `test/sqlite/sqlite_err_*.goose`; the lines are wrapped
here.)

---

## 2. The schema

`sqlite::schema(migration, …)` takes string literals, or `let`/`const`
globals initialized with one, as `embed_shader` does (and with the same
`ConstStrLit` resolution). A file can stand in for a literal:
`sqlite::schema_file("schema/001.sql", "schema/002.sql")`, with paths
relative to the calling file.

* **At compile time** the compiler applies the migrations in order to an
  in-memory database, once per schema. A migration that fails is an error
  at its line, mapped through the literal as `embed_shader` maps shader
  errors.
* **At run time** the value is the migrations' text. `sqlite::open(path,
  SCHEMA)` applies those past the file's `PRAGMA user_version`, each in a
  transaction, and sets the version. `sqlite::migrate(db, SCHEMA)` does the
  same on an open connection.

One declaration is then the schema for both, and the compiler checks
against exactly what the database will hold. Migrations are append-only:
editing an applied one is caught by the drift check (§7), not by the
version number.

**`STRICT` tables are recommended, not required.** In an ordinary table, a
column declared `INTEGER` can hold text, so its declared type is a hint.
In a `STRICT` table it is a guarantee. The checker uses declared types
either way, and warns once per schema with a non-`STRICT` table that a
read can then fail with a conversion error (§4.2).

---

## 3. Checked statements

```goose
let users_above = sqlite::statement(SCHEMA, "select … where score > ?");
```

`sqlite::statement` is a compile-time builtin. It prepares the SQL against
the schema's database and records:

* the parameter count and names;
* each column's name, declared type, origin column and nullability (§4.3);
* whether the statement is read-only.

Its run-time value is a `sqlite::Statement { id: i32 }`: an index into a
table the compiler emits of each checked statement's SQL and expected
columns. That makes it flat, so a `thread_fn` can use a global statement.

The unchecked entry points take a statement as well as text, and with a
statement they check:

* **Argument count** against the parameter count, for every form:
  `exec(db, users_above, 5.0, 6.0)` is a compile error.
* **Named parameters** (`:name`, `@name`, `$name`) can be bound from one
  struct. `exec(db, add_user, NewUser { … })` binds each parameter from the
  field of the same name, and a parameter without a field (or a field
  without a parameter) is an error. Positional `?` are bound in order as
  before. A statement mixing the two is rejected at its declaration.
* **Statement kind**: `rows` on a statement that returns no columns is an
  error, and `exec` on a read-only one warns (it discards the rows).

**Not checked: parameter types.** SQLite does not infer them, and every
value binds to every parameter. In `where score > ?` with a text argument,
the comparison is simply false. Inferring `col op ?` would need a SQL
parser of the compiler's own (§9). Binding stays the `bind` overload set,
so the argument's own type decides how it binds.

---

## 4. Rows into a declared struct

```goose
let users, ok = sqlite::rows<User>(db, users_above, 5.0);   // User[>..], bool
let user, found = sqlite::one<User>(db, user_by_id, 7);    // User, bool
sqlite::each<User>(db, users_above, 5.0) { u => … };        // u: a User
```

`rows<T>` is a builtin, generic over `T`, that the compiler expands for
each `(T, statement)` pair into the same step loop the hand-written
`query(…) { r => User { id: int(r, 0), … } }` compiles to. It is a
structural builtin over `T`'s fields, as `format` and `from_bytes` are, not
reflection: nothing about `T` exists at run time. `one<i64>` and other
scalar `T` take a single-column statement.

### 4.1 Matching

* **By name**, case-insensitively, against the column's name as SQLite
  reports it, which is its alias if it has one. Field order does not
  matter.
* **Every column needs a field and every field a column.** A field with a
  default (`score: f64 = 0`) may lack a column. That is the escape hatch
  for computed fields. An unused column is an error, since selecting what
  the program does not read is either a mistake or waste.
* A column name that is not a Goose identifier (`count(*)`, `u.name` in
  some forms) needs an alias. The error says so and suggests one.

### 4.2 Types

| Column's declared type (affinity) | Field types accepted |
|---|---|
| INTEGER | `i64`, `i32`, `i16`, `i8`, unsigned of each, `bool` |
| REAL | `f64`, `f32` |
| TEXT | `u8[]`, `u8[varint]`, `u8[..k]` |
| BLOB | `u8[]`, `u8[varint]`, `u8[..k]`, and any `T[>..]` (`from_bytes`, verified) |
| NUMERIC, or none (an expression) | any of the above, converted by SQLite |
| any | a type with a `sqlite::read` overload |

* A value the field cannot hold is a run-time **outcome**, not a misuse.
  It comes from the database, which the program does not control. The
  cases are an integer out of `i32`'s range, a `bool` that is not 0 or 1,
  text longer than `u8[..k]`, a BLOB that `from_bytes` rejects, and a value
  of another type in a non-`STRICT` column. `rows` returns `false` with the
  column and row in `error(db)`.
* `sqlite::read` is the decoding twin of `bind` (`sqlite.md` §4.1): `fn
  sqlite::read(r: sqlite::Row, i: i32, out: Color&) -> bool` lets an enum
  field read from a TEXT or INTEGER column.
* A BLOB column read into a `Node[>..]` makes a whole relative-reference
  structure one field of a row (`sqlite.md` §10).

### 4.3 NULL

Goose has no optional scalar (stdlib_design §2.2), so a column that can be
NULL needs a field that can say so:

```goose
struct Nullable<T> { has: bool = false, v: T }    // v is T's default when !has
fn none<T>() -> Nullable<T>
fn some<T>(v: T) -> Nullable<T>
fn some(v: const u8[:]) -> Nullable<u8[]>         // text, as a field holds it
```

A non-`Nullable` field for a column that can be NULL is a compile error,
with two suggested fixes: `Nullable<T>`, or `coalesce` in the SQL. The
question is which columns can be NULL. §8 shows what SQLite can say:

* A **direct column** of a table carries its `NOT NULL` (or `PRIMARY KEY`)
  through `sqlite3_table_column_metadata`.
* **Except on the inner side of an outer join.** SQLite reports
  `posts.title` in `users left join posts` as `NOT NULL`, which is the
  table's declaration, and returns NULL for a user without posts. The
  bytecode marks the NULL-filled cursor (`NullRow`), but in the probe that
  cursor was an automatic index SQLite built on `posts`, not the table, and
  the bytecode format is documented as unstable between releases.
* An **expression** (`count(p.id)`, `score * 2`, `coalesce(…)`) has no
  declared type and no nullability at all.

So the rule is conservative:

1. A direct column is non-null if its declaration says so **and** the
   statement has no outer join (no `NullRow` in its bytecode, which is a
   reliable yes/no even though cursor mapping is not).
2. Everything else can be NULL.
3. The column's alias overrides it, in the convention sqlx uses for the
   same problem: `as "posts!"` asserts non-null, and `as "email?"`
   asserts nullable. The marker is stripped before names are matched.
   A non-null assertion that the data contradicts is caught at run time,
   as a type mismatch is.

So `count(p.id) as "posts!"` needs its `!`, though `count` never returns
NULL. The checker cannot see that: SQLite reports an aliased column by its
alias, and never says which expression produced it. Knowing `count`,
`total` and `coalesce(…, literal)` would take the SQL parser of §9.

---

## 5. Generated row types

```goose
type PostCount = sqlite::row_type(post_counts);
```

This declares a nominal struct with a field per column, in column order:
the column's name, the type from §4.2's first row for its affinity
(`i64`, `f64`, `u8[]`, `u8[]`), and `Nullable<…>` where §4.3 says the
column can be NULL. An expression column with no declared type has to say
what it is (`as "doubled: real"`), since there is no field type to infer it
from. The error asks for that.

What this costs and buys, compared with declaring the struct:

* **Buys**: no struct to keep in step with the SQL. Adding a column to the
  select adds the field.
* **Costs**: the type is not in the source. `--dump` prints it, and the
  editor support (`vscode/`) would need to show it on hover. Field types
  are the defaults (`u8[]` and never `u8[..24]`, `i64` and never `i32`). A
  schema change silently changes every use, though each one still
  typechecks against the new type.
* **Language cost**: this is a type expression computed by a builtin. `type
  X = T;` aliases exist (spec §3.2), but nothing on the right of one is
  computed today. It would be the first type-level builtin, and should
  wait until layers 1 and 2 have shown what programs want.

A smaller alternative with no language cost is for the compiler to
**print** the struct: the error for a missing or mismatched field shows
the declaration that would match, ready to paste, and
`goose --sqlite-types app.goose` prints one for every statement.

---

## 6. Where SQL stays unchecked

* **SQL built at run time** (`sqlite.md` §4.2) cannot be checked, and
  keeps the unchecked API.
* **A text literal passed straight to `exec` or `query`** could be checked
  too, but has no schema to check it against. One design would check it
  against the program's only schema when there is exactly one. That is
  left out: which schema applies to which connection should be visible in
  the source.
* **The block form** `query(db, stmt) { r => … }` with a checked statement
  checks parameters but not the block's column indices. The block is
  ordinary code, and `rows<T>` is the checked form of it.

---

## 7. At run time: drift

The compiler checked the statements against the schema as declared. The
file on disk may differ: an older program version, a hand-edited table, an
edited migration. `sqlite::open(path, SCHEMA)` therefore, after migrating:

1. Prepares every checked statement of that schema (the compiler's table,
   §3), which also fills the statement cache.
2. Compares each statement's columns, declared types and parameters with
   what the compiler recorded.
3. Fails to open, with the first difference in `error(db)`, if anything
   disagrees.

This costs one prepare per statement at open, microseconds each. It turns
every later "the database is not what the program expects" into an error
at open, the one place a program is already prepared to handle errors.

---

## 8. Probe: what SQLite reports

A C program against the system SQLite (3.51.0, macOS, which is built with
`SQLITE_ENABLE_COLUMN_METADATA`) created the §1 schema with `STRICT` tables
and prepared statements against it:

| Statement | What came back |
|---|---|
| `select id, name, email, score from users where score > ?` | 1 parameter. `id INTEGER users.id` not null, `name TEXT` not null, `email TEXT` nullable, `score REAL` not null. No `NullRow` |
| `select u.name, p.title, p.body from users u left join posts p …` | `p.title` reported **not null** (wrong for this query). `NullRow` on cursor 2, which is `OpenAutoindex … for posts`, not the `posts` table cursor (1) |
| `… count(p.id) as n, max(p.title) as latest … group by u.id` | `n` and `latest`: no declared type, no origin |
| `select name, score * 2 as doubled, coalesce(email, '') as email … where id = :id` | parameter named `:id`. Both expressions: no declared type, no origin |
| `insert … values (:name, :email) returning id` | parameters `:name`, `:email`; `id INTEGER` not null; `readonly` 0 |
| `select nam from users` | `no such column: nam`, offset 7 |
| `select id from users where` | `incomplete input`, offset -1 (no position; reported at the literal) |

Conclusions:

* Shape, parameters and declared types are reliable.
* Errors carry a byte offset for most mistakes, enough to point into the
  literal.
* Nullability is reliable only for direct columns without outer joins,
  hence §4.3's rule.
* The compiler needs `SQLITE_ENABLE_COLUMN_METADATA`, which the vendored
  build (`sqlite.md` §2) adds. Vendoring also means the compile-time
  SQLite is the run-time one, so SQL the compiler accepts is SQL the
  program can run. A system `libsqlite3` at run time would weaken that to
  the same major version.

---

## 9. Alternatives considered

* **An external generator (sqlc's model).** A tool reads `schema.sql` and
  `queries.sql` and writes a `.goose` file of structs and typed functions.
  It needs no language change, and the generated code is plain to read.
  But it is a build step Goose does not otherwise have, generated files
  drift until regenerated, and the compiler already has SQLite and
  structural builtins. `--sqlite-types` (§5) keeps its one real advantage,
  seeing the types, without a generated file.
* **A SQL parser in the compiler.** This would give parameter types and
  precise outer-join nullability. But SQLite's grammar is large, and a
  second parser that disagrees with SQLite is worse than a conservative
  rule plus `!`. It could be added later behind the same interface.
* **Reading SQLite's bytecode** for nullability (`NullRow` data flow into
  `ResultRow`). It works on today's output (§8), but EXPLAIN is
  documented as unstable, and a compiler upgrade of SQLite could silently
  change what is accepted. Only its yes/no use, "has an outer join", is in
  the design.
* **Checking without declaring statements**, `rows<User>(db, SCHEMA,
  "select …")` inline. It works the same way. Declared statements are
  preferred because they make the drift check's list (§7) and give each
  query a name to report errors under. Inline use could be allowed too.

---

## 10. What the compiler needs

As built:

* **SQLite in the compiler at check time** (`src/sqlite_check.h`). It is
  linked already for JIT runs. The catalog of schemas and statements is the
  `Ast`'s, filled from the declarations as parsed, so a statement may be
  checked before or after its schema, and whichever pass needs one first
  prepares it. A compiler built without SQLite (`GOOSE_SQLITE=OFF`) rejects
  checked SQL with "this compiler was built without SQLite, which checked
  SQL needs", and the test runner skips those tests there. It cannot skip
  the check, since `rows<T>`'s decoder comes from it.
* **Lowering, not builtins** (`src/typecheck_sqlite.h`). The checker, about
  to resolve a call named `sqlite::…`, rewrites a checked one in place into
  the library call it stands for, then resolves that. `rows<T>` becomes
  `query(db, "<sql>", args…) { r => T { f: read(r, i), … } }`, `one<T>`
  becomes `one_of(…) { r, has => if has { T {…} } else { T's default } }`,
  and `each<T>` puts a `let` of the decoded row in front of the program's
  block. The declarations become `schema_of(K)` and `statement_of(N)`, and
  `open(path, S)` becomes `open_schema(path, def, migrations, expected)`
  with the migrations and every statement's expected shape as literals.
  Everything after the checker sees ordinary calls: no pass changed.
* **No per-program table** is needed for §7. The expectations are literals
  in the `open` and `migrate` calls, which the lowering knows by scanning
  the program's globals for statements of that schema.
* **Struct binding** projects each named parameter's field. From a struct
  literal, its initializers are used directly. From a variable or a field
  path, `arg.field` is read. Another expression has to be bound to a local
  first.
* **Row types** (`row_type`) are made before name resolution: the parser
  keeps `type X = sqlite::row_type(q);` as written (so `--dump` and the
  roundtrip test see it), and resolution first prepares `q`, writes
  `struct X { … }` as source and parses it into the program. No type is
  computed by the checker.

The cost at compile time is one in-memory database per schema and one
prepare per statement, small next to compiling the program's C.

---

## 11. Open questions

1. **Namespaced builtins.** Not needed after all: the lowering recognizes
   `sqlite::` calls by their qualified name before it resolves them (§10),
   and only a program that imports the module can name them. A general
   mechanism, for `embed_shader` to move to `gfx::`, is still open.
2. **Nullable's spelling.** `sqlite::Nullable<T>` is a value type the
   standard library has so far declined to have (stdlib_design §2.2). It
   could be justified here because NULL is data, not absence, and if it
   proves general it belongs in `std`.
3. **Matching by name or by position.** By name (proposed) survives
   reordering a select and catches swapped columns of one type. By
   position needs no aliases for expressions. Names could be the default
   with a `#[positional]`-like opt-out, though Goose has no attribute
   syntax today.
4. **More than one database.** A program with two schemas declares two
   `sqlite::schema` globals, and statements name theirs. Nothing ties a
   `Db` to its schema statically, so using a statement on the wrong
   connection is caught only by the drift check's statement table, at run
   time. `Db<S>` typed by its schema would catch it at compile time, at
   the cost of a type parameter on every signature.
5. **Interaction with the unchecked `Param` arrays** of `sqlite.md` §4.2:
   probably none, since run-time SQL is unchecked by nature.

---

## 12. Implemented

All six steps of the plan:

1. `sqlite::schema` (and `schema_file`) and `sqlite::statement`:
   compile-time prepare, errors mapped into literals, argument counts
   checked at call sites, migrations and `user_version` at run time.
2. Struct binding of named parameters.
3. `rows<T>` / `one<T>` / `each<T>`: name matching, the §4.2 type table,
   `Nullable<T>`, the §4.3 rule with `!` / `?` aliases, and `sqlite::read`.
   Error messages print the matching struct.
4. The drift check at `open` and `migrate`.
5. `goose --sqlite-types`.
6. `sqlite::row_type`.

The tests are in `test/sqlite/`. `sqlite_checked` covers the three layers
end to end. `sqlite_checked_more` covers `schema_file`, `migrate`, a program
type through `sqlite::read`, each run-time failure of §4.2, drift, and a
database newer than the program. The `sqlite_err_*` fixtures have one
diagnostic each. The runner also compares `--sqlite-types` with
`expected/sqlite_types.out`.

---

## 13. What implementing it changed

* **`Nullable<T>` is `{ has, v }`**, with `none<T>()` and `some(v)`:
  `null` is a Goose keyword, which no field or function can be named. A
  concrete `some(const u8[:]) -> Nullable<u8[]>` makes `some("x")` the
  text a field holds, rather than a `Nullable` of a borrowed slice.
* **Markers combine with types**: `as "posts: integer!"` (or
  `"posts!: integer"`). A generated row type needs the type for any
  expression column, `count(*)` included (§4.3).
* **A row that fails a typed read stays in `rows`' result**, the field
  that failed left zero or empty, and `rows` returns false. The row was
  already built in place in the result, and an array of variable-size rows
  cannot drop its last element. `one<T>` and `each<T>` stop the same way.
* **`one<T>` needs a `T` with a default**, to return when there is no
  row: the struct's own field defaults or its types' (the checker's
  `DefaultValue`); the error says so where there is none.
* **Statements are globals only**, and `sqlite::statement` anywhere else
  is an error. `--sqlite-types` names each struct after its global
  (`users_above` gives `UsersAboveRow`).
* **The drift check compares declared types as text**, the same SQLite
  reporting both, and the parameter count. A file whose table changed
  shape fails to open with the first statement that differs.
