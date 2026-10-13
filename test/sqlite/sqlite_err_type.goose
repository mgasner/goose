// error: sqlite::rows: field name is f64, but column name is TEXT
// A field's type must be one its column reads as.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let all = sqlite::statement(SCHEMA, "select id, name from users");
struct User { id: i64, name: f64 }

fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    let us, ran = sqlite::rows<User>(db, all);
}
