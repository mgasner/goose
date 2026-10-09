# Deferred calls: stored calls by defunctionalization

A *deferred call* is a call stored as data and made later: a function
plus some of its arguments, held in a variable, an array or a queue, and
called with the rest of its arguments when the program decides. This note
designs them for Goose without runtime function pointers, closures or a
new memory discipline. The compiler defunctionalizes: each deferred type
becomes an ADT whose variants are the calls the program stores, and
calling one is tag dispatch (spec §8.2). Everything the feature allows, a
hand-written enum and case functions would also allow. The new parts are
that the compiler writes those for you, and that the set of variants is
open across modules.

Status: implemented (spec §8.3; `src/deferred.h`; implementation notes
§3.12). The graphql library's deferred values are built on it
(`graphql.md` §5, `design/graphql.md` §5.2). Measurements are in §9.

## 1. Motivation

Function values are compile-time entities that cannot be stored (spec
§7.6). That rules out three patterns the current work runs into:

* **"Load, then transform."** A GraphQL resolver cannot ask a loader for a
  key and say what to do with the value once the batch arrives
  (`design/graphql.md` §5.1).
* **Handlers registered with a library.** An event loop (`design/http.md`)
  or a scheduler wants a table of "what to run when X happens" that the
  library owns and the program fills in. The library cannot name the
  program's functions, so the program has to own the dispatch.
* **Work queues.** A list of pending jobs of different kinds, each with its
  own arguments, run in order or handed to workers through `qput`.

All three can be written as an enum plus case functions. The library cannot
write that enum, though, because it does not know the program's functions,
and the program has to write one variant struct and one case function per
job kind.

## 2. The feature in one example

```goose
// A deferred type: what a stored call is called with, and what it returns.
deferred Job(now: i64) -> bool;

fn resize(img: i64, width: i32, now: i64) -> bool { ... }
fn expire(key: u8[], now: i64) -> bool { ... }

var jobs: Job..[>..] = [];
jobs.push(Job(resize, 17, 640));       // stores img = 17, width = 640
jobs.push(Job(expire, "session:42"));  // stores key

for j in jobs {
    if !j(clock()) { print("job failed") }   // calls resize or expire
}
```

* `deferred Job(now: i64) -> bool;` declares a nominal type. Its parameter
  list is the **call-time signature**: what every stored call of this type
  is called with and returns.
* `Job(resize, 17, 640)` is a **construction**. It names a **member**
  function and its leading arguments. The member's remaining parameters
  must be exactly the call-time signature.
* `j(clock())` is an **invocation**: tag dispatch to the member the value
  holds, with the stored arguments followed by the call-time ones.

## 3. Language rules

Spec §8.3 is normative; this section gives the reasons.

### 3.1 Declaration

```
deferred    := "deferred" declname "(" dparams? ")" ("->" rettypes)? ";"
```

A top-level declaration with the visibility, namespace rules and order
independence of `struct` and `enum` (§11.1). Every parameter has a type and
no default. Results follow `fn` declarations, multiple results and nonfixed
ones included (§7.1, §7.3). Parameters may be of any type a function
parameter may have: a call-time argument is passed at the call, never
stored, so references, slices and growable references (`u8[>..]&`) are all
fine.

A deferred type is an ADT type (§3.5) for size class, placement, modes,
copying and equality. `Job` is fixed mode, usable only when every member's
stored arguments are fixed-size. `Job..` is variable mode, sized to the
call actually stored. It has no variant names a program can write, other
than `empty` (§3.5): it cannot be `match`ed, and its variants cannot be
named as types.

There are no generic deferred types (§8.1).

### 3.2 Members and construction

`D(f, a1, …, an)`, where `D` names a deferred type, constructs a value of
`D`. `f` must be a function name, written as a function value is (§7.6),
optionally qualified (`image::resize`). Block literals are not members
(§8.2). `f` is a **member** of `D`, and must:

* be a top-level `fn` or `extern fn`: not nested, since a nested function's
  free variables are references into a frame that will be gone (§7.5), and
  not a `thread_fn`;
* have no type parameters and a type on every parameter, so its stored
  argument types are known without checking any body;
