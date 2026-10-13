# GraphQL — Design

Status: implemented in `stdlib/graphql/`. [`../graphql.md`](../graphql.md)
is the user's guide. This document records the design: why it has this
shape, what was measured, and where the implementation departed from the
first proposal.

`import graphql;` is a GraphQL **server-side engine**. It parses a schema
written in SDL, parses and validates requests against it, executes them by
calling the program's own resolvers, and writes the JSON response. It runs
requests on a pool of shared-nothing workers. It does no networking: it
takes request bytes and appends response bytes.

---

## 0. Summary

The usual GraphQL server has five parts that do not fit Goose:

* a resolver map from `(type, field)` to closures;
* a response tree of dynamically typed values, which is then serialized;
* executor recursion that holds allocations at every level;
* batching through DataLoaders: promises, and an event loop that flushes
  them;
* parallelism through threads that share the data.

Goose has no runtime function values, no heap, restricted recursion and no
shared memory. Each part is replaced with something that fits:

| Usual design | This design |
|---|---|
| Resolver map of closures | One resolver **function value** (the trailing block), which dispatches through **case functions** over a user enum of object handles (§3) |
| Response tree, then serialize | Resolver results kept as flat **entries**, then written as JSON in one depth-first pass. Null propagation **truncates** the output back to a watermark (§5) |
| DataLoaders over promises | **Breadth-first resolution**: a level of objects at a time, with one **batch hook** call per object type per level, before that level's resolvers (§5.1) |
| Exceptions or `Result` for errors | Field errors are values. Non-null propagation is **`return … from`** to the nearest nullable position (§5) |
| Per-request allocation, GC | Per-request rows sit above the schema's in flat global tables and are **truncated** when the request ends (§6) |
| Threads over shared data | **Shared-nothing workers**, each with its own copy of the data. Mutations are **replayed** on every copy, and large levels are **split** across workers (§8) |

Resolvers and batch hooks are called from a loop, not from inside a
recursion. So **user code needs no `recursive` and can build temporaries
freely.**

---

## 1. The shape of a program

```goose
enum Obj { Query, Book { i: i64 }, Author { i: i64 } }

fn resolve(o: Obj.Book, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("title") { r.string(books[o.i].title); }
    else if f.is("author") { r.object(Obj.Author { i: books[o.i].author }); }
}
// ... one resolve per variant ...

fn type_of(o: Obj) -> const u8[:] { match o { Book => "Book", Author => "Author", _ => "Query" } }

fn batch(objs: Obj[:], sel: graphql::Selection&) { /* one backend call per table the level needs */ }

graphql::execute(request, Obj.Query, out, type_of, batch) { o, f, r => resolve(o, f, r) };
```

[`samples/32_graphql.goose`](../../samples/32_graphql.goose) is a whole
server, with a pool.

---

## 2. The schema

`load_schema(sdl)` parses SDL into flat global tables:
- types, fields, input values, enum values, type references, union members,
  implemented interfaces, and directives, all linked by index;
- names and strings in one text arena.

It parses a built-in SDL first, which provides the scalars, directives and
introspection types. Then it parses the program's SDL and resolves every
name. A hidden `__Meta` type holds the definitions of `__schema` and
`__type`, so they are validated like any other field.

Why SDL text rather than a Goose description:

* **There is no reflection.** A schema cannot be derived from the program's
  types.
* **Codegen needs a build step,** and Goose has none.
* SDL is what GraphQL users write and what tools exchange, and introspection
  has to reproduce it anyway.

Why **flat global tables** rather than a schema value with relative links (the
first proposal):

* **Workers copy flat globals at spawn** (spec §11.2). A schema loaded in
  `main` before the pool starts is therefore in every worker for free.
  Relative references are not flat, so a self-relative schema pool could not
  cross.
* **A struct can own one resizable array,** and the schema has a dozen
  tables. Globals hold any number.

---

## 3. Binding program data to GraphQL types

**Handles.** A parent value is a user-defined **fixed-mode enum `O`**, one
variant per object type. A payload holds whatever reaches the object, usually
an index or a key. The executor never copies an object; fields are read on
demand through the handle. The library wraps handles as `Handle<O>`, whose
second variant holds introspection's own handles. Introspection therefore
runs through the same executor and type checks as the program's fields.

**The resolver** is one function value `F(o: O, f: Field&, r: Result<O>&)`,
passed as the trailing block. **A function value cannot be an overload set**
(the compiler says so), so case functions cannot be passed directly. The
block `{ o, f, r => resolve(o, f, r) }` does the dispatch: calling a case
function set with an `O` jumps on its tag. That costs one line, and
exhaustiveness is still checked. For the same reason **`type_of` is one
function**, usually a `match`. It is passed before the block, because only
the last function value can be a trailing block.

