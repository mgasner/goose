# GraphQL in Goose

`import graphql;` gives a Goose program a GraphQL server. You write the
schema in SDL, and the program answers fields from its own data. The library
does the rest: it parses and validates each request against the schema,
calls your resolvers, checks what they return against the schema, and writes
the JSON response. One call runs one request, a level at a time, so a
backend sees one batch per type per level. A pool of worker threads runs
many requests at once.

This page shows how to use it. [`design/graphql.md`](design/graphql.md)
explains why it is built this way, and
[`samples/32_graphql.goose`](../samples/32_graphql.goose) is a complete
server.

The library does no networking, because Goose has none yet. It takes a
request as bytes and appends the response as bytes. Your program decides
where they come from and go: stdin and stdout, files, or a C host through
`export fn`.

---

## 1. A first server

```goose
import std;
import graphql;

struct User { name: u8[..24], friends: i64[..4] }
var users: User[>..] = [];

// One variant per object type, each holding whatever finds the object.
enum Obj { Query, User { i: i64 } }

fn resolve(o: Obj.Query, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("me") { r.object(Obj.User { i: 0 }); }
    else if f.is("users") { r.list() { for i in users.len { r.object(Obj.User { i: i }); } }; }
}

fn resolve(o: Obj.User, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let u = users[o.i];
    if f.is("name") { r.string(u.name); }
    else if f.is("friends") { r.list() { for k in u.friends { r.object(Obj.User { i: k }); } }; }
}

fn main() {
    users.push(User { name: "ada", friends: [1] });
    users.push(User { name: "grace", friends: [0] });

    let err = graphql::load_schema("""
        type Query { me: User, users: [User!]! }
        type User { name: String!, friends: [User!]! }
        """);
    guard err.len == 0 else { print(err); exit(1); }

    var out: u8[>..] = [];
    graphql::execute("{ me { name friends { name } } }", Obj.Query, out) { o, f, r => resolve(o, f, r) };
    print(out);    // {"data":{"me":{"name":"ada","friends":[{"name":"grace"}]}}}
}
```

There are four pieces:

* **The schema**, in SDL, loaded once with `graphql::load_schema`.
* **Handles**: an enum with one variant per object type. A handle says which
  object a field is asked about. It is usually an index or a key into your
  own tables, not the object itself.
* **Resolvers**: one case function per variant. Each one answers a field by
  appending the field's value to `r`. The call `resolve(o, f, r)` with an
  `Obj` dispatches on its variant, so the block passed to `execute` is the
  same one line for every program.
* **`execute`**: runs a request with a root handle and appends the response
  to `out`.

---

## 2. The schema

```goose
let err = graphql::load_schema(sdl);    // "" or what is wrong, with line and column
```

Call it once, in `main`, before running any request and before spawning any
worker. It supports:

* `type`, `interface` (with `implements`), `union`, `enum`, `input`, `scalar`;
* field arguments and input fields with default values;
* list and non-null types;
* descriptions, as strings or block strings before a definition;
* `@deprecated(reason: ...)` on fields, arguments, input fields and enum
  values;
* `directive` definitions;
* a `schema { query: ... mutation: ... }` block.

Without a `schema` block the root types are `Query` and `Mutation`.

`Int`, `Float`, `String`, `Boolean` and `ID` are built in, as are `@skip`,
`@include`, `@deprecated` and `@specifiedBy`.

A schema that does not load says why:

```
Unknown type "Nope".
Syntax Error: Expected Name, found "}". (line 3, column 9)
Union type U can only include Object types, it cannot include Int.
```

Type extensions (`extend type`) and subscriptions are not supported. A
program has one schema; loading another replaces it.

---

## 3. Resolvers

A resolver gets the handle of the object, the field being asked for, and the
result to append its value to:

```goose
fn resolve(o: Obj.User, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let u = users[o.i];
    if f.is("name") { r.string(u.name); }
    else if f.is("age") { r.int(u.age); }
}
```

