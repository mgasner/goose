// error: sqlite::rows: all has no column for the field nickname of User
// Every field needs a column, unless it has a default.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let all = sqlite::statement(SCHEMA, "select id, name from users");
struct User { id: i64, name: u8[], nickname: u8[] }

fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    let us, ran = sqlite::rows<User>(db, all);
}
