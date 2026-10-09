// The Goose standard library: `sqlite` (docs/stdlib.md), SQLite databases:
// open one, run SQL with bound parameters, read rows straight into Goose
// values, transactions, backups and in-memory images. The functions are C,
// the layer in src/sqlite/ over the SQLite amalgamation in third_party/sqlite,
// declared here as extern fns against the list in src/sqlite/sqlite_api.h;
// the test suite checks the two agree. docs/design/sqlite.md is the design.
//
//     let db, ok = sqlite::open("app.db");
//     sqlite::exec(db, "insert into users(name, score) values (?, ?)", "alice", 9.25);
//     let users, ok2 = sqlite::query(db, "select id, name from users where score > ?", 5.0) { r =>
//         User { id: sqlite::int(r, 0), name: sqlite::text(r, 1) }
//     };
//
// Statements are cached per connection by their SQL and never finalized by
// the program. Parameters are arguments (up to 16, each bound by the `bind`
// overload set, which a program extends with `fn sqlite::bind(s:
// sqlite::Stmt, i: i64, v: MyType) -> bool`), or a `Param` array when their
// number is known only at run time (`exec_params` and friends).
//
// Errors: what fails for reasons outside the program (a constraint, a busy
// database, SQL built at run time that does not parse) returns false, and
// code(db) and error(db) describe it. A call the program should not have
// made -- a closed connection, a column out of range, the wrong number of
// parameters, a connection used from another thread -- aborts the program,
// saying why.
//
// Transactions: `transaction(db) { tx => ...; true }` commits when the block
// yields true and rolls back when it yields false. Leaving the block early,
// with a `return` from the function around it, rolls the transaction back at
// the connection's next use. Inside the block, use the block's handle, not
// the outer one: name it `db` to make that automatic.
//
// A thread_fn may use sqlite, with connections of its own: a connection
// belongs to the thread that opened it.

namespace sqlite;

import std;

// --- constants: SQLite's result codes (primary) -----------------------------------

let OK: i32 = 0;
let ERROR: i32 = 1;
let INTERNAL: i32 = 2;
let PERM: i32 = 3;
let ABORT: i32 = 4;
let BUSY: i32 = 5;
let LOCKED: i32 = 6;
let NOMEM: i32 = 7;
let READONLY: i32 = 8;
let INTERRUPT: i32 = 9;
let IOERR: i32 = 10;
let CORRUPT: i32 = 11;
let FULL: i32 = 13;
let CANTOPEN: i32 = 14;
let PROTOCOL: i32 = 15;
let SCHEMA: i32 = 17;
let TOOBIG: i32 = 18;
let CONSTRAINT: i32 = 19;
let MISMATCH: i32 = 20;
let MISUSE: i32 = 21;
let AUTH: i32 = 23;
let RANGE: i32 = 25;
let NOTADB: i32 = 26;
let ROW: i32 = 100;
let DONE: i32 = 101;

// The type of a value in a row (column_type).
let INTEGER: i32 = 1;
let FLOAT: i32 = 2;
let TEXT: i32 = 3;
let BLOB: i32 = 4;
let NULL: i32 = 5;

// --- types -------------------------------------------------------------------------

// A connection. `token` is zero outside a transaction() block and names the
// block's transaction inside it; a handle only crosses to the layer as its
// two words.
struct Db { h: u64, token: i64 = 0 }
// A prepared statement, from the connection's cache.
struct Stmt { h: u64 }
// The current row of a statement, valid inside the block it is given to.
struct Row { h: u64 }

// How open() configures a connection. The defaults are the recommendation.
struct OpenDef {
    read_only: bool = false,
    create: bool = true,       // create the file if it is not there
    wal: bool = true,          // journal_mode=WAL, for a file database that may be written
    busy_timeout_ms: i32 = 5000,
    foreign_keys: bool = true,
    statement_cache: i32 = 128,
}

// A parameter bound as a BLOB; a `u8[:]` alone binds as TEXT.
struct Blob { bytes: const u8[:] }
// A parameter bound as NULL: `sqlite::Null {}`.
struct Null {}

// A parameter as data, for SQL whose parameter count is known only at run
// time. Text and Blob borrow their bytes: nothing is copied until SQLite
// binds them.
enum Param {
    Null,
    Int { v: i64 },
    Real { v: f64 },
    Text { s: const u8[:] },
    Blob { b: const u8[:] },
}

// A value read out of a row whatever its type, for programs that do not
// know the schema (value()). Store it variable-mode (`Value..`), so a number
// does not take the room of the longest text.
enum Value {
    Null,
    Int { v: i64 },
    Real { v: f64 },
    Text { s: u8[] },
    Blob { b: u8[] },
}

// --- the layer ---------------------------------------------------------------------

