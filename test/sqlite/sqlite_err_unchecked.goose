// error: sqlite::rows<T>(db, q, ...) takes a checked statement
// rows<T> needs a statement the compiler checked.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

struct Id { id: i64 }
fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    let ids, ran = sqlite::rows<Id>(db, "select id from users");
}
