# JSON — Design

Status: phases 1–4 (§12) are implemented in pure Goose in `stdlib/json/`,
with `bench/json/` and the `stdlib_json` fixture. [`../json.md`](../json.md)
is the user's guide. SIMD kernels (§10) and typed decoding (§11) are
designed here and not implemented. §13 records what was measured and
where the implementation departed from the first plan.

`import json;` reads and writes JSON (RFC 8259) as fast as Goose allows.
It is one library with four layers, each usable on its own:

| Layer | For | Shape |
|---|---|---|
| **Writer** (§4) | responses: GraphQL, HTTP, logs | appends to a `u8[>..]`; containers are trailing blocks |
| **Numbers** (§5) | every layer | shortest round-trip `f64` output, correctly rounded `f64` input, integers eight digits at a time |
| **Document** (§6) | reading a whole value and walking it | one pass into a flat tape of 16-byte entries, indexed by position |
| **Cursor** (§7) | pulling a few fields out of a large input | a structural index, walked lazily, nothing materialized |

The goal is throughput in the class of yyjson on one core, without SIMD
intrinsics, and a clear path to simdjson's class (§10) when measurement
says the structural scan is the bottleneck.

---

## 1. What the fast libraries do

**simdjson** (Langdale and Lemire; 5.0, September 2026). Parsing is two
stages. *Stage 1* reads 64-byte blocks and builds 64-bit masks: one bit
per byte for structural characters (`{}[]:,`), whitespace, quotes and
backslashes. Escaped quotes are found from the runs of backslashes before
them. The bytes inside strings are the prefix-XOR of the quote mask,
computed with one carry-less multiply. The structural and
start-of-scalar bits outside strings are then turned into a `u32` array of
positions with count-trailing-zeros, unrolled. *Stage 2* walks that
array. The DOM API builds a tape. The *On-Demand* API (Keiser and
Lemire, 2024) builds nothing: a cursor over the index parses a value only
when the program asks for it, and skips the rest by depth counting.

**yyjson** (ibireme). Plain C89 and no explicit SIMD, yet close to
simdjson on DOM workloads. It parses in one pass into a contiguous array of
16-byte values: a tag word (type in the low bits, length or child count
above) and a payload word (integer, double bits, string pointer, or for a
container the byte distance to its end). Skipping a container is O(1). Its
speed comes from character-class lookup tables, reading 4 or 8 bytes at a
time in the string and whitespace loops, carefully ordered branches, and
an optional in-place mode that unescapes strings into the input buffer.
Its writer uses an escape table and copies clean runs whole.

**Glaze** (C++). No DOM. Reflection gives each struct's fields at compile
time, and a compile-time perfect hash maps a key to its field in one
probe. Reading writes straight into the program's own structs, and writing
reads straight from them.

**Numbers.** Writing a `f64` correctly means printing the shortest decimal
that reads back as the same double. Ryu (2018), Schubfach (2020) and
Dragonbox (2020) each do it with one or two 128-bit multiplies against a
table of powers of ten. Zmij (Zverovich, 2025) narrows the candidates and
replaces 64-bit logarithm approximations with 32-bit ones, and is about
1.7× faster than Dragonbox. Reading a `f64` correctly is the
Eisel–Lemire algorithm (fast_float, 2020): one 64×64→128 multiply against
a table of powers of five decides the result in all but a vanishing
fraction of inputs. Those few fall back to exact big-decimal arithmetic.
Eight decimal digits can be parsed at once with three multiplies on a
64-bit word.

## 2. What this means in Goose

Measured or read from the implementation before designing:

* **No SIMD types or intrinsics** in the language (spec §12, future item
  10). clang auto-vectorizes simple loops in the generated C, but not a
  parser. The plan is SWAR — 64-bit words as 8 lanes of bytes — in pure
  Goose, with SIMD as a later `extern` kernel (§10).
* **Word loads are cheap if written right.** Taking an 8-byte slice
  `s[at..at + 8]` costs one range check, and the eight indexes into it
  are then elided by BCE; clang folds the shifts and ORs into one
  unaligned load. Unsigned arithmetic wraps by definition (spec §6.2), so
  the borrow tricks of SWAR are defined.
* **A `f64`'s bits** come from `bytes_of` on a one-element fixed array,
  in pure Goose. The other direction is exact arithmetic: a 53-bit
  mantissa converted to `f64` and scaled by a power of two from a table.