extern "gs_sql_available" fn available() -> bool;
extern "gs_sql_version_number" fn version_number() -> i64;
extern "gs_sql_version" fn version_into(out: u8[>..]&);
extern "gs_sql_misuse_count" fn misuse_count() -> i64;
extern "gs_sql_misuse_text" fn misuse_text_into(out: u8[>..]&);
extern "gs_sql_memory_used" fn memory_used() -> i64;
extern "gs_sql_set_soft_heap_limit" fn set_soft_heap_limit(bytes: i64) -> i64;

extern "gs_sql_open" fn open_raw(path: const u8[:], read_only: bool, create: bool, wal: bool,
                                 busy_timeout_ms: i32, foreign_keys: bool, statement_cache: i32) -> u64;
extern "gs_sql_is_open" fn is_open_raw(db: u64) -> bool;
extern "gs_sql_close" fn close_raw(db: u64);
extern "gs_sql_code" fn code_raw(db: u64) -> i32;
extern "gs_sql_extended_code" fn extended_code_raw(db: u64) -> i32;
extern "gs_sql_error" fn error_into(db: u64, out: u8[>..]&);
extern "gs_sql_error_offset" fn error_offset_raw(db: u64) -> i32;
extern "gs_sql_changes" fn changes_raw(db: u64, token: i64) -> i64;
extern "gs_sql_total_changes" fn total_changes_raw(db: u64, token: i64) -> i64;
extern "gs_sql_last_rowid" fn last_rowid_raw(db: u64, token: i64) -> i64;
extern "gs_sql_in_transaction" fn in_transaction_raw(db: u64, token: i64) -> bool;
extern "gs_sql_interrupt" fn interrupt_raw(db: u64);
extern "gs_sql_exec_script" fn exec_script_raw(db: u64, token: i64, sql: const u8[:]) -> bool;
extern "gs_sql_settle" fn settle_raw(db: u64, token: i64);
extern "gs_sql_backup" fn backup_raw(db: u64, token: i64, path: const u8[:]) -> bool;
extern "gs_sql_serialize" fn serialize_raw(db: u64, token: i64, out: u8[>..]&) -> bool;
extern "gs_sql_deserialize" fn deserialize_raw(db: u64, token: i64, image: const u8[:]) -> bool;
extern "gs_sql_forget" fn forget_raw(db: u64, sql: const u8[:]);
extern "gs_sql_cached_count" fn cached_count_raw(db: u64) -> i64;

extern "gs_sql_begin" fn begin_raw(db: u64, token: i64, immediate: bool) -> i64;
extern "gs_sql_end" fn end_raw(db: u64, token: i64, commit: bool) -> bool;

extern "gs_sql_prepare" fn prepare_raw(db: u64, token: i64, sql: const u8[:]) -> u64;
extern "gs_sql_param_count" fn param_count_raw(st: u64) -> i32;
extern "gs_sql_param_index" fn param_index_raw(st: u64, name: const u8[:]) -> i32;
extern "gs_sql_param_name" fn param_name_into(st: u64, i: i32, out: u8[>..]&);
extern "gs_sql_bind_i64" fn bind_i64(st: u64, i: i32, v: i64) -> bool;
extern "gs_sql_bind_f64" fn bind_f64(st: u64, i: i32, v: f64) -> bool;
extern "gs_sql_bind_text" fn bind_text(st: u64, i: i32, v: const u8[:]) -> bool;
extern "gs_sql_bind_blob" fn bind_blob(st: u64, i: i32, v: const u8[:]) -> bool;
extern "gs_sql_bind_null" fn bind_null(st: u64, i: i32) -> bool;
extern "gs_sql_step" fn step_raw(st: u64) -> i32;
extern "gs_sql_reset" fn reset_raw(st: u64);
extern "gs_sql_readonly" fn readonly_raw(st: u64) -> bool;
extern "gs_sql_sql" fn sql_into(st: u64, out: u8[>..]&);
extern "gs_sql_column_count" fn column_count_raw(st: u64) -> i32;
extern "gs_sql_column_type" fn column_type_raw(st: u64, i: i32) -> i32;
extern "gs_sql_column_i64" fn column_i64(st: u64, i: i32) -> i64;
extern "gs_sql_column_f64" fn column_f64(st: u64, i: i32) -> f64;
extern "gs_sql_column_bytes" fn column_bytes_raw(st: u64, i: i32) -> i64;
extern "gs_sql_column_text" fn column_text(st: u64, i: i32, out: u8[>..]&);
extern "gs_sql_column_blob" fn column_blob(st: u64, i: i32, out: u8[>..]&);
extern "gs_sql_column_name" fn column_name_into(st: u64, i: i32, out: u8[>..]&);
extern "gs_sql_column_decltype" fn column_decltype_into(st: u64, i: i32, out: u8[>..]&);

// --- the library -------------------------------------------------------------------