* have `n + k` parameters, where `k` is `D`'s parameter count, and its last
  `k` parameters must have exactly `D`'s parameter types, passing modes
  (`var`) included;
* return exactly `D`'s result types;
* take its first `n` parameters (the **stored parameters**) at **flat**
  (§1.1), non-resizable types.

Where `f` names an overload set, the overloads meeting the declaration-only
rules are candidates, and exactly one must be. The arguments `a1…an` are
then checked as the member's parameters, and every stored argument is
written: the member's defaults for them are not used (as in tag dispatch,
§8.2).

**Why flat.** A stored reference would be safe in principle, since the value
is an ordinary holder to the store rule (§9). But membership is open (§3.4),
so one member storing a reference would make every `D` value non-flat, and a
library's `qput` of its own deferred type would fail because of a program's
member. Requiring flat stored arguments keeps each deferred type's thread
and serialization properties under its declarer's control. §8.3 discusses
relaxing this.

**Fixed or variable.** One member storing a variable-size value (a `u8[]`)
makes fixed mode unavailable to the whole type, wherever it is used. The
error at a fixed-mode use names the member responsible. A library that
wants its tables of a deferred type in fixed mode says so in its
documentation (graphql's `Loader` and `Then` do).

### 3.3 Invocation

A call whose callee is a value of a deferred type is an invocation:
`j(now)`, `jobs[i](now)`, `conn.on_close(code)`, `make_job()(now)`. For a
UFCS-shaped call, fields are tried first (§7.1), so `conn.on_close(code)`
calls the stored field when `conn` has one by that name.

An invocation evaluates the callee once, then the call-time arguments in
order. It then calls the member the value holds, with the stored
arguments followed by the call-time ones. It is a tag-dispatched call in
every respect (§8.2):

* the arguments are evaluated before the tag selects a member, and no
  member's defaults are used;
* a nonfixed result is built at the call's destination by whichever member
  runs (§4.3);
* the result's roots are the merge of what every member returns;
* its effects are the union of every member's: shrinks, growths, stores
  and rebinds of globals, and of anything reached through call-time
  references;
* `return … from` works across it, since the call runs synchronously on the
  invoker's stack. A member may return from a function that encloses
  every invocation reaching it, exactly as a case function may (§7.9).

A variable-mode value in storage gives its member the stored payload where
it lies (the by-reference case set, §5.1), so an invocation never copies the
payload as a whole. A variable-size stored argument is still copied into
the member's by-value parameter at every invocation, as a direct call
would copy it: a stored parameter is flat, so it cannot be a slice viewing
the payload (§8.6). A large value is better kept in the program's tables and
stored as an index.

### 3.4 Open membership

A deferred type's members are every function that any construction in the
program names, in any module. The library declaring `D` need not know
them. Membership is decided from the source before type checking (§5.1),
so it is the set of constructions as written. A construction in a
generic function that is never instantiated, or in a function that is
never called, still makes its function a member. Such a member only takes
a tag value and, in fixed mode, may make the payload area larger.

### 3.5 The empty value

Tag 0 of every deferred type is reserved for the **empty** call, which has
no payload and is written `D.empty`. It is the type's zero value:
`default<D>()` (fixed mode only, as `default` is), a missed `qpoll<D>()`
(§11.2), a field of type `D` that a `..` construction leaves out. Invoking
it is a runtime abort, `invoked an empty D`, in every build mode, like an
index out of bounds (§9.3). Test for it with `j == D.empty`. Without this
reservation the zero value would be a call of whichever member received tag
0 with zeroed arguments, which is worse than an abort.

The aborting arm has a cost a hand-written enum without one does not: §9.

### 3.6 Recursion

An invocation is a call to every member. A member that can reach an
invocation of its own type, directly or through calls, is in a call cycle
through that invocation, and the rules of §7.8 apply as they do to any
cycle:

* the member must be declared `recursive fn` (members are already fully
  typed);
* no function in the cycle may have a nonfixed local in scope at the call
  into it, the invocation included.

The error names the member and the deferred type it is stored as. The
common shapes of the motivating uses form no cycle: a member pushing new
jobs onto the queue the driver loop is draining, or a handler registering
another handler. Only a member *calling* a deferred value of its own type
does.

### 3.7 Threads, queues and serialization

A deferred type is flat (stored arguments are flat), so its values can be
thread arguments and queue elements, and cross as a `memcpy` (§11.2).
Tags are global to the program, and a worker's program compiles the
members its invocations reach, so a job built in `main` and run in a worker
calls the same function, which reads the worker's own globals.

`from_bytes` has no verifier for any type that contains a deferred type (a
compile error). Its verifier would accept any in-range tag, so untrusted
bytes could choose which function the program calls next. Tag numbers also
change when members are added, so a saved image would not survive a
rebuild. `to_bytes` and `bytes_of` are allowed, for queues and for
debugging. A program that wants persistent jobs uses an ordinary enum.

### 3.8 Printing

`print`/`str` render a deferred value as the variant literal it is: the
member's name and its stored arguments, `resize { 17, 640 }`, and
`Job.empty` for the empty call.

## 4. Examples

**Load, then transform** (GraphQL). The library declares

```goose
namespace graphql;
deferred Loader(keys: i64[:]);
deferred Then(key: i64, s: Slot&);
fn ::later<O>(r: graphql::Result<O>&, l: graphql::Loader, key: i64, then: graphql::Then)
```

and calls each loader asked once per round, then every `then` in order
(`design/graphql.md` §5.2). The program writes

```goose
fn load_authors(keys: i64[:]) { /* one backend call */ }
fn author_name(key: i64, s: graphql::Slot&) { s.string(authors[key].name); }
...
r.later(graphql::Loader(load_authors), books[o.i].author, graphql::Then(author_name));
```

**Handlers registered with a library** (a scheduler,
`test/typing/deferred_lib/sched.goose`):

```goose
namespace sched;
deferred Task(now: i64) -> bool;
var pending: Task[>..<] = [];
fn after(t: Task) { pending.push(t); }
fn run_all(now: i64) -> i64 { ... if !pending[i](now) { failed++; } ... }
```

```goose
fn log_tick(id: i64, now: i64) -> bool { ... }
sched::after(sched::Task(log_tick, 1));
```

## 5. Compiler implementation

The design comes down to rewriting the program into an enum and case
functions that the existing checker, optimizer and backends already handle.
The new code is front end and checker hooks; the optimizer, bounds-check
elimination and the C backend are unchanged.

### 5.1 Front end

* **Lexer/parser** (`lexer.h`, `parser.h`). A `deferred` keyword and the
  declaration of §3.1, stored as an `SEnum` marked `isdeferred`, with its
  call-time `Param`s and result `TypeExpr`s, and a single variant, `empty`
  (tag 0). Constructions and invocations need no new syntax: `D(f, …)` is
  already a `Call` on an `Ident`, and `ParsePostfix` already parses a call
  on any expression. The dump prints the declaration as written.
* **Resolution** (`resolve.h`) rejects any written variant type or literal
  of a deferred type (`Job.resize { … }`), since none exists yet and none
  should be written.
* **Membership pass** (`deferred.h`, run by `main.cpp` after resolution and
  after `--roundtrip` has taken its dump, so the dump never shows generated
  code). It scans `Ast::allnodes`, which holds every parsed node in parse
  order, for a `Call` whose callee is an `Ident` naming a deferred type
  (`Ast::LookupEnum`) and whose first argument is an `Ident` naming a
  function. For each one it:
  1. picks the member by the rules of §3.2 that need only declarations
     (`Unfit`): arity, call-time parameter types compared by their
     resolved text, result types, top-level, non-generic, fully typed;
  2. finds or creates the variant for that `SFunction` (one per member,
     whatever the number of construction sites), whose fields are the
     member's stored `Param`s, sharing their resolved `TypeExpr`s. The
     variant is named after the member, with a suffix where two members
     share a leaf name;
  3. writes the member's **constructor** `deferred__D__new__f`, from the
     stored parameters to a `D` built as a variant literal, and rewrites the
     construction into a call of it.

  Per deferred type it writes the **case functions** `deferred__D__call`
  and `deferred__D__callref`, one per variant, taking the variant by value
  and by reference, then the call-time parameters. A member's case calls
  it with the payload's fields (non-scalar ones through `copy`, since a
  variable-size value is never copied implicitly, §4.1) and the call-time
  parameters; the empty call's aborts. Every generated function records its
  type and member (`SFunction::deferredof`, `dmember`, `isdctor`), and every
  call the pass resolved itself carries its target (`Call::pinned`), which
  the checker takes in place of the name's overload set, so no overload the
  program declares can capture it. Generated functions are registered in
  the type's namespace but are not top-level declarations, so neither the
  dump nor `CheckUnreached` sees them.

