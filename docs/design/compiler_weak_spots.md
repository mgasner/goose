# Compiler weak spots found while writing the HTTP parser

Status: items 1–5 and 7 are fixed on `weak-spot-fixes` (the commit is
named under each); item 6 is open, with the options written up under it.
Each item was reproduced against the compiler at `20ebab6`. Fixing item 1
also turned up two soundness bugs in the same analysis, fixed alongside
(see "Found while fixing" at the end).

Writing an HTTP/1.1 request parser in Goose (`stdlib/http.goose`, in
progress), and benchmarking it against picohttpparser, turned up the
following weak spots. None of them is a correctness bug. Each one either
cost measurable time in a hot loop or forced code into a less natural
shape. The parser works around each one, and the workarounds are noted
below so they can be removed once the compiler handles the case.

The one correctness bug found in the same work, a `thread_spawn` whose id
is unused never running, is fixed separately: PR #2,
`fix-discarded-thread-spawn`.

Bounds-check results come from `goose -O2 --bce-lines`. Timings are on an
Apple M5 with clang 21, `-O2`.

## Bounds-check elimination (§10.5)

These extend TODO 0f.

### 1. One non-unit step disables a counter's invariants function-wide

A counter that is also stepped by more than 1 anywhere in the function
loses its inferred invariants (`v >= 0`, `v <= len`). Checks are then kept
in *every* loop over it, including loops that come before the large step
and are unaffected by it:

```goose
fn f1(s: const u8[:]) -> i64 {
    let n = s.len; var i = 0;
    while i < n { let c = s[i]; if c == 32 { break; } i++; }   // kept
    loop { if i + 2 > n { return 0; } if s[i] == 13 { i += 2; break; } i++; }   // kept
    return i;
}
fn f2(s: const u8[:]) -> i64 {                                  // the same, with a second counter
    let n = s.len; var i = 0;
    while i < n { let c = s[i]; if c == 32 { break; } i++; }   // elided
    var j = i;
    loop { if j + 2 > n { return 0; } if s[j] == 13 { j += 2; break; } j++; }   // kept
    return j;
}
```

The write `i += 2` is guarded: `i + 2 <= n` holds just before it, so it
preserves `i <= n`. The recording pass that infers invariants (bce.h,
"Loops") does not seem to use the guard's fact when it judges a write. So
the counter stops being eligible, and the loss reaches every use of it, not
just the code after the write.

Even standing alone, as `j` in `f2`, the guarded loop keeps its check. The
guard forms `i + 2 > n`, `n - i < 2`, `i + 1 >= n` and `i >= n - 1` all
behave the same once the counter steps by 2.

*Where it bit:* the request parser stepped one cursor over the method, the
target, the version and every header line. Lines end in CRLF (`i += 2`).
With that one cursor, a test program built around the parser had 1 of its
52 index checks elided.

*Workaround:* re-slice instead of advancing a cursor. Each scan runs a fresh
`var k = 0` that only does `k++` over the remaining input `r`, and then
`r = r[k + 1..]`. This removes every check in the scan loops.

