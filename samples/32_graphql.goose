// A GraphQL server for a small book catalogue, on a pool of worker
// threads. Requests arrive on stdin, one JSON request per line, and the
// responses go to stdout in the same order.
//
// The schema is SDL. The program's side is an enum of object handles --
// one variant per object type, each holding an index into the program's
// own tables -- and one resolver case function per variant that answers a
// field by appending its value to `r`. The library parses and validates
// each request, calls the resolvers, checks what they give against the
// schema and writes the JSON.
//
// Workers share nothing: each starts with its own copy of the globals,
// catalogue included, and answers whole requests, a level of objects at a
// time. A worker that reaches a large enough level hands parts of it to the
// others. A mutation runs on the main thread, which records what it
// changed; `sync` then has every worker apply the same changes to its copy,
// between requests.
//
// Build and run (from this directory):
//   goose -o graphql.c 32_graphql.goose && cl graphql.c && graphql < data/graphql.stdin

import std;
import os;
import graphql;

let SDL = """
    "Anything with an ID."
    interface Node { id: ID! }

    enum Genre { FICTION HISTORY SCIENCE POETRY }

    type Book implements Node {
      id: ID!
      title: String!
      year: Int!
      genre: Genre!
      author: Author!
      "The average of the ratings given, or null before the first."
      rating: Float
    }

    type Author implements Node {
      id: ID!
      name: String!
      books(genre: Genre): [Book!]!
    }

    union SearchResult = Book | Author

    type Query {
      book(id: ID!): Book
      books(first: Int = 10, after: Int = 0, genre: Genre): [Book!]!
      authors: [Author!]!
      search(text: String!): [SearchResult!]!
      node(id: ID!): Node
    }

    type Mutation {
      rateBook(id: ID!, stars: Int!): Book!
    }
    """;

// --- the catalogue: flat tables, copied into every worker -------------------

struct Book { title: u8[..40], year: i32, genre: i32, author: i32, stars: i32, ratings: i32 }
struct Author { name: u8[..24] }

var books: Book[>..] = [];
var authors: Author[>..] = [];

fn genre_name(k: i64) -> const u8[:] {
    match k { 0 => "FICTION", 1 => "HISTORY", 2 => "SCIENCE", _ => "POETRY" }
}

fn build_catalogue() {
    let first = ["Ada", "Grace", "Alan", "Edsger", "Barbara", "Donald", "Frances", "Ken"];
    let last = ["Lovelace", "Hopper", "Turing", "Dijkstra", "Liskov", "Knuth", "Allen", "Thompson"];
    let words = ["River", "Stone", "Engine", "Garden", "Signal", "Harbor", "Lantern", "Atlas", "Winter", "Orbit"];
    for i in 64 {
        authors.push(Author { name: "" });
        format(authors[i].name, first[i % 8], " ", last[(i / 8 + i) % 8]);
    }
    var seed: u64 = 7;
    for i in 6000 {
        seed = seed * 6364136223846793005 + 1442695040888963407;
        let w = (seed >> 33) as! i64;
        books.push(Book { title: "", year: (1900 + w % 125) as! i32, genre: (w / 7 % 4) as! i32,
                          author: (i % 64) as! i32, stars: 0, ratings: 0 });
        format(books[i].title, "The ", words[w % 10], " of ", words[w / 10 % 10], " ", i);
    }
}

// --- changes: what a mutation did, replayed on every worker ------------------------

struct Rating { book: i64, stars: i64 }
var changes: Rating[>..] = [];

fn apply(c: Rating) {
    books[c.book].stars += c.stars as! i32;
    books[c.book].ratings += 1;
}

// --- resolvers ----------------------------------------------------------------------------

enum Obj { Query, Mutation, Book { i: i64 }, Author { i: i64 } }

// "Book:12" -> 12, if it names a row of the table.
fn parse_id(id: const u8[:], kind: const u8[:], count: i64) -> i64 {
    guard starts_with(id, kind) && id.len > kind.len && id[kind.len] == ':' else { return -1; }
    let n, ok = parse_int(id[kind.len + 1..]);
    return if ok && n >= 0 && n < count { n } else { -1 };
}

fn genre_of(f: graphql::Field&) -> i64 {
    guard f.has("genre") else { return -1; }
    let g = f.string("genre");
    for k in 4 { if genre_name(k) == g { return k; } }
    return -1;
}

fn resolve(o: Obj.Query, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("book") {
        let b = parse_id(f.string("id"), "Book", books.len);
        if b >= 0 { r.object(Obj.Book { i: b }); } else { r.none(); }
    } else if f.is("books") {
        let first = f.int("first");
        let after = f.int("after");
        let genre = genre_of(f);
        guard first >= 0 && after >= 0 else { r.error("first and after must not be negative"); return; }
        r.list() {
            var n = 0;
            for i in after..books.len {
                if n == first { break; }
                if genre >= 0 && books[i].genre != genre { continue; }
                r.object(Obj.Book { i: i });
                n++;
            }
        };
    } else if f.is("authors") {
        r.list() { for i in authors.len { r.object(Obj.Author { i: i }); } };
    } else if f.is("search") {
        let text = f.string("text");
        r.list() {
            for a, i in authors { if find(a.name, text) >= 0 { r.object(Obj.Author { i: i }); } }
            for b, i in books { if find(b.title, text) >= 0 { r.object(Obj.Book { i: i }); } }
        };
    } else if f.is("node") {
        let id = f.string("id");
        let b = parse_id(id, "Book", books.len);
        let a = parse_id(id, "Author", authors.len);
        if b >= 0 { r.object(Obj.Book { i: b }); }
        else if a >= 0 { r.object(Obj.Author { i: a }); }
        else { r.none(); }
    }
}

