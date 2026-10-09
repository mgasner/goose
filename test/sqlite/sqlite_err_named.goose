// error: sqlite::exec: NewUser has no field for the parameter :email of add
// A struct binds named parameters by field, and needs one for each.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let add = sqlite::statement(SCHEMA, "insert into users(name, email, score) values (:name, :email, :score)");
struct NewUser { name: u8[], score: f64 }

fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    sqlite::exec(db, add, NewUser { name: "a", score: 1.0 });
}
