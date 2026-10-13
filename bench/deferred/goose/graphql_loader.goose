// A GraphQL request whose fields need rows from a "backend" that charges a
// fixed cost per call, resolved three ways (bench/deferred/README.md):
//
//   naive  every resolver loads what it needs itself, through a per-request
//          cache: one backend call per distinct row (the N+1 problem);
//   batch  the batch hook loads, before the level runs, what the level's
//          fields will need (docs/graphql.md §5);
//   later  resolvers ask loaders for keys and say what to do with the rows
//          (r.later, deferred calls): one call per loader per round.
//
//   graphql_loader <naive|batch|later> <books> <call_ns> <reps>
//     -> the first response, then: ns_per_request backend_calls_per_request
//
// `{ books { title authorName authorCountry } }` over `books` books, a
// quarter as many authors, and 16 countries; a country needs its author's
// row first, so it is a second round of loading.
import os;
import std;
import graphql;

struct BookRow { title: u8[..16], author: i64 }
struct AuthorRow { name: u8[..16], country: i64 }
var book_rows: BookRow[>..] = [];
var author_rows: AuthorRow[>..] = [];
var country_rows: u8[..8][>..] = [];

// The backend: a call costs call_ns, spent spinning, and marks the rows it
// returns as loaded for the request (the program's own cache).
var call_ns: i64 = 0;
var calls: i64 = 0;
var author_loaded: bool[>..] = [];
var country_loaded: bool[>..] = [];

fn spin(ns: i64) {
    guard ns > 0 else { return; }
    let until = clock_ns() + ns;
    while clock_ns() < until {}
}

fn fetch_authors(ids: i64[:]) {
    calls++;
    spin(call_ns);
    for i in ids { author_loaded[i] = true; }
}

fn fetch_countries(ids: i64[:]) {
    calls++;
    spin(call_ns);
    for i in ids { country_loaded[i] = true; }
}

fn new_request() {
    for &x in author_loaded { x = false; }
    for &x in country_loaded { x = false; }
}

// naive: a row at a time, through the cache.
fn author_row(a: i64) -> AuthorRow {
    if !author_loaded[a] { fetch_authors([a]); }
    return author_rows[a];
}
fn country_name(c: i64) -> const u8[:] {
    if !country_loaded[c] { fetch_countries([c]); }
    return country_rows[c][..];
}

enum Obj { Query, Book { i: i64 } }

var mode: i64 = 0;
let NAIVE = 0;
let BATCH = 1;
let LATER = 2;

fn resolve(o: Obj.Query, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("books") { r.list() { for i in book_rows.len { r.object(Obj.Book { i: i }); } }; }
}

fn resolve(o: Obj.Book, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let b = book_rows[o.i];
    if f.is("title") { r.string(b.title); }
    else if f.is("authorName") {
        if mode == LATER { r.later(graphql::Loader(load_authors), b.author, graphql::Then(give_name)); }
        else if mode == BATCH { assert(author_loaded[b.author]); r.string(author_rows[b.author].name); }
        else { r.string(author_row(b.author).name); }
    } else if f.is("authorCountry") {
        if mode == LATER { r.later(graphql::Loader(load_authors), b.author, graphql::Then(give_country)); }
        else if mode == BATCH {
            let c = author_rows[b.author].country;
            assert(country_loaded[c]);
            r.string(country_rows[c]);
        } else { r.string(country_name(author_row(b.author).country)); }
    }
}

// batch: the level's books, all at once.
fn batch(objs: Obj[:], sel: graphql::Selection&) {
    guard sel.type_name() == "Book" else { return; }
    guard sel.has("authorName") || sel.has("authorCountry") else { return; }
    var ids: i64[>..] = [];
    for o in objs { match o { Book b => ids.push(book_rows[b.i].author), _ => {} } }
    sort(ids[..]);
    dedup(ids);
    fetch_authors(ids);
    guard sel.has("authorCountry") else { return; }
    var cs: i64[>..] = [];
    for a in ids { cs.push(author_rows[a].country); }
    sort(cs[..]);
    dedup(cs);
    fetch_countries(cs);
}

// later: the loaders and what follows them.
fn load_authors(keys: i64[:]) { fetch_authors(keys); }
fn load_countries(keys: i64[:]) { fetch_countries(keys); }
fn give_name(key: i64, s: graphql::Slot&) { s.string(author_rows[key].name); }
fn give_country(key: i64, s: graphql::Slot&) {
    s.later(graphql::Loader(load_countries), author_rows[key].country, graphql::Then(give_country_name));
}
fn give_country_name(key: i64, s: graphql::Slot&) { s.string(country_rows[key]); }

fn type_of(o: Obj) -> const u8[:] { match o { Book => "Book", _ => "Query" } }

fn request(q: const u8[:], out: u8[>..]&) {
    new_request();
    if mode == BATCH {
        graphql::execute(q, Obj.Query, out, type_of, batch) { o, f, r => resolve(o, f, r) };
    } else {
        graphql::execute(q, Obj.Query, out) { o, f, r => resolve(o, f, r) };
    }
}

fn main() {
    let a = args();
    mode = if a[1] == "naive" { NAIVE } else if a[1] == "batch" { BATCH } else { LATER };
    let nbooks = parse_int(a[2]);
    call_ns = parse_int(a[3]);
    let reps = parse_int(a[4]);
    let e = graphql::load_schema("""
        type Query { books: [Book!]! }
        type Book { title: String!, authorName: String!, authorCountry: String! }
        """);
    assert(e.len == 0);
    let nauthors = max(1, nbooks / 4);
    for i in 16 {
        var c: u8[..8] = [];
        format(c, "C", i);
        country_rows.push(c);
        country_loaded.push(false);
    }
    for i in nauthors {
        var n: u8[..16] = [];
        format(n, "author", i);
        author_rows.push(AuthorRow { name: n, country: (i * 5) % 16 });
        author_loaded.push(false);
    }
    for i in nbooks {
        var t: u8[..16] = [];
        format(t, "book", i);
        book_rows.push(BookRow { title: t, author: (i * 7) % nauthors });
    }
    let q = "{ books { title authorName authorCountry } }";
    var first: u8[>..] = [];
    request(q, first);
    print(first);
    // Warm up, then time.
    for k in min(reps, 10) { var out: u8[>..] = []; request(q, out); }
    calls = 0;
    let t0 = clock_ns();
    for k in reps { var out: u8[>..] = []; request(q, out); }
    let t1 = clock_ns();
    print((t1 - t0) / reps, " ", calls / reps);
}