// Aborts, saying why, if the program has used sqlite wrongly.
fn check() {
    if misuse_count() > 0 {
        var text: u8[>..] = [];
        misuse_text_into(text);
        abort(str("sqlite: ", text));
    }
}

// SQLite's version, as text ("3.54.0").
fn version() -> u8[>..] {
    var text: u8[>..] = [];
    version_into(text);
    return text;
}

// --- connections -------------------------------------------------------------------

// Opens (or, by default, creates) a database: a file, ":memory:", "" for a
// private temporary file, or a "file:" URI. false if it could not be opened,
// with error(db) saying why; close() the connection either way.
fn open(path: const u8[:], def: OpenDef = OpenDef {}) -> Db, bool {
    let db = Db { h: open_raw(path, def.read_only, def.create, def.wal, def.busy_timeout_ms,
                              def.foreign_keys, def.statement_cache) };
    check();
    return db, is_open_raw(db.h);
}

// Closes a connection: its statements are finalized and an open transaction
// is rolled back. Every copy of the handle is invalid afterwards.
fn close(db: Db) {
    close_raw(db.h);
    check();
}

// The last failure on the connection: its primary code (CONSTRAINT, BUSY,
// ...), its extended code, SQLite's message, and the byte offset in the SQL
// of a syntax error (-1 when there is none). OK and "not an error" before
// any failure.
fn code(db: Db) -> i32 {
    let c = code_raw(db.h);
    check();
    return c;
}
fn extended_code(db: Db) -> i32 {
    let c = extended_code_raw(db.h);
    check();
    return c;
}
fn error(db: Db) -> u8[>..] {
    var text: u8[>..] = [];
    error_into(db.h, text);
    check();
    return text;
}
fn error_offset(db: Db) -> i64 {
    let o = error_offset_raw(db.h);
    check();
    return o;
}

// The rows the last statement changed, and all since open.
fn changes(db: Db) -> i64 {
    let n = changes_raw(db.h, db.token);
    check();
    return n;
}
fn total_changes(db: Db) -> i64 {
    let n = total_changes_raw(db.h, db.token);
    check();
    return n;
}
// The rowid of the last row inserted.
fn last_rowid(db: Db) -> i64 {
    let id = last_rowid_raw(db.h, db.token);
    check();
    return id;
}
fn in_transaction(db: Db) -> bool {
    let t = in_transaction_raw(db.h, db.token);
    check();
    return t;
}

// Makes the statement running on the connection stop with INTERRUPT.
fn interrupt(db: Db) {
    interrupt_raw(db.h);
    check();
}

// Runs SQL holding any number of statements that return no rows: a schema,
// a migration.
fn exec_script(db: Db, sql: const u8[:]) -> bool {
    let ok = exec_script_raw(db.h, db.token, sql);
    check();
    return ok;
}

// Resets every statement an each() block left mid-step, for a program that
// knows no each() is running. They are otherwise reset when next used.
fn settle(db: Db) {
    settle_raw(db.h, db.token);
    check();
}

// Copies the whole database to a file (the online backup API).
fn backup(db: Db, path: const u8[:]) -> bool {
    let ok = backup_raw(db.h, db.token, path);
    check();
    return ok;
}

// The database as one image (sqlite3_serialize), appended to `out`.
fn serialize(db: Db, out: u8[>..]&) -> bool {
    let ok = serialize_raw(db.h, db.token, out);
    check();
    return ok;
}

// Replaces the connection's database with an image from serialize(). The
// statement cache is emptied, so statements prepared before are invalid.
fn deserialize(db: Db, image: const u8[:]) -> bool {
    let ok = deserialize_raw(db.h, db.token, image);
    check();
    return ok;
}

// Drops the cached statement for this SQL, for programs that generate SQL
// text without bound.
fn forget(db: Db, sql: const u8[:]) {
    forget_raw(db.h, sql);
    check();
}

// How many statements the connection has cached.
fn cached_count(db: Db) -> i64 {
    let n = cached_count_raw(db.h);
    check();
    return n;
}

// --- transactions ------------------------------------------------------------------

// Runs F with the connection in a transaction (BEGIN IMMEDIATE, so a writer
// waits for the lock up front rather than failing at its first write): F
// gets the handle to use inside the block and yields whether to commit.
// Nested, it is a savepoint. Returns whether it committed. Leaving the block
// early rolls the transaction back at the connection's next use.
fn transaction<F>(db: Db) -> bool {
    let t = begin_raw(db.h, db.token, true);
    check();
    if t == 0 { return false; }
    let commit: bool = F(Db { h: db.h, token: t });
    let ok = end_raw(db.h, t, commit);
    check();
    return ok && commit;
}

