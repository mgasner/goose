# bddicken/languages in Goose

A Goose implementation of the benchmarks of
[bddicken/languages](https://github.com/bddicken/languages) (fibonacci,
loops, levenshtein and hello-world), laid out as a language directory of
that repository, plus a script that runs them here against the
repository's own C, C++ and Rust.

## Layout

| here | in a bddicken/languages checkout |
|---|---|
| `lib/goose/benchmark.goose` | `lib/goose/benchmark.goose` |
| `<benchmark>/goose/run.goose`, `<benchmark>/goose/<benchmark>.goose` | the same |

`lib/goose/benchmark.goose` is the in-process runner, after the
repository's `lib/c/benchmark.c`: it calls the function under benchmark as
many times as fit in the run time, timing each call with a monotonic
nanosecond clock, and prints `mean_ms,std-dev-ms,min_ms,max_ms,runs,result`.
Goose has no function pointers, so each program hands the runner its work
and what to keep of the last call's result as compile-time function
arguments; the result is summed or stored outside the measured time, as
the other runners do it. Each benchmark's function under benchmark lives in
a module of its own, `<benchmark>/goose/<benchmark>.goose`, as the
repository asks.

The repository also needs these entries in `languages.sh`:

```bash
compile 'Goose' 'goose' 'goose -O2 --standalone -o goose/run.c goose/run.goose && gcc -O3 -march=native goose/run.c -o goose/run -lm -pthread'
run 'Goose' './goose/run' './goose/run'
```

and `goose/run` and `goose/run.c` in its `.gitignore` and `clean.sh`. Of
gcc and clang, each with and without `-march=native` (which the C++ entry
uses too), gcc with it is the fastest over the three timed benchmarks
(below).

## The implementations

Each follows the reference implementations: the same algorithm, written
the same way, with what Goose offers for speed taken where it applies.

* **fibonacci**: naive recursion with the early return for `n < 2`, on
  `i32` as in C.
* **loops**: the 10k by 10k loop updating a `u32[10000]`, the random
  number from one generator seeded from entropy once, as the C++ version
  does. Unsigned, as in Rust: Goose's `%` is Euclidean (spec §6.2), which
  for a signed type also has to adjust a negative remainder.
* **levenshtein**: Wagner-Fischer in two rows of the shorter string's
  length, made for every call and swapped after each row. The rows are
  pushed onto data stacks, so making them is a pointer bump and the
  function's return frees both. The words are slices of the file's text,
  so nothing is copied out of it.
* **hello-world**: a `print`.

## Running here

`compare.py` builds and runs the four languages, reading the C, C++ and
Rust from a checkout of bddicken/languages next to this repository's
checkout (`languages` or `bddicken-languages`, or `$BDDICKEN`), and writes
everything under `bench/bddicken/build/`.

```
python bench/bddicken/compare.py build
python bench/bddicken/compare.py check
python bench/bddicken/compare.py run --run-ms 5000 --warmup-ms 1000 --reps 5
python bench/bddicken/compare.py build --langs goose-native,c-native
```

The flags are those of `languages.sh`: C with `-O3`, C++ with `-O3
-march=native -ffast-math`, Rust with its `Cargo.toml` release profile; Goose's
C is compiled as the C version is. On Windows the compilers are the clang
and clang++ that come with Visual Studio, and `shim/clock_gettime.h` gives
the reference C runner the `clock_gettime` the Windows C library lacks.
Runs are pinned to CPUs 16-31 (`--cpus`), interleaved by repetition, and the
table reports the best mean. Check the clone out with LF line ends: with
`core.autocrlf` the levenshtein words end in `\r`, and every program then
reports a wrong sum.

## Results

Ryzen 9 9950X3D, pinned to the CCD without V-cache. Mean milliseconds per
call; hello-world is whole processes, with process creation the bulk of it.

Windows 11, clang 22, rustc 1.98 (best mean of 5 interleaved runs of 5 s):