### 5.2 Typechecker

* **Constructor mode.** At setup, after every non-generic enum is
  validated, a constructor's result is made fixed-mode where every payload
  of its type is fixed-size, so a construction meets fixed-mode storage and
  `==` as a variant literal would; otherwise variable mode is the type's
  only mode.
* **Invocation** (`CheckInvocation`). A call whose callee is a variable
  (`CheckNamedCall`), a field (`CheckUfcsCall`) or any other expression
  (`CheckCall`) of a deferred type becomes a call of the by-reference case
  set, where the callee is variable-mode storage, or of the by-value set,
  with the callee as the first argument. Resolution finds no ordinary
  candidate and goes to `TryDispatch`, which finds exactly one case per
  variant by construction. Effects, result roots and destinations then come
  from the existing dispatch code.
* **Cycles** (`ValidateCycle`). A back edge through a case function, or to
  a member reached through one, reports the member and the deferred type.
* **Restrictions.** `BuildVariant` rejects a non-flat or resizable stored
  parameter at the member's declaration; `ValidateType` names the member
  that makes fixed mode unavailable; `VerifiableElem` refuses a deferred type
  to `from_bytes`; `CheckMatch` refuses a match, and `CheckVariantConst` any
  variant name but `empty`.

### 5.3 Optimizer, BCE, codegen and runtime