**The resolver-facing API is global.** UFCS looks up a function in the
caller's namespace (`namespaces.md`). `graphql::int(r, 5)` would work, but
`r.int(5)` only works if `int` is visible from the user's namespace. So
`stdlib/graphql/api.goose` declares those calls `fn ::int(...)` and so on,
overloads that take only graphql's own types. Inside the library they are
thin wrappers over `graphql::` functions.

**Field selection by name.** `f.is("title")` compares the field's schema
name. That is a short string compare per field per object, measured below
as part of a whole request at well under the queue costs that decide
parallelism.

---

## 4. Requests

`prepare(request)` runs the whole front end, which ends with `cur_op`
selected or with errors:
1. the envelope, parsed by `json::parse`, its variables copied from the
   document's tape into the value table;
2. the document;
3. validation of every operation and fragment;
4. selecting the operation;
5. coercing the variables.

Parsing GraphQL follows `18_json`: a lexer over a global `source`, recursive
descent, and every syntax error one `return false from parse_source`. JSON
is the `json` module's (`json.md`). Validation
reports every error it finds, with graphql-js's messages and with
locations. Variables are coerced in place: an ID given as an integer becomes
a string, and an enum given as a JSON string becomes an enum value. That is
why argument accessors in resolvers can read values directly.

Validation also computes, per selection, the number of fields at and below
it. The executor uses that number to decide whether a list is worth splitting
(§8). It is not a security limit; `max_depth` is. Execution depth consumes
native stack, so a document deeper than `max_depth` is rejected before
anything runs.

Not implemented: the OverlappingFieldsCanBeMerged rule (where merged fields
differ, the first wins), UniqueDirectivesPerLocation, UniqueInputFieldNames,
subscriptions, and type extensions. Schema loading checks names, kinds, root
types, union members, and that every implemented interface's fields exist on
the implementing type, but not that their types are compatible.

---

## 5. Execution, output, errors

Execution has two phases.

**Phase 1 resolves, breadth-first, without recursion.** Objects are rows of a
`nodes` table; each holds its handle and its **plan**. A plan is the fields
an object of one type runs, collected once from its merged selection sets.
Every object of a type reached through the same field gets the same plan, so
`collect` runs once per (field, type), not once per object. Each level:

1. call the batch hook once per object type (§5.1);
2. for each node, for each field of its plan, call the resolver. A resolver
   answers by appending **entries** (scalars, an object handle, list
   brackets, an error), with string payloads in a text table beside them;
3. check that the resolver gave exactly one value, and record where it starts;
4. make every object entry a node of the next level, with its runtime type
   (from `type_of` for abstract types) and its child plan. A `type_of` that
   names no possible type turns the entry into a field error.

A mutation's top-level fields run one at a time, each with all the levels
below it, as the spec's serial execution requires.

**Phase 2 writes, depth-first.** It walks from the root node, writing JSON,
and checks every entry against its field's declared type. A resolver bug
therefore becomes a field error naming the field. **Null propagation** works
with watermarks and a long-distance return:

* A nullable position runs inside `nullable`. It records the lengths of the
  response and of the path, then calls `guarded`.
* A non-null violation anywhere below is **`return false from guarded`**,
  which lands at the innermost active `guarded`, the nearest nullable
  position.
* `nullable` sees `false`, **truncates the response and path back** and
  writes `null`.

Phase 2 reads only the stored entries, never calling user code, so it is not
generic, and only the response and path need restoring. In the first,
depth-first executor, resolvers ran inside the recursion and scratch tables
had to be restored as well. The frames that `return from` skips never reach
their own truncations, so the catcher has to restore everything they touched.

Field errors are recorded in phase 2, in its order, so they come out exactly
as they did from the depth-first executor. That includes not reporting
errors under a position that an earlier violation nulled. Phase 1 does
resolve those subtrees; only failure cases pay for that, as in graphql-js.
Each error has `message`, `locations` and `path`. **Request errors** produce
`{"errors":[...]}` with no `data`.

**`guarded` is one function with a mode,** a value or a whole object. The
first executor had overloads of `guarded`, and `return … from guarded` landed
at the root overload instead of the innermost call (§10).

**Cost.** Against the depth-first executor on in-memory data: a 583 KB
response 5–7% faster, a 23 KB response 4–20% faster, CPU-bound requests the
same, and requests of a few fields 0.15 µs slower (0.57 → 0.72 µs), from
building the plan and node tables. Results stay in memory until phase 2,
about the size of the response.

### 5.1 Batching

DataLoader batches by *demand*: resolvers ask a loader for keys, the loader
waits for the event loop to drain, then makes one call. That needs promises,
continuations and an event loop. Goose has none of them: function values
cannot be stored.

