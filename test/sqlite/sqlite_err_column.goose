// error: sqlite: no such column: nam
// A misspelled column is found when the program is compiled, at the line of
// the SQL.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let q = sqlite::statement(SCHEMA, "select id, nam from users");

fn main() {}
