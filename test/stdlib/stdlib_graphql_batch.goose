// The graphql batch hook: one call per object type per level, with the
// fields that level will ask for, before any resolver of that level runs.
// The "backend" here counts its calls and the keys in each, and resolvers
// read only what the hook loaded, so a missed batch aborts the program.
// The pool part checks that a level split across workers batches per part.
import std;
import graphql;

struct Author { name: u8[..16], books: i64[..4] }
struct Book { title: u8[..24], author: i64, reviews: i64 }
var authors: Author[>..] = [];
var books: Book[>..] = [];

// What the backend has handed over in this request, and its calls.
var author_loaded: bool[>..] = [];
var book_loaded: bool[>..] = [];
var reviews_loaded: bool[>..] = [];
var serial: i64 = -1;
var calls: u8[>..] = [];

fn new_request() {
    if serial == graphql::request_serial { return; }
    serial = graphql::request_serial;
    for &b in author_loaded { b = false; }
    for &b in book_loaded { b = false; }
    for &b in reviews_loaded { b = false; }
}

// One backend call for the rows not loaded yet; records "table(new/asked)".
fn fetch(table: const u8[:], ids: i64[:], loaded: bool[:]) {
    var fresh = 0;
    for i in ids { if !loaded[i] { loaded[i] = true; fresh++; } }
    format(calls, " ", table, "(", fresh, "/", ids.len, ")");
}

enum Obj { Query, Author { i: i64 }, Book { i: i64 } }

fn batch(objs: Obj[:], sel: graphql::Selection&) {
    new_request();
    var ids: i64[>..] = [];
    for o in objs { match o { Author a => ids.push(a.i), Book b => ids.push(b.i), _ => {} } }
    if sel.type_name() == "Author" {
        if sel.has("name") { fetch("authors", ids, author_loaded); }
    } else if sel.type_name() == "Book" {
        if sel.has("title") || sel.has("author") { fetch("books", ids, book_loaded); }
        if sel.has("reviews") { fetch("reviews", ids, reviews_loaded); }
    }
}

fn resolve(o: Obj.Query, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("authors") { r.list() { for i in authors.len { r.object(Obj.Author { i: i }); } }; }
    else if f.is("everything") {
        r.list() {
            for i in authors.len { r.object(Obj.Author { i: i }); }
            for i in books.len { r.object(Obj.Book { i: i }); }
        };
    }
}

fn resolve(o: Obj.Author, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("name") { assert(author_loaded[o.i]); r.string(authors[o.i].name); }
    else if f.is("books") { r.list() { for b in authors[o.i].books { r.object(Obj.Book { i: b }); } }; }
}

fn resolve(o: Obj.Book, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("title") { assert(book_loaded[o.i]); r.string(books[o.i].title); }
    else if f.is("author") { assert(book_loaded[o.i]); r.object(Obj.Author { i: books[o.i].author }); }
    else if f.is("reviews") { assert(reviews_loaded[o.i]); r.int(books[o.i].reviews); }
}

fn type_of(o: Obj) -> const u8[:] { match o { Author => "Author", Book => "Book", _ => "Query" } }

fn run(q: const u8[:]) {
    calls.clear();
    var out: u8[>..] = [];
    graphql::execute(q, Obj.Query, out, type_of, batch) { o, f, r => resolve(o, f, r) };
    print(q);
    print("  calls:", calls);
    print("  ", out[..min(out.len, 140)], if out.len > 140 { " ..." } else { "" });
}

thread_fn worker(n: i64) {
    graphql::serve<i64>(n, Obj.Query, apply, type_of, batch) { o, f, r => resolve(o, f, r) };
}

fn apply(c: i64) {}

fn main() {
    let e = graphql::load_schema("""
        type Query { authors: [Author!]!, everything: [Thing!]! }
        type Author { name: String!, books: [Book!]! }
        type Book { title: String!, author: Author!, reviews: Int! }
        union Thing = Author | Book
        """);
    assert(e.len == 0);
    for i in 40 {
        authors.push(Author { name: "", books: [i * 3, i * 3 + 1, i * 3 + 2] });
        format(authors[i].name, "author", i);
        author_loaded.push(false);
    }
    for i in 120 {
        books.push(Book { title: "", author: (i * 7) % 40, reviews: i % 5 });
        format(books[i].title, "book", i);
        book_loaded.push(false);
        reviews_loaded.push(false);
    }

    // One call per type per level, however many objects are on it.
    run("{ authors { name books { title author { name } } } }");
    // Lookahead: no field of a loaded table, no call.
    run("{ authors { books { reviews } } }");
    // A union list: the level's authors and books, one call each.
    run("{ everything { ... on Author { name } ... on Book { title reviews } } }");
    // A request's cache: the second level's authors were loaded at the first.
    run("{ authors { name books { author { name } } } }");
    // Introspection objects never reach the hook.
    run("{ __type(name: \"Book\") { name fields { name } } }");

    // On a pool, a level split across workers is batched per part. Every
    // response matches the main thread's.
    graphql::fork_min_fields = 8;
    graphql::fork_min_items = 4;
    let n = 4;
    var p = graphql::pool(n);
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker, n)); }
    let q = "{ authors { name books { title author { name } } } }";
    calls.clear();
    var local: u8[>..] = [];
    graphql::execute(q, Obj.Query, local, type_of, batch) { o, f, r => resolve(o, f, r) };
    var same = 0;
    for k in 10 {
        graphql::submit(p, q);
        if graphql::receive(p).body == local { same++; }
    }
    print("pool: ", same, "/10 match");
    graphql::stop(p);
    for id in ids { thread_wait(id); }
}
