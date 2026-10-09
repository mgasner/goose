// The sqlite module's connections, types and errors: opening, the value of
// every column type and NULL, reading columns every way, the statement's own
// description of its columns, failures as values with their codes, and
// what the library reports about itself.
import std;
import sqlite;

// Bytes as hex, so a blob prints as text.
fn hex(b: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in b { format_uint(out, c, 16, 2, '0'); }
    return out;
}

// A value with its blob, if it is one, as hex.
fn show(v: sqlite::Value..) -> u8[>..] {
    return match v {
        Blob &x => str("Blob { ", hex(x.b), " }"),
        _ => str(v),
    };
}

fn main() {
    print(sqlite::available(), " ", sqlite::version_number() >= 3054000);

    // A database that cannot be opened: false, with the reason, and the
    // connection still to close.
    let bad, opened = sqlite::open("/nonexistent/dir/x.db", sqlite::OpenDef { create: false });
    print("open missing: ", opened, " ", sqlite::code(bad) == sqlite::CANTOPEN, " ",
          sqlite::error(bad));
    sqlite::close(bad);

    let db, ok = sqlite::open(":memory:");
    print("open: ", ok, " ", sqlite::code(db), " ", sqlite::error(db));

    print(sqlite::exec_script(db, """
        create table t(i integer, r real, s text, b blob, n);
        insert into t values (42, 2.5, 'hi', x'00ff10', null);
        insert into t values (-7, -0.25, '', x'', 3);
        """));
    print("changes ", sqlite::changes(db), ", total ", sqlite::total_changes(db),
          ", last rowid ", sqlite::last_rowid(db));

    // Every way of reading every column of the first row.
    sqlite::one(db, "select i, r, s, b, n from t where rowid = 1") { r =>
        print("columns ", sqlite::column_count(r));
        for i in sqlite::column_count(r) {
            print(sqlite::column_name(r, i), ": type ", sqlite::column_type(r, i),
                  " null ", sqlite::is_null(r, i), " bytes ", sqlite::byte_count(r, i),
                  " value ", show(sqlite::value(r, i)));
        }
        print(sqlite::int(r, 0), " ", sqlite::real(r, 1), " [", sqlite::text(r, 2), "] ",
              hex(sqlite::blob(r, 3)), " ", sqlite::int(r, 4), " ", sqlite::text(r, 4).len);
        print(sqlite::int_or(r, 4, -1), " ", sqlite::real_or(r, 4, 0.5), " ",
              sqlite::int_or(r, 0, -1), " ", sqlite::bool_of(r, 0));
        // SQLite's conversions: the integer as text, the text as a number.
        print(sqlite::text(r, 0), " ", sqlite::real(r, 0), " ", sqlite::int(r, 1));
        var line: u8[>..] = [];
        format(line, "into: ");
        sqlite::text_into(r, 2, line);
        line.push(' ');
        sqlite::blob_into(r, 3, line);
        print(line.len);
        print("index of s ", sqlite::column_index(r, "s"), ", of zz ", sqlite::column_index(r, "zz"));
    };

    // The statement's own description: declared types, empty for expressions.
    let s, prepared = sqlite::prepare(db, "select i, s, i + 1 as next from t");
    for i in sqlite::column_count(s) {
        print(sqlite::column_name(s, i), " [", sqlite::column_decltype(s, i), "]");
    }
    print("readonly ", sqlite::readonly(s), " sql ", sqlite::sql(s));
    let ins, p2 = sqlite::prepare(db, "insert into t(i) values (1)");
    print("readonly ", sqlite::readonly(ins));

    // Failures are values, described by code, extended code, message and
    // where in the SQL a syntax error is.
    print(sqlite::exec(db, "select nope from t"), " ", sqlite::code(db), " ",
          sqlite::error(db), " at ", sqlite::error_offset(db));
    print(sqlite::exec(db, "selec 1"), " ", sqlite::error(db), " at ", sqlite::error_offset(db));
    print(sqlite::exec(db, "select 1; select 2"), " ", sqlite::error(db));
    sqlite::exec(db, "create table u(id integer primary key, name text not null unique)");
    sqlite::exec(db, "insert into u(name) values (?)", "a");
    print(sqlite::exec(db, "insert into u(name) values (?)", "a"), " ", sqlite::code(db) == sqlite::CONSTRAINT,
          " ", sqlite::extended_code(db), " ", sqlite::error(db));
    print(sqlite::exec(db, "insert into u(name) values (null)"), " ", sqlite::error(db));
    print(sqlite::exec_script(db, "insert into u(name) values ('b'); bogus;"), " ", sqlite::error(db));
    // A failure stays until the next one; successes do not clear it.
    print(sqlite::exec(db, "insert into u(name) values ('c')"), " ", sqlite::error(db));
    let count, found = sqlite::scalar_int(db, "select count(*) from u");
    print("rows ", count, " ", found);

    // The library: memory, a soft heap limit (returning the previous one).
    print(sqlite::memory_used() > 0, " ", sqlite::set_soft_heap_limit(1 << 30), " ",
          sqlite::set_soft_heap_limit(0));
    sqlite::close(db);
}
