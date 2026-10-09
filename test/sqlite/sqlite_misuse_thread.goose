// A connection belongs to the thread that opened it. Its handle is a flat
// value a queue can carry, but another thread using it is a misuse.
import std;
import sqlite;

thread_fn worker() {
    let db = qget<sqlite::Db>();
    print("a connection from another thread");
    sqlite::exec(db, "select 1");
    print("not reached");
}

fn main() {
    let db, ok = sqlite::open(":memory:");
    let id = thread_spawn(worker);
    qput(db);
    thread_wait(id);
}
