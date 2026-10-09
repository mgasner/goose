// Reading rows: query building each into the result, each and one, the
// scalar forms, rows as variable-size values, each() left early and what
// settle() does about it, the same SQL nested inside its own each(), and the
// statement cache: reuse, forget, and eviction under a small capacity.
import std;
import sqlite;

struct Item { id: i64, name: u8[], tags: u8[varint], price: f64 }
struct Short { code: u8[..4], qty: i32 }

fn first_expensive(db: sqlite::Db) -> i64 {
    sqlite::each(db, "select id, price from items order by id") { r =>
        if sqlite::real(r, 1) > 2.0 { return sqlite::int(r, 0); }
    };
    return -1;
}

fn main() {
    let db, ok = sqlite::open(":memory:", sqlite::OpenDef { statement_cache: 4 });
    sqlite::exec_script(db, """
        create table items(id integer primary key, name text, tags text, price real);
        insert into items(name, tags, price) values
            ('apple', 'fruit,red', 1.25), ('bread', 'bakery', 2.5),
            ('cheese', 'dairy,aged', 7.0), ('dates', '', 3.75);
        """);

    // Rows built in place: variable-size fields, a varint array, a limited one.
    let items, ran = sqlite::query(db, "select id, name, tags, price from items order by id") { r =>
        Item { id: sqlite::int(r, 0), name: sqlite::text(r, 1), tags: sqlite::text(r, 2),
               price: sqlite::real(r, 3) }
    };
    print(ran);
    for it in items { print(it.id, " ", it.name, " [", it.tags, "] ", it.price); }
    let shorts, ran2 = sqlite::query(db, "select substr(name, 1, 3), id * 10 from items where price < ?", 5.0) { r =>
        Short { code: sqlite::text(r, 0), qty: sqlite::int(r, 1) as i32 }
    };
    for s in shorts { print(s.code, " ", s.qty); }
    let none, ran3 = sqlite::query(db, "select name from items where price > ?", 100.0) { r => sqlite::text(r, 0) };
    print("none: ", none.len, " ", ran3);
    let bad, ran4 = sqlite::query(db, "select name from nowhere") { r => sqlite::text(r, 0) };
    print("bad: ", bad.len, " ", ran4, " ", sqlite::error(db));

    // Rows as values whatever their types.
    let values, ran5 = sqlite::query(db, """
        select name from items where id = 1 union all select price from items where id = 2
        union all select null union all select id from items where id = 4
        """) { r => sqlite::value(r, 0) };
    for v in values { print(v); }

    // one and the scalars: found, ran.
    let found, ran6 = sqlite::one(db, "select name from items where id = ?", 3) { r =>
        print("one: ", sqlite::text(r, 0));
    };
    print(found, " ", ran6);
    let missing, ran7 = sqlite::one(db, "select name from items where id = ?", 99) { r => print("not printed"); };
    print(missing, " ", ran7);
    print(sqlite::scalar_real(db, "select sum(price) from items"), " ",
          sqlite::scalar_text(db, "select name from items where price = ?", 2.5));
    let nothing, found2 = sqlite::scalar_int(db, "select id from items where id < 0");
    print(nothing, " ", found2);

    // each() left early: the statement stays mid-step until it is used
    // again, or settle() resets it.
    print("first expensive: ", first_expensive(db));
    print("again: ", first_expensive(db));
    sqlite::settle(db);

    // The same SQL inside its own each(): a second statement for it.
    var pairs = 0;
    sqlite::each(db, "select id from items") { a =>
        sqlite::each(db, "select id from items") { b => pairs += 1; };
    };
    print("pairs ", pairs);

    // The statement cache, at a capacity of 4: reused by SQL, forgotten,
    // and the least recently used evicted.
    sqlite::forget(db, "select id from items");
    let before = sqlite::cached_count(db);
    for i in 3 { sqlite::scalar_int(db, "select count(*) from items"); }
    print("cached ", before, " -> ", sqlite::cached_count(db));
    for i in 10 {
        var q: u8[>..] = [];
        format(q, "select ", i);
        sqlite::scalar_int(db, q);
    }
    print("cached after 10 more: ", sqlite::cached_count(db));

    // A prepared statement stepped by hand.
    let s, prepared = sqlite::prepare(db, "select name from items where price between ? and ? order by price");
    sqlite::bind(s, 1, 2.0);
    sqlite::bind(s, 2, 5.0);
    while sqlite::step(s) == sqlite::ROW { print("between: ", sqlite::text(sqlite::row(s), 0)); }
    sqlite::reset(s);
    sqlite::close(db);
}