// The same with a deferred transaction, which takes locks as it needs them:
// for a block that only reads, to see one snapshot of the database.
fn read_transaction<F>(db: Db) -> bool {
    let t = begin_raw(db.h, db.token, false);
    check();
    if t == 0 { return false; }
    let commit: bool = F(Db { h: db.h, token: t });
    let ok = end_raw(db.h, t, commit);
    check();
    return ok && commit;
}

// --- statements ----------------------------------------------------------------------

// The cached statement for this SQL, reset and unbound, or a new one; false
// if the SQL does not prepare, with error(db) saying why. For hot loops and
// named parameters: bind(), step() and the Row accessors through row().
fn prepare(db: Db, sql: const u8[:]) -> Stmt, bool {
    let s = Stmt { h: prepare_raw(db.h, db.token, sql) };
    check();
    return s, s.h != 0;
}

fn param_count(s: Stmt) -> i64 {
    let n = param_count_raw(s.h);
    check();
    return n;
}
// The index of a named parameter (":name", "@name", "$name"), 0 if there is none.
fn param_index(s: Stmt, name: const u8[:]) -> i64 {
    let i = param_index_raw(s.h, name);
    check();
    return i;
}
fn param_name(s: Stmt, i: i64) -> u8[>..] {
    var text: u8[>..] = [];
    param_name_into(s.h, i as i32, text);
    check();
    return text;
}

// Binding a parameter, numbered from 1: an overload set. A program adds its
// own types as `fn sqlite::bind(s: sqlite::Stmt, i: i64, v: T) -> bool`.
fn bind(s: Stmt, i: i64, v: i64) -> bool {
    let ok = bind_i64(s.h, i as i32, v);
    check();
    return ok;
}
fn bind(s: Stmt, i: i64, v: f64) -> bool {
    let ok = bind_f64(s.h, i as i32, v);
    check();
    return ok;
}
fn bind(s: Stmt, i: i64, v: bool) -> bool {
    let ok = bind_i64(s.h, i as i32, if v { 1 } else { 0 });
    check();
    return ok;
}
fn bind(s: Stmt, i: i64, v: const u8[:]) -> bool {
    let ok = bind_text(s.h, i as i32, v);
    check();
    return ok;
}
fn bind(s: Stmt, i: i64, v: Blob) -> bool {
    let ok = bind_blob(s.h, i as i32, v.bytes);
    check();
    return ok;
}
fn bind(s: Stmt, i: i64, v: Null) -> bool {
    let ok = bind_null(s.h, i as i32);
    check();
    return ok;
}
fn bind(s: Stmt, i: i64, p: Param) -> bool {
    return match p {
        Null => bind(s, i, Null {}),
        Int x => bind(s, i, x.v),
        Real x => bind(s, i, x.v),
        Text x => bind(s, i, x.s),
        Blob x => bind(s, i, Blob { bytes: x.b }),
    };
}

// One step: ROW with a row to read through row(s), DONE, or a failure's
// code, with error(db) saying why.
fn step(s: Stmt) -> i32 {
    let rc = step_raw(s.h);
    check();
    return rc;
}
fn row(s: Stmt) -> Row { Row { h: s.h } }
fn reset(s: Stmt) {
    reset_raw(s.h);
    check();
}
// Whether the statement cannot change the database.
fn readonly(s: Stmt) -> bool {
    let r = readonly_raw(s.h);
    check();
    return r;
}
fn sql(s: Stmt) -> u8[>..] {
    var text: u8[>..] = [];
    sql_into(s.h, text);
    check();
    return text;
}
fn column_count(s: Stmt) -> i64 {
    let n = column_count_raw(s.h);
    check();
    return n;
}
fn column_name(s: Stmt, i: i64) -> u8[>..] {
    var text: u8[>..] = [];
    column_name_into(s.h, i as i32, text);
    check();
    return text;
}
// The column's declared type in its table ("INTEGER", "TEXT"), empty for
// an expression.
fn column_decltype(s: Stmt, i: i64) -> u8[>..] {
    var text: u8[>..] = [];
    column_decltype_into(s.h, i as i32, text);
    check();
    return text;
}

// --- rows --------------------------------------------------------------------------------
// Columns are numbered from 0. SQLite converts between types as
// sqlite3_column_* do: an integer column read with real() is a float, a NULL
// reads as 0 or as empty.