fn resolve(o: Obj.Mutation, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("rateBook") {
        let b = parse_id(f.string("id"), "Book", books.len);
        let stars = f.int("stars");
        guard b >= 0 else { r.error(str("no book has the id ", f.string("id"))); return; }
        guard stars >= 1 && stars <= 5 else { r.error("stars must be from 1 to 5"); return; }
        let c = Rating { book: b, stars: stars };
        apply(c);                  // this thread's copy, for the response
        changes.push(c);           // and every worker's, at the next sync
        r.object(Obj.Book { i: b });
    }
}

fn resolve(o: Obj.Book, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let b = books[o.i];
    if f.is("id") { r.string(str("Book:", o.i)); }
    else if f.is("title") { r.string(b.title); }
    else if f.is("year") { r.int(b.year); }
    else if f.is("genre") { r.enum_value(genre_name(b.genre)); }
    else if f.is("author") { r.object(Obj.Author { i: b.author }); }
    else if f.is("rating") {
        if b.ratings > 0 { r.float(b.stars * 1.0 / b.ratings); } else { r.none(); }
    }
}

fn resolve(o: Obj.Author, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("id") { r.string(str("Author:", o.i)); }
    else if f.is("name") { r.string(authors[o.i].name); }
    else if f.is("books") {
        let genre = genre_of(f);
        r.list() {
            for b, i in books {
                if b.author == o.i && (genre < 0 || b.genre == genre) { r.object(Obj.Book { i: i }); }
            }
        };
    }
}

// The object type of a handle, for the interface and union fields.
fn type_of(o: Obj) -> const u8[:] {
    match o { Book => "Book", Author => "Author", Mutation => "Mutation", _ => "Query" }
}

thread_fn worker(n: i64) {
    graphql::serve<Rating>(n, Obj.Query, apply, type_of) { o, f, r => resolve(o, f, r) };
}

// --- the server loop -------------------------------------------------------------------------

// Responses come back in whatever order workers finish; they are printed
// in request order.
var held: u8[>..] = [];
var held_at: i64[>..] = [];
var held_len: i64[>..] = [];
var slot_of: i64[>..] = [];      // a submitted request's id -> its place in order
var printed: i64 = 0;
var waiting: i64 = 0;

fn collect_all(p: graphql::Pool&) {
    while waiting > 0 {
        let reply = graphql::receive(p);
        let slot = slot_of[reply.id];
        held_at[slot] = held.len;
        held_len[slot] = reply.body.len;
        held.append(reply.body);
        waiting--;
    }
    while printed < held_at.len {
        print(held[held_at[printed]..held_at[printed] + held_len[printed]]);
        printed++;
    }
}

fn main() {
    build_catalogue();
    let err = graphql::load_schema(SDL);
    guard err.len == 0 else { print("schema: ", err); exit(1); }

    // Workers start with copies of everything above, schema included.
    let n = max(2, min(8, hardware_threads()));
    var p = graphql::pool(n);
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker, n)); }

    var line: u8[>..] = [];
    while read_line(line) {
        if trim(line).len > 0 {
            if graphql::is_mutation(line) {
                // Everything before it is answered from the data before it.
                collect_all(p);
                var out: u8[>..] = [];
                graphql::execute(line, Obj.Mutation, out, type_of) { o, f, r => resolve(o, f, r) };
                graphql::sync(p, changes);
                changes.clear();
                held_at.push(held.len);
                held_len.push(out.len);
                held.append(out);
            } else {
                let id = graphql::submit(p, line);
                assert(id == slot_of.len);
                slot_of.push(held_at.len);
                held_at.push(-1);
                held_len.push(0);
                waiting++;
            }
        }
        line.clear();
    }
    collect_all(p);

    // A big request, on one thread and on the pool, timed on stderr.
    let big = "{ authors { name books { title year rating author { name } } } }";
    let reps = 40;
    let t0 = clock();
    var one: u8[>..] = [];
    for k in reps {
        one.clear();
        graphql::execute(big, Obj.Query, one, type_of) { o, f, r => resolve(o, f, r) };
    }
    let t1 = clock();
    var same = true;
    for k in reps { graphql::submit(p, big); }
    for k in reps { if graphql::receive(p).body != one { same = false; } }
    let t2 = clock();
    print("the pool's answers match the main thread's: ", same);
    var note: u8[>..] = [];
    format(note, reps, " requests of ", one.len, " bytes: one thread ");
    format_flt(note, (t1 - t0) * 1000.0, 1);
    format(note, " ms, ", n, " workers ");
    format_flt(note, (t2 - t1) * 1000.0, 1);
    format(note, " ms\n");
    write_stderr(note);

    graphql::stop(p);
    for id in ids { thread_wait(id); }
}
