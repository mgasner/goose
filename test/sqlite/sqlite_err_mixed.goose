// error: sqlite::statement: the SQL mixes ? and named parameters
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let q = sqlite::statement(SCHEMA, "select id from users where id = ? and name = :name");
fn main() {}
