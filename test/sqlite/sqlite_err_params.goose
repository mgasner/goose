// error: sqlite::exec: by_score takes 1 parameter, given 2
// The arguments are counted against the statement's parameters.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let by_score = sqlite::statement(SCHEMA, "select id from users where score > ?");

fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    sqlite::exec(db, by_score, 1.0, 2.0);
}
