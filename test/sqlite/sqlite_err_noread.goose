// error: declare fn sqlite::read(r: sqlite::Row, i: i64, out: Color&) -> bool to read it
// A field of the program's own type needs a read overload.
import std;
import sqlite;

let SCHEMA = sqlite::schema("""
    create table users(id integer primary key, name text not null, email text, score real not null) strict;
    """);

let colors = sqlite::statement(SCHEMA, "select name as color from users");
enum Color { Red, Green }
struct C { color: Color }
fn main() {
    let db, ok = sqlite::open(":memory:", SCHEMA);
    let cs, ran = sqlite::rows<C>(db, colors);
}
