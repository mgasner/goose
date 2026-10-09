# Deferred-call benchmarks

What stored calls cost (spec §8.3, `docs/design/deferred_calls.md`), and what
graphql's deferred values (`docs/graphql.md` §5, `r.later`) cost against the
batch hook and against graphql-js with DataLoader. `deferred_bench.py`
builds and runs everything and writes [results.md](results.md) and
`results.json`; every program times itself in-process and prints a checksum
or its first response, which the harness requires to agree across all
implementations.

```
python bench/deferred/deferred_bench.py                 # everything (a few minutes)
python bench/deferred/deferred_bench.py --only calls    # or graphql
python bench/deferred/deferred_bench.py --quick         # fewer, shorter runs; results.json untouched
python bench/deferred/deferred_bench.py --no-node       # no graphql-js rows
python bench/deferred/deferred_bench.py --report-only   # re-render results.md
```

Run it on a quiet machine: the times are the best of five runs, which
resists a background process better than a median does, but not a machine
whose cores are all busy.

## Stored calls

`n` calls of four kinds, chosen by an xorshift generator every
implementation shares, are built into an array, then run `passes` times,
threading one `u64` through all of them:

| kind | stored | does |
|---|---|---|
| add | `k: u64` | `x + k` |
| mul | `k: u64` (odd) | `x * k` |
| mix | `a: u32, b: u32` | `(x ^ a) + b` |
| rot | `n: u8` | rotate left by `n` |

The arms are as small as calls get, so the numbers are dispatch and memory,
not work. Each size makes 10^8 calls: `n` = 1,000 repeats a pattern the
branch predictor learns; 100,000 does not, and fits the caches; 10,000,000
does neither.

| program | what |
|---|---|
| `goose/calls_deferred.goose` | `deferred Op(x: u64) -> u64;` and four member functions |
| `goose/calls_enum.goose` | the same as a hand-written enum and case functions |
| `goose/calls_enum_empty.goose` | that enum with an aborting empty variant, as a deferred type has |
| `baselines/calls.cpp` `function` | `std::vector<std::function<uint64_t(uint64_t)>>` of capturing lambdas |
| `baselines/calls.cpp` `virtual` | `std::vector<std::unique_ptr<Op>>` of four classes |
| `baselines/calls.cpp` `variant` | `std::vector<std::variant<…>>` and `std::visit` |
| `baselines/calls.rs` `boxed` | `Vec<Box<dyn Fn(u64) -> u64>>` of capturing closures |
| `baselines/calls.rs` `enum` | `Vec<Op>` of an enum and a `match` |

Bytes per call are the element's own size, plus the heap block for the C++
virtual (its `malloc_size`) and the Rust boxed form (the allocator's 16-byte
minimum). Peak memory is the process's, at the largest size.

The two Goose enum rows bracket the deferred one. A deferred type's empty
call (tag 0) aborts when invoked; with that arm, clang keeps branches in the
dispatch, which win where the sequence is predictable and lose where it is
not. Without it, clang turns the four arms into branch-free selects. The
deferred row matches the enum *with* the arm.

## GraphQL loading

`goose/graphql_loader.goose` and `baselines/graphql_loader.mjs` answer the
same request,

```graphql
{ books { title authorName authorCountry } }
```

over `books` books, a quarter as many authors and 16 countries. An author's
name needs the author's row; the country needs the author's row and then
the country's, a second round. The "backend" charges a fixed cost per call,
spent spinning, and nothing per row: none, or 20 µs. Every implementation
caches rows for the request, so the naive ones make one call per distinct
row.

| row | how |
|---|---|
| Goose naive | each resolver loads what it reads, through the cache |
| Goose batch hook | the hook loads the level's authors, then their countries, before the level runs |
| Goose `r.later` | resolvers ask loaders for keys; one call per loader per round |
| graphql-js naive | each resolver loads what it reads, through a per-request `Map` |
| graphql-js + DataLoader | one `DataLoader` per table per request |

Each request is parsed, validated, executed and written as JSON in every
row. The graphql-js rows use the versions pinned in
`baselines/package.json`, installed by the harness into
`bench/gen/deferred/node` with `npm install`; `--no-node` leaves them out.
