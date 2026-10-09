# JSON

`import json;` reads and writes JSON (RFC 8259). It is written in Goose,
with no C of its own, and it is built for speed: on one core it parses at
45–80% of yyjson's speed, one of the fastest C parsers (`bench/json/results.md`).
[`design/json.md`](design/json.md) records the design and the plan for
SIMD and typed decoding.

There are three ways in, each usable on its own:

| You want to | Use | Section |
|---|---|---|
| produce JSON: a response, a file, a log line | a **writer** | §1 |
| read a whole document and walk it | **`json::parse`**, a document | §2 |
| pull a few values out of a large text | **`json::cursor`** | §3 |

Numbers are exact in both directions (§4).

---

## 1. Writing

A writer appends to a growable byte array you own. Containers are
trailing blocks, and the writer puts in the commas:

```goose
import json;

var out: u8[>..] = [];
var w = json::writer(out);
w.object() {
    w.field("id", 42);
    w.field("name", "Ada \"Countess\" Lovelace");
    w.key("langs");
    w.array() { for l in langs { w.string(l); } };
    w.key("score"); w.float(0.1);
    w.key("spouse"); w.none();
};
// out: {"id":42,"name":"Ada \"Countess\" Lovelace","langs":["en","fr"],"score":0.1,"spouse":null}
```

| Call | Writes |
|---|---|
| `w.object() { … }`, `w.array() { … }` | a container; what the block writes is inside it |
| `w.key(k)` | a member's key; the next value is its value |
| `w.string(s)`, `w.int(i)`, `w.uint(u)`, `w.float(x)`, `w.boolean(b)`, `w.none()` | a value (`none` is `null`) |
| `w.field(k, v)` | `key` and a value, for a string, `i64`, `f64` or `bool` |
| `w.raw(text)` | text that is already one JSON value, as it is |
| `w.raw_key("\"id\":")` | a key already quoted, with its colon: no scan |
| `w.value(v)` | a value of a parsed document (§2), re-serialized |

`json::pretty_writer(out, 2)` writes the same calls with one item per line,
indented by two spaces per level.