* **No 128-bit multiply.** Eisel–Lemire and Schubfach/Zmij need the high
  64 bits of a 64×64 product. In pure Goose that is four 32×32→64
  multiplies (`mulhi`, §5). This is the second place an `extern` kernel
  would help (§10).
* **`std`'s `popcount`, `clz` and `ctz` are bit loops.** The library has
  its own branch-free `ctz` (de Bruijn multiply and a 64-entry table) and
  `clz` (halving). Neither is the one instruction the hardware has, and
  that shows (§13).
* **Bounds checks.** Each `s[i]` in a byte-at-a-time loop is checked
  unless BCE can see `i < s.len`. Hot loops are written as `while i <
  s.len` over a slice, or with an explicit 8-byte slice per step.
* **No reflection.** Generic code cannot walk a struct's fields, so typed
  decoding needs either hand-written code or a compiler builtin (§11). The
  builtin `format` already renders any type structurally, which is the
  precedent.
* **No heap.** Every output is a flat, growable array: the response
  bytes, the tape, the index. A document's tape has no references in it.
* **No global scratch that shrinks.** A function that clears a global
  array cannot be called while any slice the checker cannot rule out
  points into it, which in practice is anywhere a caller loops over
  string literals. So the parser's scratch arrays are locals of `parse`
  and `value`, passed down by reference.

## 3. Modules

```
stdlib/json.goose            imports the parts below
stdlib/json/tables.goose     generated by scripts/json_tables.py: 128-bit powers of ten
                             and five, exact powers of two and ten, the UTF-8 DFA
stdlib/json/base.goose       word helpers (load8, lane tests, ctz64, clz64, mul128),
                             bits_of / f64_of, Error
stdlib/json/number.goose     integer and f64 writing and reading
stdlib/json/write.goose      Writer
stdlib/json/doc.goose        the tape parser and its accessors
stdlib/json/cursor.goose     the structural index and the cursor
```

Everything is in `namespace json`. As in `graphql`, functions meant to be
called through UFCS on the library's types (`v.get("k")`) are declared
global with `fn ::name`, so they are found from the caller's namespace.

## 4. Writer

```goose
var out: u8[>..] = [];
var w = json::writer(out);
w.object() {
    w.key("id");    w.int(42);
    w.key("name");  w.string(name);
    w.key("tags");  w.array() { for t in tags { w.string(t); } };
    w.key("score"); w.float(0.1);
};
```

* **Commas are the writer's job, and need no stack.** One bit says
  whether the next item needs a comma. Opening a container or writing a
  key clears it; a value or a closed container sets it. That is all the
  parent needs, since after a container closes the parent always wants a
  comma before its next item. A second bit says a key was just written,
  so a pretty printer keeps the value on the key's line.