fn int(r: Row, i: i64) -> i64 {
    let v = column_i64(r.h, i as i32);
    check();
    return v;
}
// int(), or `d` for NULL.
fn int_or(r: Row, i: i64, d: i64) -> i64 {
    if is_null(r, i) { return d; }
    return int(r, i);
}
fn real(r: Row, i: i64) -> f64 {
    let v = column_f64(r.h, i as i32);
    check();
    return v;
}
fn real_or(r: Row, i: i64, d: f64) -> f64 {
    if is_null(r, i) { return d; }
    return real(r, i);
}
fn bool_of(r: Row, i: i64) -> bool { int(r, i) != 0 }
// The column as text, copied out of SQLite: it fits a u8[], u8[varint] or
// u8[..k] field, or an element of an array.
fn text(r: Row, i: i64) -> u8[] {
    var t: u8[>..] = [];
    column_text(r.h, i as i32, t);
    check();
    return t;
}
// The same, appended to a builder.
fn text_into(r: Row, i: i64, out: u8[>..]&) {
    column_text(r.h, i as i32, out);
    check();
}
fn blob(r: Row, i: i64) -> u8[] {
    var b: u8[>..] = [];
    column_blob(r.h, i as i32, b);
    check();
    return b;
}
fn blob_into(r: Row, i: i64, out: u8[>..]&) {
    column_blob(r.h, i as i32, out);
    check();
}
// The size in bytes of the column's text or blob.
fn byte_count(r: Row, i: i64) -> i64 {
    let n = column_bytes_raw(r.h, i as i32);
    check();
    return n;
}
// INTEGER, FLOAT, TEXT, BLOB or NULL: the type of this row's value.
fn column_type(r: Row, i: i64) -> i32 {
    let t = column_type_raw(r.h, i as i32);
    check();
    return t;
}
fn is_null(r: Row, i: i64) -> bool { column_type(r, i) == NULL }
fn column_count(r: Row) -> i64 { column_count(Stmt { h: r.h }) }
fn column_name(r: Row, i: i64) -> u8[>..] { column_name(Stmt { h: r.h }, i) }
// The index of the column of this name, -1 if there is none.
fn column_index(r: Row, name: const u8[:]) -> i64 {
    let n = column_count(r);
    for i in n {
        if column_name(r, i) == name { return i; }
    }
    return -1;
}
// The value whatever its type.
fn value(r: Row, i: i64) -> Value.. {
    let t = column_type(r, i);
    if t == INTEGER { return Value.Int { v: int(r, i) }; }
    if t == FLOAT { return Value.Real { v: real(r, i) }; }
    if t == TEXT { return Value.Text { s: text(r, i) }; }
    if t == BLOB { return Value.Blob { b: blob(r, i) }; }
    return Value.Null;
}

// --- running statements ---------------------------------------------------------------
// exec, query, each, one and the scalar_* functions take the SQL and its
// parameters as arguments, 0 to 16 of them, generated below; the *_params
// forms take them as a Param array.

// The statement for `sql` with `n` parameters to bind, or a zero handle if
// it does not prepare. A parameter count that is not `n` is a misuse.
fn statement_for(db: Db, sql: const u8[:], n: i64) -> Stmt {
    let s = Stmt { h: prepare_raw(db.h, db.token, sql) };
    check();
    if s.h != 0 {
        let want = param_count(s);
        if want != n {
            abort(str("sqlite: the statement takes ", want, " parameter", if want == 1 { "" } else { "s" },
                      ", given ", n, ": ", sql));
        }
    }
    return s;
}

// Steps a statement to its end, ignoring rows: true if it ran.
fn run(s: Stmt) -> bool {
    var rc = step_raw(s.h);
    while rc == ROW { rc = step_raw(s.h); }
    reset_raw(s.h);
    check();
    return rc == DONE;
}

// Every row through F into a fresh array, and whether the statement ran:
// an empty one and false for a statement that did not prepare.
fn collect<F>(s: Stmt) {
    var out = [];
    if s.h == 0 { return out, false; }
    var rc = step_raw(s.h);
    check();
    while rc == ROW {
        out.push(F(Row { h: s.h }));
        rc = step_raw(s.h);
        check();
    }
    reset_raw(s.h);
    check();
    return out, rc == DONE;
}

// Each row to F, and whether the statement ran to its end.
fn each_row<F>(s: Stmt) -> bool {
    var rc = step_raw(s.h);
    check();
    while rc == ROW {
        F(Row { h: s.h });
        rc = step_raw(s.h);
        check();
    }
    reset_raw(s.h);
    check();
    return rc == DONE;
}

// The first row to F, if there is one: whether there was, and whether the
// statement ran.
fn first_row<F>(s: Stmt) -> bool, bool {
    let rc = step_raw(s.h);
    check();
    if rc == ROW { F(Row { h: s.h }); }
    reset_raw(s.h);
    check();
    return rc == ROW, rc == ROW || rc == DONE;
}

fn bind_all(s: Stmt, ps: const Param[:]) {
    for p, i in ps { bind(s, i + 1, p); }
}