The writer does not check structure. A key outside an object, or two
values in a row inside one, is written as asked. Strings are escaped as
JSON requires: `"`, `\` and control characters. Bytes from 0x80 up pass
through unchanged, so the text must already be UTF-8. Floats are written
as §4 describes. NaN and the infinities, which JSON cannot express, are
written as `null`.

The writer works on a `u8[>..]` or a `u8[>..<]`, and keeps two flags and
a depth: writing allocates nothing beyond the output.

## 2. Documents

`json::parse(text)` checks the whole text and builds a **document**: a flat
array of 16-byte entries, one per value and key, in the order they appear.
Strings without escapes are not copied; they are views of `text`.

```goose
let d = json::parse(text);
guard d.ok() else {
    print("bad JSON at byte ", d.error.at, ": ", d.error.message);
    return;
}
let users = d.root().get("users");
print(users.count(), " users");
users.each() { u =>
    print(u.get("name").string(), " is ", u.get("age").int());
};
d.root().members() { k, v => print(k, ": ", v.kind()); };
```

A `json::Value` is a handle: the document and an entry of it. A lookup
that finds nothing gives a **missing** value, and reading a missing value,
or a value of the wrong kind, gives that kind's default. So chains need no
checks along the way: `d.root().get("a").at(3).get("b").int()` is 0 if any
step is not there. Where the difference matters, ask:

| Call | Gives |
|---|---|
| `d.root()` | the document's value; missing if it did not parse |
| `v.get(key)` | an object's first member with that key |
| `v.at(i)` | an array's item `i` |
| `v.each() { x => … }` | each item of an array |
| `v.members() { k, x => … }` | each member of an object, in order, duplicates included |
| `v.count()` | items or members; 0 for anything else |
| `v.kind()` | `json::K_NULL`, `K_FALSE`, `K_TRUE`, `K_INT`, `K_UINT`, `K_FLOAT`, `K_STRING`, `K_ARRAY`, `K_OBJECT`, or `K_MISSING` |
| `v.exists()`, `v.is_null()`, `v.is_string()`, `v.is_number()`, `v.is_bool()`, `v.is_array()`, `v.is_object()` | tests |
| `v.int()`, `v.uint()`, `v.float()`, `v.string()`, `v.boolean()` | the value, or the default |
| `v.try_int()`, `v.try_uint()`, `v.try_float()`, `v.try_string()`, `v.try_boolean()` | the value and whether there was one |

Numbers keep their kind:

* a number with no fraction or exponent that fits `i64` is `K_INT`;
* one above `i64` that fits `u64` is `K_UINT`;
* anything else is `K_FLOAT`, the nearest double.

`int()` also takes a whole float in range, and `float()` any number.

**Lifetimes.** A document holds views of `text`, so `text` must outlive
it. The compiler checks this, as it checks every view in Goose. Values
hold a reference to their document. The tape itself, `d.tape`, is flat
data: a `json::Val[>..]` of 16-byte entries with no references in them.

**Errors.** A document that fails to parse has `d.ok()` false, and
`d.error` says why: `error.at` is the byte offset and `error.message` the
reason, for example `expected ',' or '}'`, `invalid UTF-8` or `unpaired
surrogate`. Parsing never aborts on bad input.

**Validation** is complete:

* the RFC's grammar exactly, with no trailing commas, comments, leading
  zeros, `NaN` or single quotes;
* strings checked as UTF-8, rejecting overlong forms, surrogates and
  anything past U+10FFFF;
* escapes checked, with `\uXXXX` surrogate pairs combined and unpaired ones
  rejected;
* no control characters in strings;
* nothing after the value but whitespace;
* a byte-order mark rejected.

`json::max_depth` (1024) bounds nesting.

## 3. The cursor

`json::cursor(text)` makes one fast pass over the text, finding where
every structural character, string and scalar is. It parses nothing.
Values are then read only when asked, and a value you step over costs only
counting brackets in that index:

```goose
var c = json::cursor(body);
guard c.ok() else { reject(); return; }
let q = c.root().get("query").string();
let vars = c.root().get("variables");
if vars.exists() { use_raw(vars.raw()); }   // its exact text, unparsed
```

A cursor's values, `json::Lazy`, have the same calls as a document's (§2),
plus `v.raw()`, the value's exact source text. A cursor must be a `var`:
reading a string with escapes stores the unescaped text in the cursor.

**What a cursor checks.** When it is made, it checks that strings are
closed and that the root value spans the whole text. Each value is checked
fully when it is read: its grammar, its UTF-8 and its escapes. A malformed
value reads as missing, and the first error is kept in `c.error`, so check
`c.ok()` after reading. Values the program never reads are not checked
beyond their brackets. This is simdjson's On-Demand contract. Where the
whole text must be valid, use a document.

**When it pays.** The cursor wins when a program reads a small part of a
large text. canada.json's one key at its end comes back twice as fast as
from a document, because the numbers in between are never parsed. To read
everything, a document is about twice as fast, since the cursor finds
each value through its index and parses it on the way.

## 4. Numbers

```goose
json::write_int(out, i)        json::write_uint(out, u)       json::write_float(out, x)
let x, ok = json::parse_float(s)                  // the whole of s, in JSON's number grammar
let kind, bits, end = json::scan_number(s, at)    // NUM_INT / NUM_UINT / NUM_FLOAT / NUM_BAD
```

**Doubles out** are the shortest text that reads back as the same double.
The digits come from Schubfach. The layout is JavaScript's
`Number.prototype.toString`:

* plain notation for decimal exponents from -7 up to 21 (`0.000001`,
  `123.456`, `100000000000000000000`);
* otherwise `1.5e-7` or `1e+21`.

`-0.0` is written `-0`.

**Doubles in** are correctly rounded, the nearest double to the decimal,
however many digits it has. Three tiers decide it:

1. Clinger's fast path: one exact multiply or divide;
2. Eisel–Lemire: a 128-bit product;
3. exact decimal arithmetic, for the rare inputs the first two cannot
   decide.

Both directions are tested against Python's correctly rounded conversions
on several million values, including every hard case near a rounding
boundary.

## 5. Performance

On one core (Apple arm64, clang -O2), against yyjson 0.13 on the same
machine and run:

| | twitter.json | citm_catalog.json | canada.json |
|---|---|---|---|
| parse | 2.2 GB/s (45%) | 3.9 GB/s (79%) | 1.2 GB/s (60%) |
| parse and read everything | 1.9 GB/s (47%) | 3.1 GB/s (75%) | 1.0 GB/s (59%) |
| write | 2.2 GB/s (31%) | 1.5 GB/s (32%) | 0.7 GB/s (42%) |

Per double, writing takes 21 ns and reading 11 ns. Both are dominated by
the 128-bit multiplies that pure Goose builds from four 64-bit ones.
`bench/json/results.md` has the full tables. Run
`python bench/json/json_bench.py` to remeasure.

Tips:

* Parse straight from the buffer you read into; the document will not copy
  it.
* For request bodies, where a handler wants a few fields, a cursor is the
  cheaper reader. For data a program walks whole, use a document.
* Pre-quote constant keys with `raw_key` in hot writers.
* Each worker of a pool parses its own requests; a document is too cheap
  to make to be worth splitting across workers.

## 6. Reference

| Function | |
|---|---|
| `json::writer(out) -> Writer<A>` | a compact writer appending to `out` |
| `json::pretty_writer(out, indent) -> Writer<A>` | one item per line |
| `json::parse(text) -> Doc` | a checked document; `d.ok()`, `d.error`, `d.root()` |
| `json::cursor(text) -> Cursor` | a structural index; `c.ok()`, `c.error`, `c.root()` |
| `json::write_string(out, s)` | `s` quoted and escaped |
| `json::write_int`, `write_uint`, `write_float` | numbers, as §4 |
| `json::parse_float(s) -> f64, bool` | a whole string as a number |
| `json::scan_number(s, at) -> kind, bits, end` | the number at `s[at]` |
| `json::index(text, out: u32[>..]&) -> bool` | the cursor's stage 1 alone: positions of structure and values |
| `json::max_depth` | the deepest nesting `parse` accepts (1024) |
| `json::Error { ok, at, message }` | what went wrong, and where |

The writer's calls are listed in §1, and a value's calls in §2.
