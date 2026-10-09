// thread_fns using sqlite, each with a connection of its own to one WAL
// file: four writers taking turns through busy_timeout and BEGIN IMMEDIATE,
// readers alongside, and every row there at the end.
import std;
import os;
import sqlite;

struct Done { worker: i64, rows: i64 }
struct Path { text: u8[..64] }

thread_fn writer(w: i64, path: Path) {
    let db, ok = sqlite::open(path.text);
    var written = 0;
    for batch in 20 {
        sqlite::transaction(db) { db =>
            for i in 10 {
                if sqlite::exec(db, "insert into t(worker, n) values (?, ?)", w, batch * 10 + i) { written += 1; }
            }
            true
        };
    }
    sqlite::close(db);
    qput(Done { worker: w, rows: written });
}

thread_fn reader(path: Path) {
    let db, ok = sqlite::open(path.text, sqlite::OpenDef { read_only: true });
    var seen = 0;
    for i in 20 {
        let n, found = sqlite::scalar_int(db, "select count(*) from t");
        if n >= seen { seen = n; }
    }
    sqlite::close(db);
    qput(Done { worker: -1, rows: if seen <= 800 { 0 } else { 1 } });
}

fn main() {
    var name: u8[>..] = [];
    format(name, "gs_sqlite_threads_", random_seed() % 1000000000, ".db");
    let path = Path { text: name };
    let db, ok = sqlite::open(name);
    print("open ", ok);
    sqlite::exec(db, "create table t(worker integer, n integer)");
    var ids: i64[>..] = [];
    for w in 4 { ids.push(thread_spawn(writer, w, path)); }
    ids.push(thread_spawn(reader, path));
    var total = 0;
    for i in 5 {
        let d = qget<Done>();
        if d.worker >= 0 { total += d.rows; } else { print("reader saw at most 800: ", d.rows == 0); }
    }
    for id in ids { thread_wait(id); }
    print("written ", total);
    let n, found = sqlite::scalar_int(db, "select count(*) from t");
    print("rows ", n);
    sqlite::each(db, "select worker, count(*), sum(n) from t group by worker order by worker") { r =>
        print("worker ", sqlite::int(r, 0), ": ", sqlite::int(r, 1), " rows, sum ", sqlite::int(r, 2));
    };
    sqlite::close(db);
    delete_file(name);
    delete_file(str(name, "-wal"));
    delete_file(str(name, "-shm"));
    print("cleaned up ", !file_exists(name));
}