fn exec_params(db: Db, sql: const u8[:], ps: const Param[:]) -> bool {
    let s = statement_for(db, sql, ps.len);
    if s.h == 0 { return false; }
    bind_all(s, ps);
    return run(s);
}
fn query_params<F>(db: Db, sql: const u8[:], ps: const Param[:]) {
    let s = statement_for(db, sql, ps.len);
    if s.h != 0 { bind_all(s, ps); }
    return collect(s, F);
}
fn each_params<F>(db: Db, sql: const u8[:], ps: const Param[:]) -> bool {
    let s = statement_for(db, sql, ps.len);
    if s.h == 0 { return false; }
    bind_all(s, ps);
    return each_row(s, F);
}
fn one_params<F>(db: Db, sql: const u8[:], ps: const Param[:]) -> bool, bool {
    let s = statement_for(db, sql, ps.len);
    if s.h == 0 { return false, false; }
    bind_all(s, ps);
    return first_row(s, F);
}

// --- generated by scripts/sqlite_arity.py: begin ---
// exec(db, sql, args...) -> bool: runs a statement, ignoring any rows.
// query(db, sql, args...) { r => T } -> T[>..], bool: every row, built by the block.
// each(db, sql, args...) { r => ... } -> bool: each row to the block.
// one(db, sql, args...) { r => ... } -> bool, bool: the first row to the block;
//     whether there was one, and whether the statement ran.
// scalar_int / scalar_real / scalar_text(db, sql, args...) -> v, bool: the first
//     column of the first row; false for no row or a failure.

// 0 parameters
fn exec(db: Db, sql: const u8[:]) -> bool {
    let s = statement_for(db, sql, 0);
    if s.h == 0 { return false; }
    return run(s);
}

fn query<F>(db: Db, sql: const u8[:]) {
    let s = statement_for(db, sql, 0);
    return collect(s, F);
}

fn each<F>(db: Db, sql: const u8[:]) -> bool {
    let s = statement_for(db, sql, 0);
    if s.h == 0 { return false; }
    return each_row(s, F);
}

fn one<F>(db: Db, sql: const u8[:]) -> bool, bool {
    let s = statement_for(db, sql, 0);
    if s.h == 0 { return false, false; }
    return first_row(s, F);
}

fn scalar_int(db: Db, sql: const u8[:]) -> i64, bool {
    let s = statement_for(db, sql, 0);
    if s.h == 0 { return 0, false; }
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real(db: Db, sql: const u8[:]) -> f64, bool {
    let s = statement_for(db, sql, 0);
    if s.h == 0 { return 0.0, false; }
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text(db: Db, sql: const u8[:]) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 0);
    if s.h == 0 { return v, false; }
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 1 parameter
fn exec<A1>(db: Db, sql: const u8[:], a1: A1) -> bool {
    let s = statement_for(db, sql, 1);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    return run(s);
}

fn query<A1, F>(db: Db, sql: const u8[:], a1: A1) {
    let s = statement_for(db, sql, 1);
    if s.h != 0 {
        bind(s, 1, a1);
    }
    return collect(s, F);
}

fn each<A1, F>(db: Db, sql: const u8[:], a1: A1) -> bool {
    let s = statement_for(db, sql, 1);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    return each_row(s, F);
}

fn one<A1, F>(db: Db, sql: const u8[:], a1: A1) -> bool, bool {
    let s = statement_for(db, sql, 1);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    return first_row(s, F);
}

fn scalar_int<A1>(db: Db, sql: const u8[:], a1: A1) -> i64, bool {
    let s = statement_for(db, sql, 1);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1>(db: Db, sql: const u8[:], a1: A1) -> f64, bool {
    let s = statement_for(db, sql, 1);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1>(db: Db, sql: const u8[:], a1: A1) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 1);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 2 parameters
fn exec<A1, A2>(db: Db, sql: const u8[:], a1: A1, a2: A2) -> bool {
    let s = statement_for(db, sql, 2);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    return run(s);
}

fn query<A1, A2, F>(db: Db, sql: const u8[:], a1: A1, a2: A2) {
    let s = statement_for(db, sql, 2);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
    }
    return collect(s, F);
}

fn each<A1, A2, F>(db: Db, sql: const u8[:], a1: A1, a2: A2) -> bool {
    let s = statement_for(db, sql, 2);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    return each_row(s, F);
}

fn one<A1, A2, F>(db: Db, sql: const u8[:], a1: A1, a2: A2) -> bool, bool {
    let s = statement_for(db, sql, 2);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    return first_row(s, F);
}

fn scalar_int<A1, A2>(db: Db, sql: const u8[:], a1: A1, a2: A2) -> i64, bool {
    let s = statement_for(db, sql, 2);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2>(db: Db, sql: const u8[:], a1: A1, a2: A2) -> f64, bool {
    let s = statement_for(db, sql, 2);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2>(db: Db, sql: const u8[:], a1: A1, a2: A2) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 2);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 3 parameters
fn exec<A1, A2, A3>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3) -> bool {
    let s = statement_for(db, sql, 3);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    return run(s);
}

fn query<A1, A2, A3, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3) {
    let s = statement_for(db, sql, 3);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3) -> bool {
    let s = statement_for(db, sql, 3);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    return each_row(s, F);
}