`f.is(name)` compares the field's schema name. An alias in the request does
not change it. A resolver is ordinary Goose code, called from a loop rather
than from inside a recursion. It may build temporaries (`r.string(str(u.first,
" ", u.last))`), use locals of any kind, and call anything except
`graphql::execute` itself.

Resolvers run breadth-first: every field of every object at one level of the
response before any at the next (§5). Nothing should depend on the order in
which resolvers of a query are called.

### Giving a value

| Call | Gives |
|---|---|
| `r.int(v)` | an `Int`, or an `ID` written as a string |
| `r.float(v)` | a `Float` |
| `r.boolean(v)` | a `Boolean` |
| `r.string(s)` | a `String` or `ID`; for an enum type, a value's name works too |
| `r.enum_value(name)` | an enum value |
| `r.json(text)` | a custom scalar's value, as JSON written out as is |
| `r.none()` | null (`null` is a keyword, hence the name) |
| `r.object(o)` | an object, given by its handle; its selection set runs on it next |
| `r.list() { ... }` | a list whose items are the values the block gives, in order; lists nest |
| `r.error(msg)` | a field error: the field is null and `errors` says why |

A field takes exactly one value, so a list type takes one `r.list()`. The
library checks every value against the field's type:
- an `Int` outside 32 bits, a string for a `Boolean`, or an enum value the
  enum does not have becomes a field error;
- so does a field the resolver gave no value at all (`No value was given for
  User.age.`), which shows a missed field rather than hiding it as null.

```goose
r.list() { for row in grid { r.list() { for v in row { r.int(v); } }; } };   // [[Int!]!]!
```

### Arguments

Validation has already checked every argument against the schema, filled in
defaults, and replaced variables with their values. So reading one is
direct:

```goose
let first = f.int("first");          // Int (with its default, if the request gave none)
let id = f.string("id");             // String, ID, or an enum value's name
let x = f.float("x");                // Float (an Int argument reads as one too)
let on = f.boolean("on");
if f.has("after") { ... }            // whether a nullable argument has a value
```

Reading an argument that is absent or null aborts the program, and so does
asking for one the field does not declare. Both are bugs in the resolver, the
same as an out-of-bounds index. Use `f.has` first for a nullable argument.

Input objects and lists go through `graphql::Input` values:

```goose
let filter = f.arg("filter");                    // input Filter { kind: Kind!, minAge: Int = 0 }
let kind = filter.member("kind").string();
let min_age = filter.member("minAge").int();     // the input field's default, if not given
var total = 0;
f.arg("xs").each() { total += it.int(); };       // [Int!]!
```

`a.present()` asks whether an `Input` has a value. `a.each()` treats a single
value as a list of one, as GraphQL's input coercion does.

### The field itself

`f.field_name()` is the field's name and `f.parent_type()` is the name of the
object type it is being run on. The latter is useful when one variant serves
several types, such as a root handle shared by `Query` and `Mutation`.

---

## 4. Interfaces and unions

For a field whose type is an interface or a union, the library has to know
which object type each handle is. Pass a `type_of` function, the argument
before the resolver block:

```goose
fn type_of(o: Obj) -> const u8[:] {
    match o { Book => "Book", Author => "Author", _ => "Query" }
}

graphql::execute(request, Obj.Query, out, type_of) { o, f, r => resolve(o, f, r) };
```

It must name an object type that belongs to the interface or the union. Any
other name is a field error. `type_of` must be a single function, not a set
of overloads, because a function value cannot be an overload set. A `match`
does the dispatch instead. Without interfaces and unions, leave it out.

`__typename`, fragments on interfaces and unions (`... on Book { title }`),
and type conditions all use it.

---

## 5. Backends: the batch hook

When fields come from a database or another service, resolving them one
object at a time makes one backend call per object: the "N+1" problem. The
library avoids that by running a request one **level** at a time. Every
object at depth 1 of the response, then every object at depth 2, and so on.
Before it resolves any field of a level, it calls your **batch hook** once
per object type on that level, with all of those objects' handles:

