// Transactions: committed and rolled back by what the block yields, nested
// as savepoints with an inner one rolled back alone, left early -- from the
// outer block and from an inner one in a function of its own -- and rolled
// back at the connection's next use, a failing statement inside one, and a
// read transaction.
import std;
import sqlite;

fn count(db: sqlite::Db) -> i64 {
    let n, found = sqlite::scalar_int(db, "select count(*) from t");
    return n;
}

fn add(db: sqlite::Db, v: i64) { sqlite::exec(db, "insert into t values (?)", v); }

// Leaves the transaction block by returning from this function.
fn add_unless(db: sqlite::Db, v: i64, stop: bool) -> bool {
    sqlite::transaction(db) { db =>
        add(db, v);
        if stop { return false; }
        add(db, v + 1);
        true
    };
    return true;
}

// An inner transaction left early while the outer one goes on.
fn inner_left(db: sqlite::Db) {
    sqlite::transaction(db) { db =>
        add(db, 500);
        return;
        true
    };
}

fn main() {
    let db, ok = sqlite::open(":memory:");
    sqlite::exec(db, "create table t(v integer)");

    print("commit: ", sqlite::transaction(db) { db => add(db, 1); add(db, 2); true }, " count ", count(db));
    print("rollback: ", sqlite::transaction(db) { db => add(db, 3); false }, " count ", count(db));
    print("in transaction: ", sqlite::in_transaction(db));

    // Nested: the inner one rolled back alone, then the outer committed.
    sqlite::transaction(db) { db =>
        add(db, 10);
        print("inner: ", sqlite::transaction(db) { db => add(db, 11); print("  inside: ", count(db)); false });
        print("  after inner: ", count(db), " in transaction ", sqlite::in_transaction(db));
        print("inner 2: ", sqlite::transaction(db) { db => add(db, 12); true });
        true
    };
    print("nested committed, count ", count(db));

    // Left early from the outer block: rolled back at the next use.
    add_unless(db, 20, true);
    print("left early: in transaction ", sqlite::in_transaction(db), " count ", count(db));
    add_unless(db, 30, false);
    print("not left: count ", count(db));

    // An inner block left early: its savepoint is rolled back when the outer
    // block next uses the connection, and the outer one commits.
    sqlite::transaction(db) { db =>
        add(db, 40);
        inner_left(db);
        add(db, 41);
        true
    };
    let vs = sqlite::query(db, "select v from t where v >= 40 order by v") { r => sqlite::int(r, 0) };
    print("after inner left early: ", vs);

    // A statement failing inside: the block decides.
    sqlite::exec(db, "create table u(v integer not null)");
    let committed = sqlite::transaction(db) { db =>
        let a = sqlite::exec(db, "insert into u values (1)");
        let b = sqlite::exec(db, "insert into u values (null)");
        print("  a ", a, " b ", b, ": ", sqlite::error(db));
        a && b
    };
    let un, f = sqlite::scalar_int(db, "select count(*) from u");
    print("committed ", committed, ", rows in u ", un);

    // A read transaction sees one snapshot.
    sqlite::read_transaction(db) { db =>
        print("read: ", count(db), " in transaction ", sqlite::in_transaction(db));
        true
    };

    // A transaction begun with SQL stays SQL's to end.
    sqlite::exec(db, "begin");
    add(db, 99);
    sqlite::exec(db, "rollback");
    print("sql transaction rolled back, count ", count(db));
    sqlite::close(db);
}