fn one<A1, A2, A3, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3) -> bool, bool {
    let s = statement_for(db, sql, 3);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3) -> i64, bool {
    let s = statement_for(db, sql, 3);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3) -> f64, bool {
    let s = statement_for(db, sql, 3);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 3);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 4 parameters
fn exec<A1, A2, A3, A4>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4) -> bool {
    let s = statement_for(db, sql, 4);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    return run(s);
}

fn query<A1, A2, A3, A4, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4) {
    let s = statement_for(db, sql, 4);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4) -> bool {
    let s = statement_for(db, sql, 4);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4) -> bool, bool {
    let s = statement_for(db, sql, 4);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4) -> i64, bool {
    let s = statement_for(db, sql, 4);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4) -> f64, bool {
    let s = statement_for(db, sql, 4);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 4);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 5 parameters
fn exec<A1, A2, A3, A4, A5>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5) -> bool {
    let s = statement_for(db, sql, 5);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5) {
    let s = statement_for(db, sql, 5);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5) -> bool {
    let s = statement_for(db, sql, 5);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5) -> bool, bool {
    let s = statement_for(db, sql, 5);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5) -> i64, bool {
    let s = statement_for(db, sql, 5);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5) -> f64, bool {
    let s = statement_for(db, sql, 5);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 5);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 6 parameters
fn exec<A1, A2, A3, A4, A5, A6>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6) -> bool {
    let s = statement_for(db, sql, 6);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6) {
    let s = statement_for(db, sql, 6);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6) -> bool {
    let s = statement_for(db, sql, 6);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6) -> bool, bool {
    let s = statement_for(db, sql, 6);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6) -> i64, bool {
    let s = statement_for(db, sql, 6);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6) -> f64, bool {
    let s = statement_for(db, sql, 6);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 6);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 7 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7) -> bool {
    let s = statement_for(db, sql, 7);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7) {
    let s = statement_for(db, sql, 7);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7) -> bool {
    let s = statement_for(db, sql, 7);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7) -> bool, bool {
    let s = statement_for(db, sql, 7);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7) -> i64, bool {
    let s = statement_for(db, sql, 7);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7) -> f64, bool {
    let s = statement_for(db, sql, 7);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 7);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 8 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8) -> bool {
    let s = statement_for(db, sql, 8);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8) {
    let s = statement_for(db, sql, 8);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8) -> bool {
    let s = statement_for(db, sql, 8);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8) -> bool, bool {
    let s = statement_for(db, sql, 8);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8) -> i64, bool {
    let s = statement_for(db, sql, 8);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8) -> f64, bool {
    let s = statement_for(db, sql, 8);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 8);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 9 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9) -> bool {
    let s = statement_for(db, sql, 9);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9) {
    let s = statement_for(db, sql, 9);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9) -> bool {
    let s = statement_for(db, sql, 9);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9) -> bool, bool {
    let s = statement_for(db, sql, 9);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9) -> i64, bool {
    let s = statement_for(db, sql, 9);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9) -> f64, bool {
    let s = statement_for(db, sql, 9);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 9);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 10 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10) -> bool {
    let s = statement_for(db, sql, 10);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10) {
    let s = statement_for(db, sql, 10);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
        bind(s, 10, a10);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10) -> bool {
    let s = statement_for(db, sql, 10);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10) -> bool, bool {
    let s = statement_for(db, sql, 10);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10) -> i64, bool {
    let s = statement_for(db, sql, 10);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10) -> f64, bool {
    let s = statement_for(db, sql, 10);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 10);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 11 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11) -> bool {
    let s = statement_for(db, sql, 11);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11) {
    let s = statement_for(db, sql, 11);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
        bind(s, 10, a10);
        bind(s, 11, a11);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11) -> bool {
    let s = statement_for(db, sql, 11);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11) -> bool, bool {
    let s = statement_for(db, sql, 11);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11) -> i64, bool {
    let s = statement_for(db, sql, 11);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11) -> f64, bool {
    let s = statement_for(db, sql, 11);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 11);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 12 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12) -> bool {
    let s = statement_for(db, sql, 12);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12) {
    let s = statement_for(db, sql, 12);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
        bind(s, 10, a10);
        bind(s, 11, a11);
        bind(s, 12, a12);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12) -> bool {
    let s = statement_for(db, sql, 12);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12) -> bool, bool {
    let s = statement_for(db, sql, 12);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12) -> i64, bool {
    let s = statement_for(db, sql, 12);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12) -> f64, bool {
    let s = statement_for(db, sql, 12);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 12);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 13 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13) -> bool {
    let s = statement_for(db, sql, 13);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13) {
    let s = statement_for(db, sql, 13);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
        bind(s, 10, a10);
        bind(s, 11, a11);
        bind(s, 12, a12);
        bind(s, 13, a13);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13) -> bool {
    let s = statement_for(db, sql, 13);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13) -> bool, bool {
    let s = statement_for(db, sql, 13);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13) -> i64, bool {
    let s = statement_for(db, sql, 13);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13) -> f64, bool {
    let s = statement_for(db, sql, 13);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 13);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 14 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14) -> bool {
    let s = statement_for(db, sql, 14);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14) {
    let s = statement_for(db, sql, 14);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
        bind(s, 10, a10);
        bind(s, 11, a11);
        bind(s, 12, a12);
        bind(s, 13, a13);
        bind(s, 14, a14);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14) -> bool {
    let s = statement_for(db, sql, 14);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14) -> bool, bool {
    let s = statement_for(db, sql, 14);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14) -> i64, bool {
    let s = statement_for(db, sql, 14);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14) -> f64, bool {
    let s = statement_for(db, sql, 14);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 14);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 15 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15) -> bool {
    let s = statement_for(db, sql, 15);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15) {
    let s = statement_for(db, sql, 15);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
        bind(s, 10, a10);
        bind(s, 11, a11);
        bind(s, 12, a12);
        bind(s, 13, a13);
        bind(s, 14, a14);
        bind(s, 15, a15);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15) -> bool {
    let s = statement_for(db, sql, 15);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15) -> bool, bool {
    let s = statement_for(db, sql, 15);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15) -> i64, bool {
    let s = statement_for(db, sql, 15);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15) -> f64, bool {
    let s = statement_for(db, sql, 15);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 15);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}