No changes. Case functions are a single call and are inlined at `-O1`, so
the dispatch switch calls each member's body directly; the empty arm is a
call of `gs_abort_msg` through the `abort` builtin. Layout, construction,
copying, equality, queues and `to_bytes` are those of the enum the type has
become (spec C.2), with one tag value more than the member count.

### 5.4 What it took

About 550 lines of compiler: the membership pass (330 lines with its
comments), the parser, AST and dump (about 90), and about 130 in the
checker, spread over the hooks above. The graphql library's deferred values
are about 170 lines of Goose.

## 6. Testing

* `test/typing/deferred_calls.goose`: fixed and variable mode; arrays,
  fields and call results invoked; multiple and nonfixed results built in
  place; call-time builders and slices; equality and printing; a library
  type filled by the program (`deferred_lib/sched.goose`), whose members
  schedule more; `return … from` through an invocation; a recursive member.
* `test/threads/deferred_queue.goose`: jobs across a queue, run by a worker
  against its own globals.
* `test/runtime/deferred_empty.goose`: the empty value from `D.empty`,
  `default<D>()` and a missed `qpoll`, and the abort.
* `test/stdlib/stdlib_graphql_later.goose`: graphql's deferred values.
* `test/errors/` (resolution) and `test/errors_tc/` (checking),
  `deferred_*.goose`: a generic declaration, a parameter default, a written
  variant type or literal, a nested, generic, `thread_fn` or ambiguous
  member, a wrong tail, result or count, a non-flat stored parameter, a
  block, `match`, a variant name, fixed mode with a variable-size member,
  `from_bytes`, a self-invoking member not declared `recursive`, and one
  holding a nonfixed local across the invocation.
* `--roundtrip` covers the dump of every fixture above.

## 7. Alternatives considered

* **Structural types** (`later fn(i64) -> bool` as a type, with no
  declaration). Every stored call with the same signature anywhere in the
  program would share one variant set and one fixed-mode size, so an
  unrelated module could make every other one's values large. A nominal
  declaration scopes that.
* **Membership inferred during type checking.** This would allow generic
  members, but an invocation's effects and result roots depend on every
  member, and a member found after an invocation was checked would require
  rechecking the whole program in rounds. Deciding membership from the
  source avoids this, at the cost of the restrictions in §3.2.