| benchmark | Goose | C | C++ | Rust | vs C | vs C++ | vs Rust |
|---|---:|---:|---:|---:|---:|---:|---:|
| fibonacci | 37.3 | 41.2 | 43.8 | 39.1 | 1.10 | 1.17 | 1.05 |
| loops | 35.1 | 109.3 | 110.0 | 109.6 | 3.11 | 3.13 | 3.12 |
| levenshtein | 28.2 | 51.2 | 88.8 | 37.3 | 1.82 | 3.15 | 1.32 |
| hello-world | 11.9 | 11.4 | 11.9 | 12.3 | 0.96 | 1.01 | 1.04 |

Linux (Ubuntu 24.04 in WSL), the C entry as `languages.sh` builds it and
Goose under each candidate compile line, one 5 s run each:

| benchmark | C, gcc -O3 | Goose, gcc -O3 | gcc -O3 -march=native | clang -O3 | clang -O3 -march=native |
|---|---:|---:|---:|---:|---:|
| fibonacci | 22.2 | 0.37 | 0.38 | 34.6 | 37.4 |
| loops | 112.2 | 37.2 | 5.1 | 31.6 | 4.4 |
| levenshtein | 57.6 | 33.7 | 35.9 | 35.0 | 32.7 |

hello-world is level: the Goose runtime starts in about 9 µs, and 300
interleaved runs put Goose and C within 0.1 ms of each other.

## Why

**fibonacci**: Goose's optimizer inlines the base case into the recursive
calls (`optimize_basecase.h`), so a call with `n - 1 < 2` or `n - 2 < 2`
returns at the call site and about half the calls are never made. gcc goes
much further with the result: the function is static and provably pure, so
it inlines the recursion several levels deep into the timing loop and
merges the identical calls that exposes. With `-fno-ipa-pure-const` the
same program takes 12.9 ms, 35 times as long. The benchmark's rules allow that ("if some
compiler finds ways to avoid recursive calls without any hints, than that
is a result"), but gcc does not do it for the C version (19.5 ms as one
static function in one file), and clang does it for neither.

**loops**: `j % u` divides by a value the loop does not change. Goose
computes a libdivide-style magic number for the divisor before the loop
and makes each `%` a multiplication, a shift and a subtraction; C, C++ and
Rust leave a `div` instruction in the loop. The operands are `u32`, so the
magic number is a 32-bit one (`gs_divu32_gen`, `gs_divu32_q`): the quotient
is the high half of a 32 by 32-bit product, where a 64-bit magic number
takes the high half of a 64 by 64-bit one, which x86-64 has only as a
scalar instruction. With `-march=native` clang vectorizes the whole inner
loop, the remainder included, with AVX-512, and Goose takes 4.6 ms. With a
64-bit magic number the same program took 44.6 ms, and 33.6 ms with
`-march=native`, where clang vectorized only the additions around the
multiplications. gcc 13 vectorizes the loop with `-march=native` too (5.1
ms in WSL), but only because Goose stores `a[i]` as it loads it, as
`(*a).e[i]`, rather than through a pointer taken first, and fails a zero
divisor outright rather than with the plain `%` and its zero test: either
one keeps gcc from holding `a[i]` in a register across the inner loop. At
`-O3` alone gcc does not vectorize the 64-bit product the high half comes
from, and takes 35.5 ms.

**levenshtein**: each cell is the minimum of three candidates, one of them
the cell before it, which makes the row a chain of dependent minima. As
written, `min(min(deletion, insertion), substitution)`, that chain goes
through both comparisons, two compares and two conditional moves per cell,
and no C compiler regroups it. Goose's optimizer regroups integer min and
max chains so that the operand carried from the previous iteration is
combined last (`optimize_reassoc.h`), which leaves one comparison on the
chain: 28.2 ms instead of 39.6. LLVM compiles Rust's first `min` to a branch,
which also shortens the chain, while it predicts well: 37.3 ms. The C
version, which copies the row back instead of swapping and calls a
three-way `min` function, takes 51.2 ms, and the C++ version, which makes
two vectors per call and takes `std::min` of an initializer list, 88.8 ms.