// 16 parameters
fn exec<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, A16>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15, a16: A16) -> bool {
    let s = statement_for(db, sql, 16);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    bind(s, 16, a16);
    return run(s);
}

fn query<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, A16, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15, a16: A16) {
    let s = statement_for(db, sql, 16);
    if s.h != 0 {
        bind(s, 1, a1);
        bind(s, 2, a2);
        bind(s, 3, a3);
        bind(s, 4, a4);
        bind(s, 5, a5);
        bind(s, 6, a6);
        bind(s, 7, a7);
        bind(s, 8, a8);
        bind(s, 9, a9);
        bind(s, 10, a10);
        bind(s, 11, a11);
        bind(s, 12, a12);
        bind(s, 13, a13);
        bind(s, 14, a14);
        bind(s, 15, a15);
        bind(s, 16, a16);
    }
    return collect(s, F);
}

fn each<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, A16, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15, a16: A16) -> bool {
    let s = statement_for(db, sql, 16);
    if s.h == 0 { return false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    bind(s, 16, a16);
    return each_row(s, F);
}

fn one<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, A16, F>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15, a16: A16) -> bool, bool {
    let s = statement_for(db, sql, 16);
    if s.h == 0 { return false, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    bind(s, 16, a16);
    return first_row(s, F);
}

fn scalar_int<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, A16>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15, a16: A16) -> i64, bool {
    let s = statement_for(db, sql, 16);
    if s.h == 0 { return 0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    bind(s, 16, a16);
    var v: i64 = 0;
    let found, ok = first_row(s) { r => v = int(r, 0); };
    return v, found && ok;
}

fn scalar_real<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, A16>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15, a16: A16) -> f64, bool {
    let s = statement_for(db, sql, 16);
    if s.h == 0 { return 0.0, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    bind(s, 16, a16);
    var v: f64 = 0.0;
    let found, ok = first_row(s) { r => v = real(r, 0); };
    return v, found && ok;
}

fn scalar_text<A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14, A15, A16>(db: Db, sql: const u8[:], a1: A1, a2: A2, a3: A3, a4: A4, a5: A5, a6: A6, a7: A7, a8: A8, a9: A9, a10: A10, a11: A11, a12: A12, a13: A13, a14: A14, a15: A15, a16: A16) -> u8[>..], bool {
    var v: u8[>..] = [];
    let s = statement_for(db, sql, 16);
    if s.h == 0 { return v, false; }
    bind(s, 1, a1);
    bind(s, 2, a2);
    bind(s, 3, a3);
    bind(s, 4, a4);
    bind(s, 5, a5);
    bind(s, 6, a6);
    bind(s, 7, a7);
    bind(s, 8, a8);
    bind(s, 9, a9);
    bind(s, 10, a10);
    bind(s, 11, a11);
    bind(s, 12, a12);
    bind(s, 13, a13);
    bind(s, 14, a14);
    bind(s, 15, a15);
    bind(s, 16, a16);
    let found, ok = first_row(s) { r => text_into(r, 0, v); };
    return v, found && ok;
}
// --- generated by scripts/sqlite_arity.py: end ---
