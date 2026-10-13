# Extending `math`

`stdlib/math.goose` is libm as `extern fn` at both float widths, `PI` and
`TAU`, and four helpers (stdlib_design.md §7). This plan grows it into the
numeric library the rest of the stdlib and user programs keep needing, in
phases that each stand alone. Nothing here is implemented yet.

## Where it stands

```goose
extern fn sqrt(x: f64) -> f64;        extern "sqrtf" fn sqrt(x: f32) -> f32;
// sin cos tan asin acos atan atan2 exp log log2 log10 pow floor ceil round trunc, likewise
let PI = 3.141592653589793;  let TAU = 6.283185307179586;
fn radians(deg: f64) -> f64          fn degrees(rad: f64) -> f64
fn is_nan(x: f64) -> bool            fn is_inf(x: f64) -> bool
```

The ordering and bit helpers are in `std`, not here: `min max clamp abs sign
lerp next_pow2 popcount clz ctz`, `hash`, and `rng`. Vectors are in `vec`.
This split stays: `std` keeps what is generic over `T` and needs no C;
`math` takes what is float-specific, extern-backed, or a numeric algorithm.

The gaps:

1. **No `f32` helpers.** `radians`, `degrees`, `is_nan` and `is_inf` are
   `f64`-only, while `gfx`, `ui` and `physics` work in `f32`.
2. **Thin libm coverage.** No hyperbolics, `hypot`, `cbrt`, `fma`,
   `copysign`, `exp2`, `log1p`/`expm1`, `ldexp`/`frexp` or `nextafter`.
3. **No access to a float's bits.** `json` builds its own: `bits_of`
   (`stdlib/json/base.goose`) reads the eight bytes of `bytes_of` and shifts
   them together, and its inverse `f64_of` rebuilds the double through exact
   scalings by powers of two, which is slow and drops NaN payloads.