Here the handles already are the keys. A field that gives an object gives
its handle, usually an id, and loads nothing. The data is needed when the
*next* level's fields run on those objects. So batching becomes a schedule
rather than a mechanism: phase 1 has the whole next level before any of it
runs. It calls

```goose
batch(objs: O[:], sel: graphql::Selection&)
```

once per object type on the level, with every handle of that type, before
resolving any of them. `sel.has(name)` is lookahead: whether any of those
objects will be asked for a field. The hook can then fetch only what the level
needs, including per-object lists such as an author's books, as one query for
all the level's authors. The program keeps what it loads in its own flat
tables, so workers can copy them. Skipping keys already loaded gives
DataLoader's per-request cache. `request_serial` tells a cache when a new
request has started.

What it gives up against DataLoader: a resolver cannot defer a value until a
batch it asked for comes back ("load, then transform"), because that needs
a stored continuation. A loaded value is either a field of an object the next
level reaches, or the object itself, so this has not been needed. A deferred
entry ("key K of loader L, filled in at the end of the level") would fit the
entry model if it ever is.

`stdlib_graphql_batch.goose` checks the schedule:
- one call per type per level, also for a union list;
- lookahead skipping a table no field reads;
- the cache answering a later level;
- introspection objects never reaching the hook;
- batching inside the parts of a split level.

---

## 6. Memory

The library's state is flat global tables: the schema's rows, then each
request's rows above them, truncated when the request ends. Per-request
rows include the document, plans, nodes, entries and the response. This
differs from the first proposal, where per-request tables were locals of
`execute`, and for the reasons of §2. Workers must be able to copy
everything, and the recursion rules make many tables easier as globals than as
a struct of references.

The schema and the program's data outlive every request. Freeing a request is
a handful of `resize` calls. Only phase 2's native stack grows with query
depth, and `max_depth` bounds it. Handles and the program's data never move.

A consequence is that **one request runs at a time per thread**, and a
resolver or batch hook must not call `execute`. Each worker is a thread with
its own copy, so this does not limit the pool.

---

## 7. Introspection

`__typename`, `__schema` and `__type` come from a built-in resolver over the
schema tables, using `Handle<O>.Meta`. The introspection types are ordinary
types of the built-in SDL, so validation, fragments and type checking work on
them unchanged. `introspection = false` turns `__schema` and `__type` into
unknown fields.

---

## 8. Parallelism

### What was measured

These measurements, on a 10-core Apple M5, decided the design:

| | |
|---|---|
| Serial executor, per field, including JSON | about 13 ns |
| One queue round trip, main → worker → main | about 4 µs, the cost of about 300 fields |
| One field per queue job, 8 workers | 358 ns per field, worse than with 1 worker (one mutex per queue type) |
| Jobs of 4096 fields, 8 workers | 0.19 ns per field, 4.9x serial |

**One job per field, through a shared queue, is 150–400x slower than serial.**
Workers also cannot see `main`'s data, since only flat globals are copied at
spawn. Queues are addressed by type, not by worker, so results cannot be
routed or broadcast. Field-level parallelism was therefore rejected. What was
built:

1. **Request-level parallelism (the default).** Every worker runs the whole
   engine on its own copy of the schema and the data, which it got at spawn.
   `submit` puts a request in the shared inbox and `receive` takes the next
   finished reply.
2. **Splitting a large level, for latency.** When a worker reaches a level of
   objects whose estimated work is at least `fork_min_fields`, it splits the
   level into parts (§8.2).
3. **Mutations replayed on every copy** (§8.1).

Measured on the sample's catalogue:
- requests heavy on resolver work with small responses: 2.1x on 2 workers,
  3.6x on 4, 6.2x on 8;
- requests with 583 KB responses: 1.7x on 2 workers, 2.5x on 4, and 1.5x on 8.

At that response size, copying through the runtime's queue to the main thread
dominates: one `malloc` per message, and one consumer. A runtime queue that
reused large buffers, or a host where workers write their own responses,
would remove that bottleneck.

### 8.1 Keeping copies in step: `sync`

Each worker's data is a copy, so a write has to reach every copy. The program
runs a mutation on the main thread and records each change as a flat value
`C`. `sync(p, changes)` then broadcasts the changes using typed queues alone,
which cannot address a worker:

1. take the split token (no split is then in flight);
2. put N `Msg.SYNC` in the inbox; each worker that takes one replies `Ack`
   and blocks on `qget<Go<C>>`. A parked worker takes no other `Msg`, so the N
   messages land on N different workers;
3. collect N `Ack`s; now every worker is parked between requests;
4. put N `Go<C>` holding all the changes; each parked worker takes exactly one
   and applies them in order;