```goose
fn batch(objs: Obj[:], sel: graphql::Selection&) {
    var ids: i64[>..] = [];
    for o in objs { match o { Author a => ids.push(a.id), Book b => ids.push(b.id), _ => {} } }
    if sel.type_name() == "Author" && sel.has("name") { authors_by_id(ids); }      // one call
    if sel.type_name() == "Book" {
        if sel.has("title") || sel.has("author") { books_by_id(ids); }             // one call
        if sel.has("reviews") { review_counts(ids); }                              // one call
    }
}

graphql::execute(request, Obj.Query, out, type_of, batch) { o, f, r => resolve(o, f, r) };
```

The hook loads what the level needs into your own tables, and the resolvers
then read those tables. `sel.has(name)` says whether any of the objects will
be asked for field `name`, so a hook fetches only what the request uses. That
includes per-object lists such as an author's books, which a hook can fetch
for all the level's authors at once.

`{ authors { name books { title author { name } } } }` makes one call per
type per level, here three, however many authors and books there are. Without
the hook it would make one call per author and per book.

* The hook runs before any resolver of its level. It sees the program's
  handles only; introspection objects never reach it.
* `objs` has one handle per object in the response. An object that appears
  twice is there twice, so de-duplicate keys before calling the backend.
* Keep what you load in global tables. Skip keys you already have, and you
  get a per-request cache like DataLoader's. `graphql::request_serial`
  changes with every request, so a cache can tell when to start over.
* With no hook, leave the argument out. `execute(request, root, out,
  type_of)` and `execute(request, root, out)` still run level by level; they
  just call no hook.

Running a level at a time has one cost: the response is written after all of
it is resolved, not while fields resolve, so a request's results stay in
memory until it ends, about as much as the response itself. On in-memory
data it ran as fast as the earlier depth-first executor. Large and medium
requests were 0–6% faster, and requests of a few fields about 0.15 µs
slower.

---

## 6. Requests and responses

A request is either a GraphQL document or a JSON object in the usual
GraphQL-over-HTTP shape:

```json
{"query": "query($id: ID!) { book(id: $id) { title } }", "variables": {"id": "Book:42"}, "operationName": null}
```

The library tells them apart by their first characters: a `{` followed by a
`"` is JSON. With several operations in the document, `operationName` picks
one.

The response is JSON:

* `{"data": ...}` when everything worked;
* `{"data": ..., "errors": [...]}` when some fields failed (**field errors**);
* `{"errors": [...]}` with no `data` when the request could not run at all
  (**request errors**: a syntax error, a validation error, or variables that
  do not fit their types).

Every error has a `message`. Errors in the query have `locations`, and field
errors have the `path` to the field. Messages follow graphql-js's wording:

```json
{"errors":[{"message":"Cannot query field \"publisher\" on type \"Book\".","locations":[{"line":1,"column":30}]}]}
{"data":{"strict":null},"errors":[{"message":"Cannot return null for non-nullable field Query.strict.","locations":[{"line":1,"column":3}],"path":["strict",1]}]}
```

The second shows **null propagation**: an item of `strict: [Pet!]` was null,
which a non-null item cannot be, so the nearest nullable position (the list
itself) became null. The library does this as GraphQL specifies. Output
already written for the abandoned part is taken back, so a response never
holds half of a failed object.

Validation implements the spec's rules except three: that fields merged
under one response key are compatible (where two differ, the first wins),
that a directive appears once per location, and that an input object
literal names each field once. Queries deeper than `graphql::max_depth`
(default 32) are rejected, because execution depth uses native stack.

---

## 7. Mutations

A mutation is a request whose operation is `mutation`. Its top-level fields
run in order, as the spec requires. Pass the root handle you want for it:

```goose
let root = if graphql::is_mutation(request) { Obj.Mutation } else { Obj.Query };
graphql::execute(request, root, out, type_of) { o, f, r => resolve(o, f, r) };
```

