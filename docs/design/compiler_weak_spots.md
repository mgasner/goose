# Compiler weak spots found while writing the HTTP parser

Status: open. Each item is reproduced against the compiler at `20ebab6`.

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

### 7. A grow-only field of a struct cannot be cleared

`res.body.clear()` and `res.body.resize(n, x)`, where `body: u8[>..]` is the
tail of a `Response` reached through `res: Response&`, are refused. The
message is: "names the array's variable, or a reference to it, not an
element of another value". A field of a struct the function only has by
reference is what an API naturally hands out.

*Workarounds:* reassign the whole struct (`res = Response { .. }`) to
reset, and use `push_n`, or `append` from a prebuilt buffer, instead of
`resize`.

## Also seen

- The TinyCC JIT on this machine fails on every program, even
  `fn main() { print(1); }`, with `include file 'stdint.h' not found`. That
  looks like an environment issue with tcc's include path on this macOS
  install, not the compiler. It meant every check went through `-o` and
  clang.
