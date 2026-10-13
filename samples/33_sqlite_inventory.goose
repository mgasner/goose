// A shop's inventory in SQLite, with one thread doing all the writing.
// Commands come in on stdin; the main thread hands each to a writer
// thread_fn over a typed queue and waits for its reply, and answers
// `report` itself, through a read-only connection of its own to the same
// WAL file -- readers never wait for the writer.
//
// What it shows of the sqlite module: a schema run as a script, parameters
// passed as arguments, rows built straight into structs by query(), the
// scalar forms, a transaction that a `return` leaves early -- `sell` returns
// from its function when the stock is short, and the half-done sale is
// rolled back when the connection is next used -- and errors from SQLite
// itself (a duplicate name) as values. A connection belongs to the thread
// that opened it, so each thread opens its own.
//
// Build and run (from this directory):
//   goose -o sqlite_inventory.c 33_sqlite_inventory.goose
//   cc sqlite_inventory.c @$(goose --sqlite-link cc) -o sqlite_inventory
//   ./sqlite_inventory < data/sqlite_inventory.stdin
import std;
import os;
import sqlite;

let DB_PATH = "sqlite_inventory_sample.db";

// What crosses the queues must be flat: text in fixed-capacity arrays.
struct Command { op: u8[..8], name: u8[..24], qty: i64, price: f64 }
struct Reply { ok: bool, msg: u8[..96] }
struct Line { name: u8[], stock: i64, price: f64, sold: i64 }

// --- the writer ------------------------------------------------------------------------

fn add(db: sqlite::Db, c: Command&) -> bool, u8[>..] {
    if !sqlite::exec(db, "insert into items(name, stock, price) values (?, ?, ?)", c.name, c.qty, c.price) {
        return false, sqlite::error(db);
    }
    return true, str("added ", c.name, " #", sqlite::last_rowid(db));
}

fn restock(db: sqlite::Db, c: Command&) -> bool, u8[>..] {
    sqlite::exec(db, "update items set stock = stock + ? where name = ?", c.qty, c.name);
    if sqlite::changes(db) == 0 { return false, str("no item ", c.name); }
    return true, str("restocked ", c.name);
}

// A sale takes stock and records itself, both or neither. Every way out
// that is not the end of the block leaves the transaction early, which
// rolls it back.
fn sell(db: sqlite::Db, c: Command&) -> bool, u8[>..] {
    sqlite::transaction(db) { db =>
        sqlite::exec(db, "insert into sales(item, qty, price) select id, ?, price from items where name = ?",
                     c.qty, c.name);
        if sqlite::changes(db) == 0 { return false, str("no item ", c.name); }
        sqlite::exec(db, "update items set stock = stock - ? where name = ?", c.qty, c.name);
        let left, found = sqlite::scalar_int(db, "select stock from items where name = ?", c.name);
        if left < 0 { return false, str("only ", left + c.qty, " ", c.name, " in stock"); }
        true
    };
    return true, str("sold ", c.qty, " ", c.name);
}

fn apply(db: sqlite::Db, c: Command&) -> bool, u8[>..] {
    if c.op == "add" { return add(db, c); }
    if c.op == "restock" { return restock(db, c); }
    if c.op == "sell" { return sell(db, c); }
    return false, str("unknown command ", c.op);
}

// A thread_fn's arguments are copied in, so they are flat too.
thread_fn writer(path: u8[..64]) {
    let db, ok = sqlite::open(path);
    sqlite::exec_script(db, """
        create table items(id integer primary key, name text not null unique,
                           stock integer not null, price real not null);
        create table sales(id integer primary key, item integer not null references items(id),
                           qty integer not null, price real not null);
        """);
    qput(Reply { ok: ok, msg: "ready" });
    loop {
        var c = qget<Command>();
        if c.op == "quit" { break; }
        let done, msg = apply(db, c);
        qput(Reply { ok: done, msg: msg[..min(msg.len, 96)] });
    }
    sqlite::close(db);
}

// --- reports, on the main thread's own connection -------------------------------------------

fn report(db: sqlite::Db) {
    let lines, ok = sqlite::query(db, """
        select i.name, i.stock, i.price, coalesce(sum(s.qty), 0)
        from items i left join sales s on s.item = i.id group by i.id order by i.name
        """) { r =>
        Line { name: sqlite::text(r, 0), stock: sqlite::int(r, 1), price: sqlite::real(r, 2),
               sold: sqlite::int(r, 3) }
    };
    print("  item        stock    price   sold");
    for l in lines {
        var row: u8[>..] = [];
        format(row, "  ", l.name);
        while row.len < 14 { row.push(' '); }
        format_int(row, l.stock, 10, 5, ' ');
        row.push(' ');
        var price: u8[>..] = [];
        format_flt(price, l.price, 2);
        while price.len < 8 { price.insert_at(0, ' '); }
        format(row, price);
        format_int(row, l.sold, 10, 7, ' ');
        print(row);
    }
    let revenue, any = sqlite::scalar_real(db, "select total(qty * price) from sales");
    var r: u8[>..] = [];
    format_flt(r, revenue, 2);
    print("  revenue ", r, " from ", sqlite::scalar_int(db, "select count(*) from sales"), " sales");
}

// One line of input: a report here, anything else a command for the writer.
fn handle(db: sqlite::Db, line: const u8[:]) {
    let w = words(line);
    if w.len == 0 { return; }
    print("> ", line);
    if w[0] == "report" {
        report(db);
        return;
    }
    var c = Command { op: w[0], name: "", qty: 0, price: 0.0 };
    if w.len > 1 { c.name = w[1]; }
    if w.len > 2 { c.qty = parse_int(w[2]); }
    if w.len > 3 { c.price = parse_flt(w[3]); }
    qput(c);
    let reply = qget<Reply>();
    print(if reply.ok { "  ok: " } else { "  refused: " }, reply.msg);
}

fn main() {
    delete_file(DB_PATH);
    let id = thread_spawn(writer, DB_PATH);
    let ready = qget<Reply>();
    let db, ok = sqlite::open(DB_PATH, sqlite::OpenDef { read_only: true });
    if !ready.ok || !ok { abort("cannot open the inventory"); }

    loop {
        var line: u8[>..] = [];
        if !read_line(line) { break; }
        handle(db, line);
    }
    qput(Command { op: "quit", name: "", qty: 0, price: 0.0 });
    thread_wait(id);
    sqlite::close(db);
    delete_file(DB_PATH);
    delete_file(str(DB_PATH, "-wal"));
    delete_file(str(DB_PATH, "-shm"));
}
