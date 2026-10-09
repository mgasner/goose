// error: sqlite::rows: column email can be NULL (users.email); declare field email as sqlite::Nullable<u8[]>
// A column that can be NULL needs a field that can say so.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let all = sqlite::statement(SCHEMA, "select id, name, email from users");
struct User { id: i64, name: u8[], email: u8[] }

fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    let us, ran = sqlite::rows<User>(db, all);
}
