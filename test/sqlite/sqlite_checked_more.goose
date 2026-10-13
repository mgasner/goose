// warning: sqlite::exec: count_items only reads, and exec drops its rows
// More of checked SQL: a schema from files, migrate() on a connection opened
// without one, a program's own type read through its sqlite::read overload,
// values that do not fit their fields failing the read rather than the
// program, a database file that does not match the schema the program was
// compiled with, one newer than it, and exec on a statement that only reads.
import std;
import os;
import sqlite;

let SCHEMA = sqlite::schema_file("sqlite_checked_schema.sql", "sqlite_checked_schema_2.sql");

let add_item = sqlite::statement(SCHEMA, "insert into items(name, color, qty, code) values (?, ?, ?, ?)");
let all_items = sqlite::statement(SCHEMA, "select name, color, qty, code from items order by id");
let count_items = sqlite::statement(SCHEMA, "select count(*) as \"n!\" from items");

enum Color { Red, Green, Blue }

fn sqlite::bind(s: sqlite::Stmt, i: i64, c: Color) -> bool {
    return sqlite::bind(s, i, match c { Red => "red", Green => "green", Blue => "blue" });
}
fn sqlite::read(r: sqlite::Row, i: i64, out: Color&) -> bool {
    let t = sqlite::text(r, i);
    if t == "red" { out = Color.Red; return true; }
    if t == "green" { out = Color.Green; return true; }
    if t == "blue" { out = Color.Blue; return true; }
    return false;
}

struct Item { name: u8[], color: Color, qty: i8, code: u8[..3] }

fn show(db: sqlite::Db) {
    let items, ok = sqlite::rows<Item>(db, all_items);
    print("  read ", items.len, " ok ", ok);
    if !ok { print("  ", sqlite::error(db)); }
    for it in items { print("    ", it.name, " ", it.color, " ", it.qty, " ", it.code); }
}

fn main() {
    // A connection opened without the schema, migrated afterwards.
    let db, ok = sqlite::open(":memory:");
    print("migrate ", sqlite::migrate(db, SCHEMA), ", version ", sqlite::user_version(db));
    sqlite::exec(db, add_item, "apple", Color.Red, 5, "APL");
    sqlite::exec(db, add_item, "lime", Color.Green, 12, "LIM");
    show(db);
    sqlite::exec(db, count_items);

    // Values the fields cannot hold: the read stops and fails, the program goes on.
    sqlite::exec(db, add_item, "bulk", Color.Blue, 1000, "BLK");
    show(db);
    sqlite::exec_script(db, "delete from items where name = 'bulk'; update items set code = 'LONG' where name = 'lime'");
    show(db);
    sqlite::exec_script(db, "update items set code = 'LIM', color = 'mauve' where name = 'lime'");
    show(db);
    sqlite::close(db);

    // A file whose items table is not the one the program knows.
    var name: u8[>..] = [];
    format(name, "gs_sqlite_drift_", random_seed() % 1000000000, ".db");
    let raw, ok2 = sqlite::open(name, sqlite::OpenDef { wal: false });
    sqlite::exec_script(raw, "create table items(id integer primary key, name blob, color text, qty real, code text); pragma user_version = 2;");
    sqlite::close(raw);
    let drifted, ok3 = sqlite::open(name, SCHEMA, sqlite::OpenDef { wal: false });
    print("drifted: ", ok3, " ", sqlite::code(drifted) == sqlite::SCHEMA, " ", sqlite::error(drifted));
    sqlite::close(drifted);
    // One newer than the program.
    let newer, ok4 = sqlite::open(name, sqlite::OpenDef { wal: false });
    sqlite::exec(newer, "pragma user_version = 7");
    sqlite::close(newer);
    let again, ok5 = sqlite::open(name, SCHEMA, sqlite::OpenDef { wal: false });
    print("newer: ", ok5, " ", sqlite::error(again));
    sqlite::close(again);
    print("removed ", delete_file(name));
}
