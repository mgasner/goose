// Inside a transaction block, the outer handle looks exactly like the block
// having been left: the transaction is rolled back, and the block's next use
// of its own handle aborts, saying what happened.
import std;
import sqlite;

fn main() {
    let db, ok = sqlite::open(":memory:");
    sqlite::exec(db, "create table t(v)");
    sqlite::transaction(db) { tx =>
        sqlite::exec(tx, "insert into t values (1)");
        print("the outer handle inside the block");
        sqlite::exec(db, "insert into t values (2)");
        sqlite::exec(tx, "insert into t values (3)");
        print("not reached");
        true
    };
}
