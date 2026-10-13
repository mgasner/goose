// A column past the end of the row is a misuse, not a zero.
import std;
import sqlite;

fn main() {
    let db, ok = sqlite::open(":memory:");
    sqlite::each(db, "select 1, 2") { r =>
        print(sqlite::int(r, 1));
        print(sqlite::int(r, 2));
        print("not reached");
    };
}