5. collect N `Applied`. Without this step, a fast worker that has applied its
   changes can take the *next* `sync`'s SYNC and then a slow worker's leftover
   `Go` from this round, applying one round twice. The test suite caught this
   with two mutations in a row.

Requests submitted before `sync` are answered from the old data: they sit
ahead of the SYNC messages in the FIFO inbox. Requests after it see the new
data. A barrier and broadcast across 8 idle workers measured 4–73 µs (before step 5
was added, which costs one more round trip). `apply`
must be deterministic so the copies stay identical. This is state-machine
replication, with the main thread as the single writer.

### 8.2 Splitting a level

With breadth-first resolution, the unit of work to split is a level of
nodes, not a list. At the start of each level, `split_level` checks:
- the level has at least `2 × fork_min_items` nodes, all of them the
  program's;
- the sum of their plans' costs (fields at and below, from validation) is at
  least `fork_min_fields`.

If so, the worker tries to take the one **split token** (`qpoll<Token>`). If
another worker holds it, the level just runs here. Holding the token, the
worker:

* keeps part 0. For each other part it marks the nodes as sent and puts one
  `Chunk<O>` in that type's queue: the request text, the part's distinct plans
  as (type, selection sets), each node's plan, and the handles. It then puts
  one `Msg.WAKE` per part in the inbox;
* carries on with its own levels. Sent nodes are skipped by the batch hook
  and by resolving;
* at the end of phase 1, runs here any chunk still in the queue, as a fresh
  frontier, so its objects batch together. It then collects a `ChunkDone` for
  each part a worker took and returns the token.

A worker that takes a part parses the request again. Parsing is
deterministic, so every selection row and name means the same. It rebuilds the
part's plans and runs both phases for the part's objects: its own levels, its
own batch hook calls, and its own phase 2 for each object. It sends back, per
object, the JSON, whether a non-null failure nulled the object itself, and
the errors. Those errors' paths start with a mark (`PATH_MARK`) where the path
to the object goes.

In phase 2 the splitter reaches each sent object at its place in the
depth-first walk. It appends the object's errors with the mark replaced by
its current path, then either writes the JSON or raises `return false from
guarded` as the object's own non-null failure would have. Errors and output
therefore come out **byte for byte as on one thread**, in the same order.

Only the token holder splits, so every `ChunkDone` belongs to it, with no
routing needed. `sync` takes the token first, so no worker is ever parked
while a split waits on it. A worker handling `WAKE` finds either a chunk or
nothing (the splitter ran it already). Nothing ever waits on a part no one
will run. One level per request is split; a part never splits again.

### 8.3 Not done: memoizing repeated fields

A field reached by several paths for the same object, such as friends of
friends, could be cached per request by (handle, field, arguments), or as a
byte range of the response for (handle, selection). It is not implemented:
- at about 13 ns per field, a lookup costs about as much as the field;
- it is only correct for pure resolvers, so it would need an opt-in per field.

It belongs with resolvers that do I/O, when there are some to measure.

---

## 9. Transport

The library stops at bytes. Two ways to serve them:
- stdin/stdout, as in the sample;
- a C host calling an `export fn` wrapper on the thread that ran
  `goose_init`.

A multi-core C host would run the pool and move bytes in and out of the main
thread. The bottleneck at large response sizes (§8) argues for letting workers
write responses themselves, which needs per-worker I/O through `extern fn`.

---

## 10. Open questions and follow-ups

1. **`return … from` an overload set.** With two overloads of `guarded`,
   `return false from guarded` lands at the innermost active call of the
   overload that encloses *every* compile-time path to the return (here the
   root one), not at the innermost active call of *any* function in the set,
   as `namespaces.md` specifies. A 40-line reproduction prints
   `{"data":null}` where `{"data":[[null]]}` is expected; with the root
   overload renamed, the compiler rejects the program instead, because some
   path then has no `guarded`. That looks like a compiler bug. The library
   uses one function, so it is not affected.
2. **A queue that reuses buffers** for large messages, to lift the
   response-size bottleneck.
3. **Field ids.** If profiles ever show `f.is(...)` string compares, the
   schema can number fields and expose `f.id`.
4. **Overlapping-fields validation**, subscriptions, type extensions, `@oneOf`.
5. **A `json` module.** Done: `stdlib/json` parses the envelope and writes
   strings and floats (`json.md`). Resolvers could also take a
   `json::Writer` for custom scalars, in place of `r.json(text)`.
6. **Shared read-only snapshots** across workers would remove the per-worker
   copies. This is a language question (spec appendix B, item 9).
7. **Deferred loads**, if a case turns up that the batch hook cannot serve
   (§5.1).