* **Rewriting constructions into variant literals** rather than constructor
  calls. A literal adapts to its destination's mode by itself, but the pass
  would have to replace a node inside its parent, and no pass has a
  replacing walk; a constructor is a call, which the `Call` node already
  is. The optimizer inlines it.
* **Runtime function pointers.** These would remove the closed set and the
  dispatch, but also inlining, the static effect union that keeps
  invocations sound against shrinks, and the static call graph that the
  stack assignment and the `return from` checks rely on.

## 8. Open points

1. **Generic deferred types** (`deferred Then<O>(r: Result<O>&)`). They would
   let graphql's `then` give objects. Membership per instantiation needs the
   type arguments at the construction; they could be inferred from the
   member's signature, which names them, by matching it against the
   declaration. Each instantiation would then be its own closed set,
   canonicalized where the checker substitutes type arguments.
2. **Block members with explicit captures**:
   `Job(id: i64 = obj.id) { now => ... }`, hoisted by the membership pass
   to a top-level function with the captures as its stored parameters.
   Capture types must be written, since the pass runs before checking.
3. **References rooted at globals or static data** as stored arguments, the
   restriction `return from` already uses for its in-flight values. They are
   useful for handles into long-lived tables, but give up flatness for the
   whole type (§3.2). Possibly opt in per declaration.
4. **Size visibility.** In fixed mode, one member with a large stored
   payload makes every slot large. A note naming the largest member when a
   fixed-mode type exceeds some size would make this visible.
5. **Stored-parameter defaults.** These could be allowed, evaluated at the
   construction. They are left out because a default resolves in the
   member's namespace and environment, not the construction's.
6. **Viewing a stored array.** A stored parameter declared as a slice could
   store a copy of what it views and be passed a view of that copy, so a
   member reads a stored string without copying it per invocation.
7. **The empty arm's codegen.** Clang turns a dispatch whose arms are all
   small arithmetic into branch-free selects, and does not once one arm can
   abort (§9). Emitting the empty check as its own predicted branch ahead
   of the switch recovered part of the difference by hand; a backend hint
   that the arm is cold might recover the rest.

## 9. Measurements

`bench/deferred/` (`deferred_bench.py`; results in `results.md`) measures
two things: a stored call itself, against hand-written Goose enums, C++ and
Rust, and graphql's deferred values against the batch hook and graphql-js
with DataLoader.

**Stored calls.** Four kinds of call with 1-8 bytes of stored arguments,
chosen at random, 10^8 invocations at each of three sizes. A deferred call
takes 9 bytes; C++'s `std::function` 32, a `unique_ptr` to a virtual object
24 plus its heap block, `std::variant` and Rust's enum 16, Rust's
`Box<dyn Fn>` 16 plus its heap block. Building a deferred call costs what
building an enum does, a fraction of the heap-allocating forms. Invoking one
costs the same as the hand-written enum with an aborting empty arm, and less
than every C++ and Rust form. The hand-written enum *without* that arm is
faster on unpredictable sequences: clang compiles its four tiny arms into
branch-free selects, which the aborting arm prevents (§8.7).

In numbers (Apple M5, clang 21, rustc 1.81), nanoseconds per call at
n = 1,000 / 100,000 / 10,000,000: deferred 0.68 / 3.00 / 3.77, the enum with
the arm 0.68 / 2.96 / 3.74, the enum without it 1.30 / 1.30 / 1.33; the best
C++ form 1.30 / 4.68 / 4.73 and the best Rust one 0.99 / 4.24 / 4.72. At
10^7 calls the deferred program peaks at 87 MB, Rust's enum at 156 MB and
`std::function` at 819 MB.

**GraphQL.** `r.later` makes the same backend calls as the batch hook, one
per loader per round: 2 per request for 1,000 books against 266 resolving
naively. On a free backend it costs 6% more than the hook (146 µs against
137 µs per request, about 4 ns per deferred field); with a 20 µs backend
call the two are equal (180 µs). graphql-js with DataLoader makes the same
2 calls in 2,645 µs and 3,007 µs.