4. **No integer algorithms.** No `gcd`, integer power or square root,
   floor/ceiling division, or overflow-detecting arithmetic. Signed overflow
   aborts in debug builds (spec §6.2), so a program that wants to detect it
   has nothing to call. The u128 plan's motivating case, `mul_wide(u64,
   u64)`, also lands here.
5. **No numeric limits.** The spec writes `i64.max` and `u64.max` in prose,
   but they are not expressions, and there is no float maximum, epsilon,
   infinity or NaN to name either.

## Phase 1: parity and libm

`f32` overloads of `radians`, `degrees`, `is_nan` and `is_inf`, and:

```goose
fn is_finite(x: f64) -> bool         // and f32
fn signbit(x: f64) -> bool           // true for -0.0 and negative NaNs
extern fn copysign(x: f64, y: f64) -> f64;    extern "copysignf" fn copysign(x: f32, y: f32) -> f32;
```

More libm, each declared at both widths as today:

```
sinh cosh tanh asinh acosh atanh  hypot cbrt  exp2 expm1 log1p
fma fmin fmax nextafter ldexp
```

`frexp` and `modf` return through a pointer in C. A Goose wrapper over a
small runtime helper returns both values instead (§7.1 multiple returns):

```goose
fn frexp(x: f64) -> f64, i64         // mantissa in [0.5, 1), exponent
fn modf(x: f64) -> f64, f64          // fraction, integer part
```

Constants, literal-like (§6.3), so each adapts to `f32` where used:

```goose
let E = 2.718281828459045;   let SQRT2 = 1.4142135623730951;
let LN2 = 0.6931471805599453;   let LN10 = 2.302585092994046;
let INF = 1.0 / 0.0;   let NAN = 0.0 / 0.0;
```

`1.0 / 0.0` folds to C's `INFINITY` at either width, so `INF` needs no
runtime help.

**Tests.** Every function at both widths, compiled and under the JIT.
The JIT has to resolve each new libm symbol, and only the 18 in use today
have been exercised there. Transcendental results compare with a tolerance,
as `stdlib_math` already does.

## Phase 2: float bits

```goose
fn bits(x: f64) -> u64               fn bits(x: f32) -> u32
fn f64_from_bits(b: u64) -> f64      fn f32_from_bits(b: u32) -> f32
fn ulp(x: f64) -> f64                // and f32
fn approx_eq(a: f64, b: f64, rel: f64 = 1e-9, abs: f64 = 0.0) -> bool
```

`bits` and the `from_bits` pair are `memcpy`s in a runtime helper, reached
through `extern` the way `os` reaches `gs_os_*`. Then `json`'s `bits_of`
and `f64_of` become calls to them, and json's number benchmarks measure the
gain. The two `from_bits` names differ by width because their argument types
alone would not pick one.

## Phase 3: shader-style helpers

```goose
fn fract(x: f64) -> f64              // x - floor(x)
fn step(edge: f64, x: f64) -> f64
fn smoothstep(e0: f64, e1: f64, x: f64) -> f64
fn remap(x: f64, a0: f64, a1: f64, b0: f64, b1: f64) -> f64
fn wrap_angle(a: f64) -> f64         // into [-PI, PI)
fn move_toward(x: f64, target: f64, max_delta: f64) -> f64
```

Each at both widths. Elementwise `float2/3/4` versions may follow in `vec`.
No copies of these exist in `gfx`, `ui` or `physics` today, so this phase
is for programs, not consolidation.

## Phase 4: integers

Generic over the integer types where the body allows it:

```goose
fn gcd<T>(a: T, b: T) -> T           fn lcm<T>(a: T, b: T) -> T
fn ipow<T>(base: T, exp: i64) -> T   // overflow as any multiply (§6.2)
fn isqrt(x: u64) -> u64              fn ilog2(x: u64) -> i64    fn ilog10(x: u64) -> i64
fn div_floor<T>(a: T, b: T) -> T     fn div_ceil<T>(a: T, b: T) -> T
fn is_pow2(x: u64) -> bool           fn align_up(x: u64, a: u64) -> u64
```

Overflow-aware arithmetic, written in Goose rather than over
`__builtin_*_overflow`, which TinyCC may not provide:

```goose
fn add_checked<T>(a: T, b: T) -> T, bool      // result and whether it fit
fn add_saturating<T>(a: T, b: T) -> T
fn add_wrapping<T>(a: T, b: T) -> T           // never aborts, debug included
// sub_ and mul_, likewise
```

`add_wrapping` on a signed type must not compute through a signed `+`,
because that aborts in debug. It goes through the unsigned type of the same
width with `as!`.

```goose
fn mul_hi(a: u64, b: u64) -> u64
fn mul_wide(a: u64, b: u64) -> u64, u64       // hi, lo
```

When the u128 plan lands, `mul_wide` returns a `u128` instead; `mul_hi`
stays.

## Out of scope

Statistics over slices, complex numbers, special functions (`erf`,
`gamma`), and SIMD versions. Each can follow if a program wants it.

## Open questions

1. **Namespace.** `math` declares everything globally, as `std` does. New
   short names (`step`, `fract`, `remap`, `gcd`) are likelier to collide
   with user code. The alternative is `namespace math;` for new
   declarations, with the existing ones left global. Under namespaces.md,
   though, overload sets do not merge across namespaces, and UFCS looks
   only in the caller's namespace. So `x.fract()` would not work from user
   code, and a `math::abs` would hide `std`'s from inside `math`.
   Leaning: keep everything global, matching `std`, and rely on overloads
   being typed tightly enough that clashes are compile errors, not silent
   rebinding.
2. **Numeric limits.** Either language properties on the type names
   (`i64.max`, `u32.max`, `f64.epsilon`, `f64.min_positive`), which the spec
   already writes in prose, or `math` constants (`I64_MAX`, `F64_EPSILON`,
   ...). Constants need no compiler change; properties cover every type at
   once and read as the spec does. Leaning: constants in this work, with
   properties proposed separately as a spec change.
3. **Integer arguments.** `sqrt(2)` is ambiguous today, because an integer
   converts to both `f32` and `f64` (docs/stdlib.md), so it has to be
   `sqrt(2 as f64)`. Integer overloads returning `f64` would fix that, at
   the cost of an `f64` computation where a caller expected the `f32`
   one to win. Leaning: leave it, since the error is clear and the fix is
   one cast.
