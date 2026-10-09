// The wrong number of parameters is a misuse, not a NULL bound to the rest.
import std;
import sqlite;

fn main() {
    let db, ok = sqlite::open(":memory:");
    print("two parameters, one given");
    sqlite::exec(db, "select ? + ?", 1);
    print("not reached");
}
