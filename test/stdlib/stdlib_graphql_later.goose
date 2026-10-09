// graphql deferred values: a resolver asks a loader for a key and says what
// to do once it has loaded (r.later). Each loader runs once per round with
// the round's keys, distinct and in the order first asked; a `then` may ask
// again, which makes another round. Thens read only what a loader loaded,
// so a value given before its load aborts the program. On a pool, workers run their own
// rounds, and every response matches the main thread's.
import std;
import graphql;

struct Author { name: u8[..16], country: i64 }
struct Book { title: u8[..24], author: i64, tags: i64[..3], rating: i64 }
var authors: Author[>..] = [];
var books: Book[>..] = [];
let countries: u8[..8][3] = ["NZ", "PT", "JP"];

// What the "backend" has handed over, and its calls.
var loaded: bool[>..] = [];         // authors
var country_loaded: bool[3] = [false, false, false];
var calls: u8[>..] = [];

let AUTHORS = 0;
let COUNTRIES = 1;

// One loader member serving two tables: the table is its stored argument.
fn load(table: i64, keys: i64[:]) {
    format(calls, " ", if table == AUTHORS { "authors" } else { "countries" }, keys);
    for k in keys {
        if table == AUTHORS { loaded[k] = true; } else { country_loaded[k] = true; }
    }
}

fn author_name(key: i64, v: graphql::Slot&) { assert(loaded[key]); v.string(authors[key].name); }

// A chain: the author's country needs the author first, then the country.
fn author_country(key: i64, v: graphql::Slot&) {
    assert(loaded[key]);
    v.later(graphql::Loader(load, COUNTRIES), authors[key].country, graphql::Then(country_name));
}
fn country_name(key: i64, v: graphql::Slot&) { assert(country_loaded[key]); v.string(countries[key]); }

// Stored context before the library's parameters.
fn tag_name(prefix: u8, key: i64, v: graphql::Slot&) {
    var s: u8[>..] = [];
    s.push(prefix);
    format(s, key);
    v.string(s);
}

// A nullable field whose then may fail, and one whose then forgets.
fn rating(key: i64, v: graphql::Slot&) {
    if books[key].rating < 0 { v.error("no rating yet"); } else { v.int(books[key].rating); }
}
fn forgetful(key: i64, v: graphql::Slot&) {}

// A non-null field given null by its then: the null goes up to the book.
fn strict(key: i64, v: graphql::Slot&) { if key == 2 { v.none(); } else { v.int(key); } }

// A list given by a then.
fn digits(key: i64, v: graphql::Slot&) { v.list() { for d in 3 { v.int(key * 10 + d); } }; }

enum Obj { Query, Book { i: i64 } }

fn resolve(o: Obj.Query, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("books") { r.list() { for i in books.len { r.object(Obj.Book { i: i }); } }; }
    else if f.is("book") { r.object(Obj.Book { i: f.int("id") }); }
}

fn resolve(o: Obj.Book, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let b = books[o.i];
    let by_author = graphql::Loader(load, AUTHORS);
    let now = graphql::Loader(nothing);
    if f.is("title") { r.string(b.title); }
    else if f.is("authorName") { r.later(by_author, b.author, graphql::Then(author_name)); }
    else if f.is("authorCountry") { r.later(by_author, b.author, graphql::Then(author_country)); }
    else if f.is("tags") { r.list() { for t in b.tags { r.later(now, t, graphql::Then(tag_name, '#')); } }; }
    else if f.is("rating") { r.later(now, o.i, graphql::Then(rating)); }
    else if f.is("forgotten") { r.later(now, o.i, graphql::Then(forgetful)); }
    else if f.is("strict") { r.later(now, o.i, graphql::Then(strict)); }
    else if f.is("digits") { r.later(now, o.i, graphql::Then(digits)); }
}

// A loader with nothing to load: a then that only needs to wait its turn.
fn nothing(keys: i64[:]) { format(calls, " nothing(", keys.len, ")"); }

fn new_request() {
    calls.clear();
    for &x in loaded { x = false; }
    for &x in country_loaded { x = false; }
}

fn run(q: const u8[:]) {
    new_request();
    let c0 = graphql::loader_calls;
    let r0 = graphql::later_rounds;
    var out: u8[>..] = [];
    graphql::execute(q, Obj.Query, out) { o, f, r => resolve(o, f, r) };
    print(q);
    print("  calls:", calls, " (", graphql::loader_calls - c0, " in ", graphql::later_rounds - r0,
          " round(s))");
    print("  ", out);
}

thread_fn worker(n: i64) {
    graphql::serve<i64>(n, Obj.Query, apply) { o, f, r => resolve(o, f, r) };
}

fn apply(c: i64) {}

fn main() {
    let e = graphql::load_schema("""
        type Query { books: [Book!]!, book(id: Int!): Book }
        type Book {
            title: String!, authorName: String!, authorCountry: String!, tags: [String!]!,
            rating: Int, forgotten: Int, strict: Int!, digits: [Int!]!
        }
        """);
    assert(e.len == 0);
    for i in 5 {
        authors.push(Author { name: "", country: i % 3 });
        format(authors[i].name, "author", i);
        loaded.push(false);
    }
    for i in 6 {
        books.push(Book { title: "", author: (i * 2) % 5, tags: [i, i + 1], rating: if i == 4 { -1 } else { i } });
        format(books[i].title, "book", i);
    }

    // One loader call for the level's six books, keys distinct, first asked first.
    run("{ books { title authorName } }");
    // A chain: authors in the first round, countries in the second.
    run("{ books { authorCountry } }");
    // Two fields on one loader share its call; lists of deferred values.
    run("{ books { authorName authorCountry tags } }");
    // Errors: a then's own, one that gives nothing, and a non-null one.
    run("{ book(id: 4) { rating forgotten } }");
    run("{ books { title strict } }");
    // A then giving a list, and fields resolved now beside deferred ones.
    run("{ book(id: 1) { title digits authorName } }");
    // Nothing deferred, no round.
    run("{ books { title } }");

    // On a pool, with levels split across workers: every response matches.
    graphql::fork_min_fields = 4;
    graphql::fork_min_items = 2;
    let n = 3;
    var p = graphql::pool(n);
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker, n)); }
    let q = "{ books { title authorName authorCountry tags } }";
    new_request();
    var local: u8[>..] = [];
    graphql::execute(q, Obj.Query, local) { o, f, r => resolve(o, f, r) };
    var same = 0;
    for k in 10 {
        graphql::submit(p, q);
        if graphql::receive(p).body == local { same++; }
    }
    print("pool: ", same, "/10 match");
    graphql::stop(p);
    for id in ids { thread_wait(id); }
}
