// error: sqlite::row_type(stats): column n is an expression, which has no declared type
// A generated row type needs an expression column to say its type.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let stats = sqlite::statement(SCHEMA, "select count(*) as n from users");
type Stats = sqlite::row_type(stats);

fn main() {}
