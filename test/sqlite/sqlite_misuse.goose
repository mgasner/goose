// A call the program should not have made: a statement run on a connection
// after it was closed. The layer refuses it, and the module aborts the
// program at once with the reason.
import std;
import sqlite;

fn main() {
    let db, ok = sqlite::open(":memory:");
    sqlite::close(db);
    print("using a closed connection");
    sqlite::exec(db, "select 1");
    print("not reached");
}
