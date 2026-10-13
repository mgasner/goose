// Parameters: as arguments at every count the module has overloads for, of
// every type the bind set takes and one the program adds, as a Param array
// built in a loop for SQL whose parameters are only known at run time, and
// by name through a prepared statement.
import std;
import sqlite;

enum Color { Red, Green, Blue }

// The program's own type joins the bind set.
fn sqlite::bind(s: sqlite::Stmt, i: i64, c: Color) -> bool {
    return sqlite::bind(s, i, match c { Red => "red", Green => "green", Blue => "blue" });
}

fn main() {
    let db, ok = sqlite::open(":memory:");

    // Every argument count, 0 to 16: each sums its parameters.
    print(sqlite::scalar_int(db, "select 0"));
    print(sqlite::scalar_int(db, "select ?", 1));
    print(sqlite::scalar_int(db, "select ? + ?", 1, 2));
    print(sqlite::scalar_int(db, "select ? + ? + ?", 1, 2, 3));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ?", 1, 2, 3, 4));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ?", 1, 2, 3, 4, 5));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ?", 1, 2, 3, 4, 5, 6));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ?", 1, 2, 3, 4, 5, 6, 7));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ?", 1, 2, 3, 4, 5, 6, 7, 8));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ?", 1, 2, 3, 4, 5, 6, 7, 8, 9));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ? + ?", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ?",
                             1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ?",
                             1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ?",
                             1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ?",
                             1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ?",
                             1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    print(sqlite::scalar_int(db, "select ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ? + ?",
                             1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16));

    // Every type the set binds, and how SQLite sees each.
    sqlite::exec(db, "create table v(x)");
    var name: u8[] = "carol";
    let small: i32 = 5;
    let bytes: u8[] = [1, 2, 3];
    sqlite::exec(db, "insert into v values (?)", 42);
    sqlite::exec(db, "insert into v values (?)", small);
    sqlite::exec(db, "insert into v values (?)", 2.5);
    sqlite::exec(db, "insert into v values (?)", true);
    sqlite::exec(db, "insert into v values (?)", "literal");
    sqlite::exec(db, "insert into v values (?)", name);
    sqlite::exec(db, "insert into v values (?)", name[1..3]);
    sqlite::exec(db, "insert into v values (?)", "");
    sqlite::exec(db, "insert into v values (?)", sqlite::Blob { bytes: bytes });
    sqlite::exec(db, "insert into v values (?)", sqlite::Blob { bytes: [] });
    sqlite::exec(db, "insert into v values (?)", sqlite::Null {});
    sqlite::exec(db, "insert into v values (?)", Color.Blue);
    sqlite::exec(db, "insert into v values (?)", sqlite::Param.Real { v: -1.5 });
    sqlite::each(db, "select typeof(x), quote(x) from v order by rowid") { r =>
        print(sqlite::text(r, 0), " ", sqlite::text(r, 1));
    };

    // A Param array: an IN list as long as the data, and a row whose values
    // borrow their text.
    let ids: i64[] = [1, 3, 5, 13];
    var sql: u8[>..] = [];
    var ps: sqlite::Param[>..] = [];
    format(sql, "select group_concat(quote(x), ' ') from v where rowid in (");
    for id, i in ids {
        if i > 0 { sql.push(','); }
        sql.push('?');
        ps.push(sqlite::Param.Int { v: id });
    }
    sql.push(')');
    sqlite::one_params(db, sql, ps) { r => print(sqlite::text(r, 0)); };
    let row: sqlite::Param[] = [sqlite::Param.Text { s: name }, sqlite::Param.Blob { b: bytes },
                                sqlite::Param.Null, sqlite::Param.Int { v: 7 }];
    sqlite::exec(db, "create table w(a, b, c, d)");
    print(sqlite::exec_params(db, "insert into w values (?, ?, ?, ?)", row));
    // A literal takes its type from its first element, so a Param array is
    // declared as one.
    let seven: sqlite::Param[] = [sqlite::Param.Int { v: 7 }];
    let quoted, ran = sqlite::query_params(db, "select quote(a) || quote(b) || quote(c) || quote(d) from w where d = ?",
                                           seven) { r => sqlite::text(r, 0) };
    for q in quoted { print(q, " ", ran); }
    var n = 0;
    let kind: sqlite::Param[] = [sqlite::Param.Text { s: "text" }];
    sqlite::each_params(db, "select x from v where typeof(x) = ?", kind) { r =>
        n += 1;
    };
    print(n, " text values");

    // Named parameters, through a prepared statement.
    let s, prepared = sqlite::prepare(db, "select :b || '-' || :a || '-' || @a2");
    print(sqlite::param_count(s), " ", sqlite::param_name(s, 1), " ", sqlite::param_name(s, 3), " ",
          sqlite::param_index(s, ":a"), " ", sqlite::param_index(s, ":zz"));
    sqlite::bind(s, sqlite::param_index(s, ":a"), "A");
    sqlite::bind(s, sqlite::param_index(s, ":b"), "B");
    sqlite::bind(s, sqlite::param_index(s, "@a2"), 2);
    print(sqlite::step(s) == sqlite::ROW, " ", sqlite::text(sqlite::row(s), 0));
    print(sqlite::step(s) == sqlite::DONE);
    sqlite::reset(s);
    sqlite::close(db);
}