`graphql::is_mutation(request)` is true for a request that is valid and
selects a mutation. With a single handle for both roots, use
`f.parent_type()` to tell the two apart.

---

## 8. Introspection

`__typename`, `__schema` and `__type(name:)` work out of the box. Tools such
as GraphiQL and code generators can therefore read the schema from a running
server. To turn them off:

```goose
graphql::introspection = false;     // __schema and __type become unknown fields
```

---

## 9. Running on many threads

Goose threads share no memory: a worker is a separate program with its own
copy of every global it uses, taken when it is spawned (tutorial §14). A
pool of workers therefore works like this:

* **Every worker answers whole requests from its own copy of the data.**
  This is where almost all of the throughput comes from.
* **A worker that reaches a large level hands parts of it to idle workers.**
  This cuts the latency of one very large request.
* **Mutations run on the main thread, which records what they changed.**
  `sync` then has every worker apply the same changes to its copy.

### Setting up a pool

```goose
// What a mutation changed, replayed on every copy of the data.
struct Rating { book: i64, stars: i64 }
var changes: Rating[>..] = [];

fn apply(c: Rating) {
    books[c.book].stars += c.stars;
    books[c.book].ratings += 1;
}

thread_fn worker(n: i64) {
    graphql::serve<Rating>(n, Obj.Query, apply, type_of, batch) { o, f, r => resolve(o, f, r) };
}

fn main() {
    load_data();
    let err = graphql::load_schema(SDL);   // before spawning: workers get copies
    let n = hardware_threads();
    var p = graphql::pool(n);
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker, n)); }

    let id = graphql::submit(p, request);   // to whichever worker is free
    let reply = graphql::receive(p);        // the next finished one: reply.id, reply.body

    graphql::stop(p);
    for w in ids { thread_wait(w); }
}
```

`serve<C>` is the worker's whole loop, and `C` is your change type. As with
`execute`, `batch` and then `type_of` can be left out. Replies come back
in the order workers finish them. Each carries the id that `submit` returned,
and the sample shows how to put them back in request order.

### What has to be flat

Workers can only copy flat globals: no references or slices anywhere inside,
including relative references. The compiler says so if you break this. In
practice:

* keep your data in global arrays of structs with inline strings (`u8[..k]`)
  and index links, as the sample does;
* make handles indices or keys, not references, because parts of split levels
  carry handles to other workers;
* the change type `C` must be flat too.

### Mutations and `sync`

Run a mutation on the main thread, against the main thread's copy of the
data, and record each change as you make it:

```goose
fn resolve(o: Obj.Mutation, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("rateBook") {
        let c = Rating { book: parse_book(f.string("id")), stars: f.int("stars") };
        apply(c);              // this copy, so the response shows it
        changes.push(c);       // every worker's copy, at the next sync
        r.object(Obj.Book { i: c.book });
    }
}

// in the server loop:
if graphql::is_mutation(request) {
    // wait for the replies to everything submitted before it, then:
    graphql::execute(request, Obj.Mutation, out, type_of) { o, f, r => resolve(o, f, r) };
    graphql::sync(p, changes);
    changes.clear();
}
```

`sync` does four things:
1. waits until each worker is between requests;
2. parks every worker;
3. hands each one the same changes to apply, in order;
4. returns once every worker has applied them.

Requests submitted before `sync` see the data as it was; requests after it
see the changes. A mutation's own response comes from the main thread's copy,
which is already up to date. For the copies to stay identical, `apply` must
be deterministic. Decide timestamps, random numbers and new IDs in the
resolver, put them in the change, and let `apply` only copy them in.

`sync` costs a few microseconds to some tens of microseconds per call with
idle workers; with busy workers it also waits for the requests in flight.
Batch changes where you can: one `sync` takes any number.

### Splitting large levels

