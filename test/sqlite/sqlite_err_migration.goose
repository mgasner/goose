// error: sqlite: near "tabel": syntax error (migration 2)
// A migration that does not apply is an error at its line.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null) strict;
    """, """
    alter table users add column email text;
    create tabel posts(id integer primary key);
    """);

fn main() {}
