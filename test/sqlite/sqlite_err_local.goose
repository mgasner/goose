// error: sqlite::statement declares a global
// Statements are declared once, as globals.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

fn main() {
    let q = sqlite::statement(SCHEMA, "select id from users");
}