* **Strings.** The escape loop reads 8 bytes as a word and tests all
  lanes at once for a byte that needs escaping (`< 0x20`, `"`, `\`). A
  clean word is skipped whole and a clean run appended at once. At a
  dirty byte, the run so far is appended and the byte escaped. Non-ASCII
  bytes pass through unchanged.
* **Keys known at compile time** can be pre-quoted: `w.raw_key("\"id\":")`
  appends the bytes with no scan.
* **Integers** are written eight digits at a time into a word (§5), and
  appended with one copy.
* **Floats** use the shortest round-trip algorithm (§5). JSON has no NaN
  or infinity, so they write `null` by default.
* **`raw(bytes)`** appends already-encoded JSON, as the GraphQL resolver's
  `r.json` does.
* **Pretty printing** is `pretty_writer(out, indent)`: newlines and an
  indent per depth.
* **`w.value(v)`** writes a value of a parsed document, by walking its
  tape in order with a stack of the containers still open.

The writer appends to a growable array the caller owns. It never builds a
tree, so writing has no allocation of its own.

## 5. Numbers

**Integers out.** The digit count comes from `clz` and a table of powers
of ten. The digits are then built eight at a time in a `u64`, in SWAR
(`encode8`): the value is split into two halves of four digits, each half
into two pairs, and each pair into two digits, every lane at once, with
multiplies by reciprocals. The digits land as ASCII bytes in lane order,
so `bytes_of` on the words is the text, appended with one copy.

**Floats out.** Schubfach as drachennest's `schubfach_64` implements it.
It finds the interval of decimals that round to the double, then the
shortest candidate in it. The table holds 617 128-bit powers of ten, as
`u64` pairs in a `const` array (about 10 KB, static data, so it is not
copied when a worker is spawned).

Schubfach multiplies `g`, the power of ten, by three neighbors: `cb`,
and `cb ± 2` (or `cb − 1` where the lower neighbor is closer). Each
product is rounded to odd. The neighbors differ from `cb` by a power of
two, so their products differ from `cb`'s by `g` shifted. One 192-bit
product and an exact add and subtract of `g << s` give all three, the
same bits as three products would: 8 64-bit multiplies in place of 24. Formatting follows ECMAScript's `Number.prototype.toString`,
which is what every JavaScript reader expects:

* integers below 10^21 are written without an exponent (`1e20` →
  `100000000000000000000`);
* decimal exponents from -7 up to 21 use plain notation (`0.000001`,
  `123.456`);
* other values use `1.5e-7` and `1e+21`.

`-0.0` writes as `-0`.

This also fixes a known gap in the language's own `format`. `gs_fmt_f64`
tries 15 digits, then 17, which round-trips but is not always the
shortest (implementation notes §6.9). The runtime can adopt this code.

**Floats in.** Three tiers:

1. **Clinger's fast path.** If the significand fits in 53 bits and
   |exponent| ≤ 22, one `f64` multiply or divide by an exact power of ten
   is correctly rounded.
2. **Eisel–Lemire.** Multiply the 19-digit significand by a 128-bit power
   of five (the same table as above, read the other way) and take the top
   bits. If the low bits show the result is too close to a rounding
   boundary to decide, fall through.
3. **Exact.** The "simple decimal conversion" of fast_float and Go's
   `strconv`: the digits as a decimal number of up to 800 digits, shifted
   by powers of two until it is in [1/2, 1), then rounded. This is slow
   and rare (adversarial inputs and numbers with more than 19 significant
   digits near a tie).

**Integers in.** Eight digits at a time with the SWAR trick: check that
all eight lanes are digits, subtract `'0'` from each lane, then three
multiply-and-shift steps combine pairs, quads and octets. A scalar tail
follows. A number with no `.`, `e` or `E` that fits `i64` is an integer.
One that fits `u64` but not `i64` is a `u64`. Anything larger is a float.

**Building a double from its bits** without a bit cast: the 53-bit
significand converted to `f64` (exact) and scaled by powers of two from a
table (each step exact, since the value is representable). Only `f64_of`
does this, when a program reads a float, not the parser: the tape stores
bits.

**`mul128(a, b)`** — both words of `a * b` — is four 32×32→64 multiplies
and the carries. It is called twice per double written and once or twice
per double read (Eisel–Lemire's second product only near a boundary).

**Testing.** `bench/json/check.py` writes several million cases from
Python's correctly rounded `repr` and `float()`, and
`bench/json/numcheck.goose` checks them:

* random bit patterns, subnormals, the extremes and powers of two;
* decimals of 1 to 40 random digits at every exponent;
* the exact midpoints between adjacent doubles, and those nudged by one
  unit in the last of many digits.

Every case matches, in both directions.

## 6. Document

```goose
let d = json::parse(text);
guard d.ok() else { print(d.error.message, " at byte ", d.error.at); return; }
d.root().get("users").each() { u =>
    print(u.get("name").string(), " ", u.get("age").int());
};
```

**The tape.** `Doc { src: const u8[:], ntape: i64, error: Error, tape:
Val[>..] }`. A struct holds one resizable, so the unescaped text of
strings with escapes lives in the tape too: in entries after the last
value (`ntape`), sixteen bytes to an entry, read back with `bytes_of`.
A `Val` is 16 bytes:

```goose
struct Val { head: u64, data: u64 }
// head: kind in bits 0-3, then flags, then a length or count in bits 8-63
// data: i64 or u64 value / f64 bits / string offset / container end index
```

| Kind | `head` above the kind | `data` |
|---|---|---|
| null, true, false | — | — |
| int, uint | — | the value |
| float | — | the bits |
| string | byte length; `ESC` flag if it was unescaped | offset into the source, or into the text area if `ESC` is set |
| array, object | element count (keys and values are both entries) | tape index one past the container's last entry |

* **Strings without escapes** — the great majority — are views into the
  source: `v.string()` returns `src[off..off + len]` with no copy.
  Strings with escapes are unescaped into the text area.
* **Skipping** a container is `i = data`: O(1).
* **Navigation:**
  * `v.get(key)` scans the object's keys, comparing the length (in the
    head word) first, then the bytes. It returns the first match;
    duplicate keys are kept as they appear.
  * `v.at(i)` walks `i` siblings, each step O(1) by the skip.
  * `v.each() { x => … }` and `v.members() { k, x => … }` take blocks:
    Goose has no iterator objects.
* **Values are handles.** `json::Value { doc: const Doc&, entry: i64 }`.
  The field is not called `at`: a field shadows a UFCS function of the
  same name, and `v.at(i)` must reach the function.
* **Missing values read as defaults.** A failed lookup gives entry -1,
  whose kind is `K_MISSING`, and every read of it gives a default. So
  chains need no checks; `try_` forms say whether there was a value.
* **The source** must outlive the document, since strings point into
  it. The document holds a view, never a copy, and the compiler's
  lifetime rules check the rest.

**One pass.** A single recursive-descent pass would hold a growable local
at each level (spec §7.8), so the parser is a loop with an explicit stack
of open containers. The innermost container's tape index, count and kind
live in locals; the ones around it go on an `Open[>..<]`. On close, the
count and end index are written back into its `Val`. Dispatch is on the
first byte.

* **Whitespace.** Spaces go a byte at a time, which branch prediction
  makes cheap for an indent. After a line break, a deep indent goes eight
  spaces at a time.
* **Strings.** The scan stops only at a quote, a backslash or a control
  character, eight bytes at a time. It ORs the words together on the way,
  so a string with any byte from 0x80 up is known when it ends. Only
  such a string is then checked as UTF-8 whole, by a shift DFA: one
  64-bit table row per byte, `state = (row >> state) & 63`, with ASCII
  words skipped. Checking each multi-byte sequence as the scan met it was
  measurably slower on twitter.json, which is largely Japanese.

**Validation.** Full RFC 8259:

* strings: no unescaped control characters; escapes only `\" \\ \/ \b \f
  \n \r \t \uXXXX`; surrogate pairs combined, and unpaired surrogates
  rejected;
* UTF-8 checked as above, rejecting overlong forms, surrogates and
  anything past U+10FFFF;
* number grammar exactly as the RFC states it (no leading zeros, no `+`,
  no bare `.`);
* nothing but whitespace after the root value.

`max_depth` defaults to 1024. Errors are values — `Error { ok, at, message
}` — and the parser never aborts on bad input.

## 7. Structural index and cursor

```goose
var c = json::cursor(text);
let q = c.root().get("query").string();
let vars = c.root().get("variables");   // not parsed until used
```

**Stage 1** (`json::index(src, out: u32[>..]&)`), in SWAR, 8 bytes per
step:

1. Load the word; compute exact lane masks (no borrow between lanes) for
   quote, backslash, structural characters (`x | 0x20` folds `[` `]` onto
   `{` `}`) and whitespace, each compressed to 8 bits by a
   multiply-and-shift gather.
2. Accumulate 64 bytes of these 8-bit masks into 64-bit masks. From
   there the computation is simdjson's:
   * odd-length backslash runs give the escaped quotes;
   * the prefix-XOR of the real quotes gives the in-string mask, computed
     with six shift-XOR steps instead of a carry-less multiply, carried
     across blocks;
   * structural characters outside strings are kept, with both quotes of
     every string, and the first byte of every other scalar: a byte that
     is not structure, space or string, after one that is.
3. Extract positions with the branch-free `ctz`, one per set bit.

Bytes past the end are treated as spaces. The last block is copied into a
64-byte padded buffer, so no load runs past the input.

**Stage 2** is the cursor. A `Lazy { c: Cursor&, p: i64 }` is an index
entry, and it reads with the same calls as a document's values.

* A string is two entries, its quotes: its text is between them, with no
  scan for the end.
* Skipping a value counts brackets through the index. It touches one
  byte per entry, and none inside strings.
* Scalars are parsed, and strings checked, only when read. A string with
  escapes is unescaped into words after the index, so its view stays
  valid: grow-only memory never moves.
* `cursor()` checks that strings close and that the root spans the
  whole text, by one bracket count over the index. Everything else is
  checked as it is read; errors are kept in `c.error`, the first one
  wins, and a malformed value reads as missing.

The document parser does not run over the index. In pure Goose, stage 1
alone runs at about the speed of the whole one-pass parse (§13), so a
two-pass DOM would be slower. With the SIMD kernel (§10) that changes,
and the question is open again.

## 8. Errors and limits

* Errors are values everywhere: `Error { ok: bool, at: i64, message:
  u8[..48] }`. A cursor that reads malformed input keeps the first error.
  Reading a missing key or a value of the wrong kind returns a default
  and `false`.
* Duplicate keys: kept. `get` returns the first.
* Big numbers: an integer past `u64` is the nearest double. A cursor's
  `v.raw()` gives any value's exact text; a document does not keep it.
* Depth: `max_depth` (1024) for parsing. The writer has no limit beyond
  memory.
* Input must be UTF-8. A leading byte-order mark is rejected, per RFC
  8259 §8.1.

## 9. Parallelism

A single document parses fastest on one thread. At gigabytes per second, a
megabyte takes under a millisecond, and copying it to a worker through a
queue costs as much as parsing it. (The GraphQL pool measured queue
copying as the limit for a 583 KB response.) So:

* **Per request:** each worker of a pool parses its own requests. This
  is the main use, and it needs nothing from this library.
* **NDJSON / JSON Lines:** one document per line (not built yet: a
  program can split at newlines itself). A program with a pool splits the
  input in chunks of a few megabytes and gives each chunk to a worker.
* **One huge document** (above about 16 MB): stage 1 can run on chunks
  in parallel. Each chunk's in-string state is unknown at its start, so
  each worker computes both possibilities and the chunks are stitched
  in order. This is simdjson's threaded stage 1. It is not planned until
  a user needs it.

## 10. SIMD (designed, not implemented)

The pure-Goose code is the specification and the fallback. SIMD replaces
exactly two kernels, behind `extern fn`s with the same contract, and only
when measurement shows they dominate.

**Kernel 1: structural index.**

```goose
extern "gs_json_index" fn index_kernel(src: const u8[:], out: u32[>..]&, state: IndexState&) -> bool;
```

* Same output as the SWAR stage 1, and resumable across calls through
  `state` (in-string bit, backslash carry, previous-byte class), so large
  inputs can be fed in pieces.
* C in `src/runtime/runtime_json.h`, declared in `runtime_ext.h` like the
  `gs_os_*` functions.
* Paths:
  * SSE2 baseline on x86-64, AVX2 when `__builtin_cpu_supports("avx2")`
    at first call;
  * NEON on arm64;
  * the classification by two `pshufb`/`vqtbl1q` nibble lookups;
  * the prefix-XOR by `pclmulqdq`/`vmull_p64`;
  * position extraction by `tzcnt`, unrolled 8 at a time.
* MSVC and TinyCC compile the scalar C path. That path is a direct port
  of the Goose SWAR, so all three agree.

**Kernel 2: wide multiply and string scan.**

* `extern "gs_mulhi64" fn mulhi(a: u64, b: u64) -> u64` uses
  `__uint128_t` or `_umul128`. That is about 1 ns against about 4, worth
  it for float-heavy documents (canada.json is almost all floats).
* `gs_json_scan_string` finds the next `"` or `\`, and
  `gs_json_escape_scan` finds the next byte that needs escaping, 16 or 32
  bytes per step.

**How we proceed:**

1. **Gate on a profile.** A kernel is written only if its Goose version
   is above roughly 25% of the time on the standard corpus. Today's
   profile (§13) already passes the gate for two of them:
   * string and whitespace scanning are about two thirds of the parse
     time of twitter.json and citm_catalog.json;
   * Schubfach, mostly its 128-bit products, is about 40% of the time
     to write a double; `mul128` and Eisel–Lemire are about an eighth of
     canada.json's parse, below the gate on their own.

   Stage 1 is the cursor's whole fixed cost.
2. **Parity first.** The SIMD and SWAR versions are differential-tested:
   * on every file of the corpus and of JSONTestSuite;
   * on a fuzzer that generates random JSON with strings straddling
     64-byte boundaries, long backslash runs, and inputs of every length
     mod 64;
   * by comparing the index arrays, not just the parse results.
3. **Selection** is a build define, `-DGS_JSON_SIMD=0/1`, landing in
   the generated C (main.cpp's `-D`). It defaults to 1 on clang and gcc,
   and 0 on TinyCC. The `--jit` path tests the fallback in every CI run.
4. **Measure the packed-layout question** (spec item 10) on the way.
   Element arrays here are bytes and `u32`, so alignment is not expected
   to matter. If it does, that is evidence for the aligned-types proposal.

**The language alternative.** If Goose gains portable vector types (for
example `u8x16`, with lane compare, movemask, shuffle and clmul as
builtins lowered to clang's `__builtin_*` vector extensions), kernel 1
moves back into Goose source and the `extern` is deleted. The SWAR code
is structured as "classify a block, combine the masks, extract the bits"
so that only the classification step changes.

## 11. Typed decoding and encoding (designed, not implemented)

Turning JSON into the program's own structs, and back, without a DOM.

**Step A — library only, hand-written.** The cursor gives a key switch:

```goose
fn decode(c: json::Cursor&, p: Point&) -> bool {
    return c.fields() { k =>
        if k == "x" { c.read(p.x) }
        else if k == "y" { c.read(p.y) }
        else { c.skip() }
    };
}
```

* `c.read(x&)` has overloads for the scalars, `u8[..N]` and `u8[>..]`
  strings, `T[>..]` arrays (calling `decode` per element), optionals
  (`null` → none) and fixed arrays.
* Each overload checks the value's kind, and returns `false` with a
  cursor error on a mismatch.
* `encode(w: json::Writer&, p: Point)` is the mirror image. This needs
  nothing new from the compiler, and it is how GraphQL variables and
  HTTP bodies are decoded in the meantime.

**Step B — a structural builtin, as `format` is.** Two builtins:

```goose
json::encode(out, x)                 // any type, structurally
json::decode<T>(text, x&) -> json::Error
```

* **Lowering.** Each is lowered per type, by the same machinery that
  renders `format`, and a user overload for a type (`fn json_encode(w,
  x: T)` / `fn json_decode(c, x: T&)`) replaces the structural one
  wherever that type occurs. That is exactly `format`'s rule (spec
  §3.7).
* **Mapping:**

  | Goose | JSON |
  |---|---|
  | struct | object with its field names as keys |
  | fixed or growable array | array |
  | `u8` arrays | strings |
  | optional | value or `null` |
  | enum without payload | the case name as a string |
  | enum with payload | `{"Case": {...}}` (the external tagging of serde's default) |
  | `bool`, integers, floats | the obvious |

* **Key dispatch** is generated per struct, at compile time:
  1. a `switch` on key length;
  2. within one length, a comparison of the first 8 bytes as a `u64`
     constant;
  3. then a `memcmp` of the rest.

  For structs with many fields of the same length, a perfect hash over
  (length, first word, last word) is computed by the compiler. This is
  Glaze's approach, without templates.
* **Missing and unknown keys.** A missing key leaves the field's
  declared default (spec §3.2). A field with no default is an error.
  Unknown keys are skipped by default (`strict` errors instead).
* **Renaming and options.** Goose has no attributes. A struct that needs
  a JSON name different from its field name, or a flattened field, gets a
  user overload. If that proves common, an attribute syntax is a
  separate language proposal.
* **Fixed-size results.** Decoding into a struct of `u8[..N]` and limited
  arrays never grows anything. A too-long string is an error, not a
  truncation, so decoding untrusted input into fixed buffers is safe.

**How we proceed:**

1. Step A builds on the cursor, which is done. The first real user is
   GraphQL's variable coercion, which today copies a document's tape into
   its own value table (`import_json`).
2. Write the builtin's spec text (§3.7's companion) and lower it in a
   branch.
3. Check, using the decoders hand-written in Step A as the reference,
   that the builtin's output is identical and at least as fast.
4. The generated decoder for a struct is ordinary Goose, inlined, so BCE
   and clang see it whole. That is where it can beat a hand-written one
   — the per-struct key switch.

## 12. Benchmarks and phases

**`bench/json/json_bench.py`** builds `json_bench.goose`,
`conformance.goose` and the yyjson baseline with one C toolchain, and
writes `results.md` and `results.json`.

* **Corpus** (`bench/json/data`): `twitter.json` (pretty-printed, much of
  it Japanese), `citm_catalog.json` (pretty-printed, deep indents) and
  `canada.json` (almost all doubles).
* **Correctness.** JSONTestSuite through the document and through a
  fully walked cursor: accept every `y_`, reject every `n_`, and record
  what `i_` does. The doubles are tested as §5 says, and the corpus is
  written back byte-identical to a Python reference serializer that uses
  the same float format.
* **Baseline.** yyjson 0.13, built with the same compiler and flags. Its
  walk reads every scalar, as ours does. simdjson is not built: it needs
  C++ and is a SIMD baseline, to be added with §10.
* **Reported:** MB/s per file for parse, parse plus walk, and write, each
  with yyjson beside it; stage 1, a cursor lookup and the same lookup
  through a document; ns per double written and read.

**Phases:**

1. Bench harness and the conformance suite. Done; `stdlib_json` is the
   always-on fixture.
2. Numbers and the writer. Done. GraphQL's `json_quote` and its float
   leaves now use them. The output is byte-identical except floats: `5.0`
   is now `5`, as graphql-js writes it.
3. The document parser. Done.
4. Stage 1 and the cursor. Done. GraphQL's envelope and variables are
   parsed by `json::parse`. Step A typed decoding is deferred with the
   rest of §11.
5. **SIMD (§10)**, gated on the profile in §13.
6. **Typed decoding (§11)**, Step A then the builtin, a language change
   with its own review.

## 13. What was measured

Apple arm64, clang -O2, one core, on a machine busy with other work (load
average 14–40), so each figure is the best of 50 runs and yyjson ran
alongside in the same invocation. `bench/json/results.md` has the tables.

| | twitter.json | citm_catalog.json | canada.json |
|---|---|---|---|
| parse | 2239 MB/s, 45% of yyjson | 3881 MB/s, 79% | 1205 MB/s, 60% |
| parse and read everything | 47% | 75% | 59% |
| write | 31% | 32% | 42% |
| stage 1 alone | 3238 MB/s | 3228 MB/s | 2635 MB/s |
| one lookup near the end: cursor / document | 2447 / 2215 MB/s | 2558 / 3863 | 2311 / 1232 |

Doubles: 21 ns each to write and 11 ns to read. The first target, half
of yyjson's DOM speed on twitter.json, is met on the other two files and
just missed on twitter.json. Writing is a third of yyjson's speed, not
the parity hoped for.

**Where the time goes** (sampled, functions not inlined):

* twitter.json: string scanning and validation about 45%, whitespace
  35%, numbers 4%.
* citm_catalog.json: whitespace about half (68% of its bytes are
  indentation), strings 20%, numbers 10%.
* canada.json: number scanning (digits and the fast paths) about 55% of
  parsing, whitespace 13%, `mul128` and Eisel–Lemire 12%. In writing,
  Schubfach is 40% of each double and digit output a quarter.

**What did not work, and why:**

* **A word-at-a-time `skip_ws` that found the end of a run of spaces with
  `ctz` was 25% slower** on twitter.json than a byte loop. Indents are
  short, and the de Bruijn `ctz` (a multiply and a table load) sits on
  the critical path, where the hardware's single instruction would not.
* **The cursor reads everything at half a document's speed.** It finds
  each value through the index, then parses it, and the number kind is
  parsed again when the value is read. It pays only when most of the
  text is skipped. That was the design's expectation, but the margin is
  smaller than with SIMD, because stage 1 in SWAR runs at about one
  parse's speed.

**Findings for the language and runtime.** These are the places pure
Goose costs most here. Each is a candidate for a builtin or an
optimization, not a change to make in this library:

1. **`ctz`/`clz`/`popcount` as intrinsics.** `std`'s versions are loops,
   and the library's branch-free ones cost a multiply and a load each.
   Stage 1 extracts every position with one, and the writer and parser
   use them per string.
2. **A 64×64→128 multiply** (`mulhi`). It is the core of both double
   conversions: four multiplies and carry handling instead of one
   instruction (§10, kernel 2).
3. **Appending through a reference reloads the array header.** `push`
   and `append` on an `A&` write the byte, then the stack top and the
   length, and reload them for the next call, since a byte store may
   alias the header. This is likely much of why writing is a third of
   yyjson's speed (not isolated yet). A `reserve` that hands back a
   writable slice, or caching
   the top across stores the compiler can prove do not alias, would
   help every writer of text, not just this one.
4. **A bit cast between `f64` and `u64`.** `bytes_of` on a one-element
   array works and costs nothing after clang, but the reverse direction
   has to be done by exact arithmetic.
