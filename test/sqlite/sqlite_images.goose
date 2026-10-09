// Whole databases and whole Goose values as bytes: a backup to a file
// opened again, an in-memory image serialized and deserialized into another
// connection, a Goose array stored as one BLOB and verified on the way back
// with from_bytes, garbage refused, and a long query interrupted.
import std;
import os;
import sqlite;

struct Item { id: i64, name: u8[] }

fn main() {
    let db, ok = sqlite::open(":memory:");
    sqlite::exec_script(db, """
        create table t(k text primary key, v integer);
        insert into t values ('a', 1), ('b', 2), ('c', 3);
        """);

    // Backup to a file, and the file opened on its own.
    var name: u8[>..] = [];
    format(name, "gs_sqlite_backup_", random_seed() % 1000000000, ".db");
    print("backup ", sqlite::backup(db, name));
    let copy, ok2 = sqlite::open(name, sqlite::OpenDef { wal: false });
    print("copy: ", sqlite::scalar_text(copy, "select group_concat(k || '=' || v) from t"));
    sqlite::close(copy);
    print("removed ", delete_file(name));
    print("backup to a directory that is not there: ", sqlite::backup(db, "/nonexistent/dir/x.db"),
          " ", sqlite::error(db));

    // Serialize, and deserialize into another connection.
    var image: u8[>..] = [];
    print("serialize ", sqlite::serialize(db, image), " ", image.len > 0, " ", image.len % 512 == 0);
    let other, ok3 = sqlite::open(":memory:");
    print("deserialize ", sqlite::deserialize(other, image));
    print("other: ", sqlite::scalar_int(other, "select sum(v) from t"));
    sqlite::exec(other, "insert into t values ('d', 4)");
    print("other grew: ", sqlite::scalar_int(other, "select sum(v) from t"), ", the original: ",
          sqlite::scalar_int(db, "select sum(v) from t"));
    let junk: u8[] = [1, 2, 3, 4, 5, 6, 7, 8];
    let third, ok4 = sqlite::open(":memory:");
    print("garbage: ", sqlite::deserialize(third, junk), " ", sqlite::code(third) == sqlite::NOTADB);
    sqlite::close(third);
    sqlite::close(other);

    // A Goose array as one BLOB, verified when it comes back.
    var items: Item[>..] = [];
    items.push(Item { id: 1, name: "one" });
    items.push(Item { id: 2, name: "two" });
    items.push(Item { id: 3, name: "three" });
    sqlite::exec(db, "create table blobs(id integer primary key, data blob)");
    sqlite::exec(db, "insert into blobs(data) values (?)", sqlite::Blob { bytes: to_bytes(items) });
    sqlite::exec(db, "insert into blobs(data) values (?)", sqlite::Blob { bytes: junk });
    sqlite::each(db, "select id, data from blobs order by id") { r =>
        let back, valid = from_bytes<Item[>..]>(sqlite::blob(r, 1));
        print("blob ", sqlite::int(r, 0), ": valid ", valid, ", ", back.len, " items");
        for it in back { print("  ", it.id, " ", it.name); }
    };

    // Interrupted from inside the block, between steps.
    var rows = 0;
    let ran = sqlite::each(db, "with recursive c(x) as (select 1 union all select x + 1 from c) select x from c") { r =>
        rows += 1;
        if rows == 3 { sqlite::interrupt(db); }
    };
    print("interrupted after ", rows, ": ran ", ran, ", code ", sqlite::code(db) == sqlite::INTERRUPT, " ",
          sqlite::error(db));
    print("usable after: ", sqlite::scalar_int(db, "select count(*) from t"));
    sqlite::close(db);
}
