// error: sqlite::rows: User has no field for column score
// Every column needs a field, by name.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let all = sqlite::statement(SCHEMA, "select id, name, score from users");
struct User { id: i64, name: u8[] }

fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    let us, ran = sqlite::rows<User>(db, all);
}