When a worker reaches a level of objects whose estimated work (objects ×
fields below each) is at least `graphql::fork_min_fields` (default 4096), it
splits the level into parts of at least `graphql::fork_min_items` (default
16). It keeps the first part, offers the others to idle workers, and goes on
with its own levels. Each worker that takes a part runs that part's objects
through every level below them, calling the batch hook for them, and sends
back their JSON. Parts nobody took, the splitting worker runs itself at the
end. The response is byte for byte the one a single thread would give,
errors and null propagation included.

One level is split at a time across the pool. A worker that finds a split
in progress just runs its level itself. Set both thresholds before
spawning. Splitting pays only for a few thousand fields or more: a field
costs tens of nanoseconds, while handing a part to another worker costs
microseconds. With a backend, each part batches its own objects, so a split
level makes one backend call per type per level per part.

### What to expect

On a 10-core Apple M5 (4 performance and 6 efficiency cores), requests that
are heavy on resolver work and give small responses ran 2.1x faster on 2
workers, 3.6x on 4 and 6.2x on 8. Requests with half-megabyte responses
scaled to 2.5x on 4 workers and no further. At that size, copying the
response through the runtime's queue to the main thread is the bottleneck,
not running the query. A host that writes each worker's responses out
directly would not have that bottleneck.

---

## 10. Reference

All of these are in namespace `graphql`, except the resolver-facing calls,
which are global so that `f.int("x")` and `r.int(1)` work from your code.

| Call | What it does |
|---|---|
| `load_schema(sdl) -> u8[>..]` | Loads the program's schema; `""`, or why it did not load. |
| `execute(request, root, out, type_of, batch) { resolver }` | Runs a request; appends the JSON response to `out`. |
| `execute(request, root, out, type_of) { resolver }` | The same, with no batch hook. |
| `execute(request, root, out) { resolver }` | The same, for a schema without interfaces or unions as well. |
| `is_mutation(request) -> bool` | Whether a request is a valid mutation. |
| `pool(workers) -> Pool` | Starts a pool's bookkeeping; spawn the workers yourself. |
| `serve<C>(workers, root, apply, type_of, batch) { resolver }` | A worker's loop; `batch`, then `type_of`, may be left out. |
| `submit(p, request) -> i64` | Queues a request; the id its reply carries. |
| `receive(p) -> Reply` | The next finished reply: `.id`, `.body`. |
| `sync(p, changes)` | Brings every worker's data up to date. |
| `stop(p)` | Ends every worker's loop once the queued requests are answered. |
| `request_serial` | Changes with every request, for per-request caches. |
| `max_depth`, `introspection`, `fork_min_fields`, `fork_min_items` | Options; set them before spawning workers. |

| On a field `f` | |
|---|---|
| `f.is(name)`, `f.field_name()`, `f.parent_type()` | Which field, on which type. |
| `f.int(n)`, `f.float(n)`, `f.string(n)`, `f.boolean(n)` | An argument's value. |
| `f.has(n)`, `f.arg(n) -> Input` | Whether it has one; the value for inputs and lists. |
| `a.present()`, `a.int()`, `a.float()`, `a.string()`, `a.boolean()` | An `Input`'s value. |
| `a.member(n)`, `a.each() { it }` | An input object's field; a list's items. |

| In a batch hook, on `sel` | |
|---|---|
| `sel.type_name()` | The batch's object type. |
| `sel.has(name)` | Whether any of the batch's objects will be asked for that field. |

| On a result `r` | |
|---|---|
| `r.int`, `r.float`, `r.boolean`, `r.string`, `r.enum_value`, `r.json`, `r.none` | A leaf value. |
| `r.object(handle)`, `r.list() { ... }` | An object; a list. |
| `r.error(msg)` | A field error. |

### Limits

* No subscriptions, type extensions, `@oneOf`, or custom executable
  directives; custom directives in SDL are parsed and ignored.
* No check that fields merged under one response key are compatible, that a
  directive appears once per location, or that an input object literal names
  each field once.
* One schema per program, and one request at a time per thread: a resolver
  or a batch hook must not call `execute`.
* JSON in a request is parsed as the GraphQL value grammar's JSON subset:
  `\u` escapes, numbers and nesting as JSON has them.