**Fixed** in `ac0a576`. The recording pass is now ordinary induction, as
it already was for globals: every candidate invariant is assumed while each
write is checked, a write that fails drops its candidate, and the pass
repeats until a walk drops nothing that any query used (at most 8 rounds,
then one pass that assumes nothing, the old behavior). A `var + const`
comparison side is admissible where the facts show the i64 addition did not
wrap, and `x - y` against a constant is the difference constraint it is
where the subtraction is exact, so all four guard spellings above work.
`f1` and `f2` keep no checks; `bce_guarded_step*` has them, and negatives
(a guard one short of the step, an unguarded step, a guard on a counter
nothing bounds, which wraps) that keep their checks and fire at run time.
A cursor-style `parse_head` (one `i` over method, target and version, with
`i += 10` behind `if i + 10 > n`) has every index check elided; the HTTP
parse benchmark's index checks went from 34/61 to 41/61 elided with
items 1–5 applied (the four-wide loop in `span` is item 1's), and suite P
got 10–23% faster with them (P3 122 → 105 ns, P5 headers-32 336 → 259 ns;
indicative, since the machine was loaded). The cost is compile time: the analysis takes up to about twice as
long on some files (stdlib_std: 0.044 → 0.069 s for `--check`; the
Goose-in-Goose compiler 1.1×).

### 2. A table lookup nested in another index keeps its check

```goose
const T: u8[256] = [1; 256];
fn a(s: const u8[:]) -> i64 { var i = 0; while i < s.len && T[s[i]] != 0 { i++; } return i; }    // T[...] kept
fn b(s: const u8[:]) -> i64 { var i = 0; while i < s.len { let c = s[i]; if T[c] == 0 { break; } i++; } return i; }  // elided
```

A `u8` local gets the storage-range axiom `0 <= c <= 255`, so `T[c]`
against a `T[256]` is proven. The same `u8` value as an inner index
expression, `s[i]` loaded from a `u8` slice, does not, even though its type
gives the same range.

TODO 0f says "a value loaded from an array has no known range". That holds
for wide element types. For elements narrower than 64 bits, the range the
type gives could be applied to the loaded value itself.

*Workaround:* bind the byte with `let`.

**Fixed** in `46cdba2`. An element or struct field narrower than 64 bits,
loaded from memory, gets a one-shot base carrying its type's range, as a
variable of that type does. `bce_narrow_load*` covers `u8`, `u16` and
fields, and negatives: a 255-entry table (whose check fires on the byte
255), a signed byte, and a 64-bit element.

### 3. `i == n` does not combine with `i <= n` into `i < n`

```goose
fn f(s: const u8[:]) -> i64 {
    let n = s.len; var i = 0;
    while i < n { let c = s[i]; if c == 32 { break; } i++; }
    if i == n { return 0; }
    return s[i];                 // kept; with `if i >= n` instead, elided
}
```

After the loop, `i <= n` holds (it is the loop's invariant). The negation of
`i == n` is `i != n`, which a difference domain cannot state. The common
"scan, then look at the stopping byte" idiom keeps its check unless the
test is written `>=`.

*Workaround:* write `if i >= n`.

**Fixed** in `6760b2c`. A `!=` fact (an `==` test's false side) now makes
a bound the facts already prove strict: `i <= n` and `i != n` give
`i < n`. It is tried only where a side is a length or a variable that
indexes or bounds an array, which keeps its two queries off a parser's
many character tests. `bce_neq_strict*` covers both operand orders and a
`while i != 0` loop, and negatives where `i <= n + 1` or nothing bounds `i`
(the first fires at run time). It also elided checks in `14_bst`,
`25_serialize`, `31_mini_doom` and some lifetime tests.

## Code generation

### 4. Building a struct with a limited array writes the array's whole capacity

§4.2 says that building a limited array writes only its metadata, and that
the free slots stay uninitialized. A struct literal with `..`, or with such
a field defaulted, does not do that:

```goose
struct H { a: const u8[:], b: const u8[:] }
struct R { n: i64, hs: H[..64] }
fn main() { for i in 3 { var r = R { .. }; fill(r, i); ... } }
```

That compiles to:

```c
t3 = (R_g){0};                 /* the whole struct, 2 KB */
memset(&t4, 0, sizeof(t4));    /* each field's default in a temporary ... */
t3.n_g = t4;
memset(&t5, 0, sizeof(t5));    /* ... including all 64 slots of hs */
t3.hs_g = t5;
r_g = t3;                      /* then the struct is copied into place */
```

Once `r`'s address escapes (it is passed by reference, as every caller of a
parser does), clang removes none of it. The work is a 2 KB zero-fill, a
2 KB memset and two 2 KB copies.

*Where it bit:* `http::Request` holds `Header[..64]`. Building one per
request cost about 15 ns, as much as parsing a small request (P1: 28 ns
against 13 ns with the `Request` reused).

*Expected:* for a limited array, store only the length (and the capacity,
for `T[..]`). For a fixed-size struct literal, build in place in the
destination rather than in a temporary that is then copied, as §4.3
already requires for non-fixed values.

*Workaround:* `parse` resets a `Request` it is given, and callers build one
per batch of input.

**Fixed** in `f208dac`. A struct or array literal initializing a local
builds in the local, and in a destination nothing else reads while it is
built (a new local, a literal's own temporary, or a resizable struct, whose
whole assignment may not name what it replaces) a field's literal, string
literal or default builds in the field. A limited array writes its length
only; its free slots stay uninitialized, except under MSVC, where the
runtime's `GS_UNWRITTEN` zeroes them, since the zero-filled temporaries were
working around an MSVC miscompile of copied partially written structs
(Appendix E). `var r = R { .. }` above is now `r.n = 0; r.hs.len = 0;`.
Assigning a fixed struct whole still goes through a temporary, since the
literal may read what it replaces. On suite P with a `Request` built per
request, P1 went from 26.0 to 11.3 ns, the same as reusing one.
`limited_inplace` checks the C with the test runner's new `// c-has:` and
`// c-lacks:` markers.

### 5. `const` tables are emitted as writable `static` data

```goose
const T: u8[4] = [1, 0, 1, 0];
```

That emits:

```c
static a4_u8 T_g = { { 1, 0, 1, 0 } };
```

There is no `const` in the C. §1.2 calls these read-only static data. Without
the qualifier, the C compiler cannot assume the table never changes. It has
to load from a writable section, and it cannot fold a lookup with a constant
index. The fix should be just a matter of emitting `static const`.

**Fixed** in `824c728`. The table is `static const`, read through a
non-const lvalue `(*(T *)&name)`, so slices and references of it keep the
runtime's unqualified types without qualifier warnings; clang still folds a
constant-index lookup through the cast, even once the table's address has
escaped. `const_tables` checks the C.

## The checker: shapes it forces on APIs

### 6. A call that both shrinks an array and stores slices of it

```goose
fn fetch(buf: u8[>..]&, rep: Reply&) { buf.clear(); ...; rep.body = buf[i..j]; }
...
fetch(buf, rep);
print(rep.body);      // error: fetch shrinks buf while rep is still used
```

The callee clears `buf` *before* storing new slices of it into `rep`, so
`rep` never holds a stale slice. The call summary records "shrinks `buf`"
and "stores into `rep`" without their order, so the call is rejected
whenever `rep` is used afterwards, which is the reason `rep` exists. The
same pattern rejects a caller that reuses one `rep` across requests.

*Workaround:* `http::fetch` never shrinks the buffer. It appends the request
and the response, and the caller clears the buffer between requests.
Recording, per parameter, that every store happens after every shrink would
admit the natural API.

**Not fixed: it needs a language decision.** Ordering the summary would
not be enough. The store record is flow-insensitive: once a reference into
`buf` is stored into `rep`, `rep` is a holder of `buf` for the rest of its
life, and overwriting the field does not retire the record. So even inline,
with no call at all, this is rejected today:

```goose
for i in 2 { buf.clear(); buf.append("hello world"); rep.body = buf[6..11]; print(rep.body); }
// error: cannot clear buf while rep is in scope: a reference into it is
// stored there at line N, which the next iteration reaches
```

and a second `fetch(buf, rep)` would be rejected by the first call's store
whatever order the callee keeps. The options:

1. *Order only.* Each specialization records, per (shrunk parameter,
   holder parameter), that no path leads from a store of a reference into
   the one into the other to a shrink of the one (loops and callees
   included); a call then leaves its own stores out of the holders live at
   its own shrinks. Sound and contained, but it admits only a `rep` used
   for one call: reusing `rep` (the motivating case) is still rejected.
2. *Kill on overwrite.* Make the store record flow-sensitive and
   field-sensitive: a store that overwrites every reference a holder's
   field can hold retires that field's earlier records, and a callee
   summary says which holder fields it overwrites on every path after its
   shrinks and before reading them (an early `return`, a `return from`
   that leaves past the caller, and aborts all count). This admits the
   loop above and the reused `rep`, but changes §5.1's "values hold
   references only where a store put them … exact to the store" into a
   flow-sensitive rule, and touches the store record everywhere it is
   replayed (calls, cycles, globals judged at the end).
3. *Change the API instead.* Returning the reply by value already works:
   `fn fetch(buf: u8[>..]&, …) -> Reply` that clears `buf` and returns
   slices of it is accepted where each call's result is a new binding
   (`for … { let rep = fetch(buf, …); use(rep); }`), since the previous
   iteration's `rep` is dead at the next shrink. Reassigning one `var rep`
   is still rejected, for the reason above.

Option 2 is the one that admits the natural API; it is a §5.1 design
change, so it is left for a decision. Option 3 needs no compiler change.

### 7. A grow-only field of a struct cannot be cleared

`res.body.clear()` and `res.body.resize(n, x)`, where `body: u8[>..]` is the
tail of a `Response` reached through `res: Response&`, are refused. The
message is: "names the array's variable, or a reference to it, not an
element of another value". A field of a struct the function only has by
reference is what an API naturally hands out.

*Workarounds:* reassign the whole struct (`res = Response { .. }`) to
reset, and use `push_n`, or `append` from a prebuilt buffer, instead of
`resize`.

**Fixed** in `55638bd`. A resizable is only ever a struct's tail field
(§3.4), its storage the struct's own resizable part, so the receiver may
now be the tail field of a struct named as a receiver could be before
(a variable, a reference variable or parameter, a global), through fields
held by value; the struct's root is what shrinks. The existing scans and
call summaries all judge by root, so they carry over: a view rooted at the
struct, a holder on record, a parameter's callers. A view of another field
of the struct counts as one into the array, which is conservative. A path
through a reference field is still refused. §5.1 says so now.
`shrink_tail_field` runs the accepted cases; `errors_tc/shrink_tail_field_*`
are the rejected ones (a live slice of the field, a call that shrinks it,
a view in the callee, a reference to another field, a reference field on
the path, a `const` reference).

## What `stdlib/http.goose` can drop

On the `http` branch as of `63e3967`, once these fixes are merged:

- *Item 1:* `parse_head` can step one cursor over the method, the target
  and the version (`i += 10` behind `if i + 10 > n`): measured above, every
  index check stays elided and it is no slower. `parse_fields` and
  `parse_reply_head` can too, though an offset `span` returns keeps its
  check in either form, since a callee's result has no known range.
- *Item 2:* `let c = r[k]` before a table lookup can be `TOKEN[r[k]]`.
- *Item 3:* `if k >= r.len` after a scan can be `if k == r.len`.
- *Item 4:* building a `Request` costs nothing, so callers (the serve loop,
  `bench/http/parse`'s `seq`) can build one per request, and the comments
  saying a fresh `Request` costs more than parsing a small request are
  stale. `res = Response { .. }` in `serve_on` no longer copies its 2 KB
  `headers` and 128-byte `content_type` either.
- *Item 7:* the reset can be `res.body.clear()` (with the other fields set
  directly) and `resize` is available on `res.body`.
- *Item 6* stays: `fetch` still only appends to `buf`, unless it returns
  the `Reply` by value (option 3).

## Found while fixing

- *Global invariants leaned on dropped candidates* (fixed in `0416975`).
  A global's `g >= 0` is checked assuming every global candidate, and one
  that fails in a later body was dropped without re-checking the bodies
  before it: with `fn a() { x = y; }` checked before `fn b() { y = -5; }`,
  `arr[x]` lost its check while `x` was -5, and read out of bounds. The
  sweep now repeats (over the bodies that write a candidate) until it drops
  nothing. `bce_global_invariant_order` fires.
- *A range loop counted iterations that wrap* (fixed in `ac0a576`, since
  item 1 widened what it relied on). `for i in k..k + 3` counted 3
  iterations from the bounds' common base even where `k + 3` wraps and the
  loop runs none, so three pushes in it were assumed. The count now
  requires both bounds to be exact. `bce_range_count_wrap` read past the
  end without the fix and now fires.

## Also seen

- The TinyCC JIT on this machine fails on every program, even
  `fn main() { print(1); }`, with `include file 'stdint.h' not found`. That
  looks like an environment issue with tcc's include path on this macOS
  install, not the compiler. It meant every check went through `-o` and
  clang.
