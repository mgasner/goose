// What every part of json shares: word-at-a-time helpers, the 128-bit
// multiply, bit access to doubles, and errors.
//
// "SWAR" below is SIMD within a register: a u64 read as eight byte lanes,
// lane 0 the lowest byte, the first in memory. A lane test leaves 0x80 set
// in each lane it holds for; the lowest set lane is always a true one, so
// `first_lane` finds the first matching byte exactly.

namespace json;

import std;

// --- words --------------------------------------------------------------------

let ONES: u64 = 0x0101010101010101;
let HIGHS: u64 = 0x8080808080808080;

// Eight bytes from s[at], lane 0 first. One range check; clang makes one load.
fn load8(s: const u8[:], at: i64) -> u64 {
    let w = s[at..at + 8];
    return w[0] | (w[1] as u64 << 8) | (w[2] as u64 << 16) | (w[3] as u64 << 24) |
           (w[4] as u64 << 32) | (w[5] as u64 << 40) | (w[6] as u64 << 48) | (w[7] as u64 << 56);
}

// The lanes of x holding byte c.
fn lanes_eq(x: u64, c: u64) -> u64 {
    let y = x ^ (c * ONES);
    return (y - ONES) & ~y & HIGHS;
}

// The lanes of x below n (n <= 128).
fn lanes_lt(x: u64, n: u64) -> u64 { (x - n * ONES) & ~x & HIGHS }

// The index of the lowest flagged lane of a nonzero lane mask.
fn first_lane(m: u64) -> i64 { ctz64(m) >> 3 }

const DEBRUIJN: u8[64] = [
    0, 1, 56, 2, 57, 49, 28, 3, 61, 58, 42, 50, 38, 29, 17, 4, 62, 47, 59, 36, 45, 43, 51, 22, 53, 39, 33, 30, 24, 18, 12, 5,
    63, 55, 48, 27, 60, 41, 37, 16, 46, 35, 44, 21, 52, 32, 23, 11, 54, 26, 40, 15, 34, 20, 31, 10, 25, 14, 19, 9, 13, 8, 7, 6,
];

// Trailing zero bits of a nonzero x, without a loop.
fn ctz64(x: u64) -> i64 { DEBRUIJN[((x & (0 - x)) * 0x03f79d71b4ca8b09) >> 58] }

// Leading zero bits of a nonzero x, by halving.
fn clz64(x: u64) -> i64 {
    var v = x;
    var n = 0;
    if v >> 32 == 0 { n += 32; v = v << 32; }
    if v >> 48 == 0 { n += 16; v = v << 16; }
    if v >> 56 == 0 { n += 8; v = v << 8; }
    if v >> 60 == 0 { n += 4; v = v << 4; }
    if v >> 62 == 0 { n += 2; v = v << 2; }
    if v >> 63 == 0 { n += 1; }
    return n;
}

// The 128-bit product of a and b: high word, low word.
fn mul128(a: u64, b: u64) -> u64, u64 {
    let a0 = a & 0xffffffff;
    let a1 = a >> 32;
    let b0 = b & 0xffffffff;
    let b1 = b >> 32;
    let p00 = a0 * b0;
    let p01 = a0 * b1;
    let p10 = a1 * b0;
    let p11 = a1 * b1;
    let mid = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff);
    return p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32), (mid << 32) | (p00 & 0xffffffff);
}

// --- doubles as bits -------------------------------------------------------------

// The IEEE bits of x.
fn bits_of(x: f64) -> u64 {
    let a: f64[1] = [x];
    let b = bytes_of(a);
    let w = b[0..8];
    return w[0] | (w[1] as u64 << 8) | (w[2] as u64 << 16) | (w[3] as u64 << 24) |
           (w[4] as u64 << 32) | (w[5] as u64 << 40) | (w[6] as u64 << 48) | (w[7] as u64 << 56);
}

// The double with these IEEE bits, built by exact arithmetic: a value that
// is representable is reached through scalings by powers of two that each
// stay exact. NaN payloads are not kept.
fn f64_of(bits: u64) -> f64 {
    let neg = bits >> 63 != 0;
    let be = ((bits >> 52) & 0x7ff) as i64;
    let frac = bits & 0xfffffffffffff;
    var x = 0.0;
    if be == 0x7ff {
        x = if frac == 0 { 1.0 / 0.0 } else { 0.0 / 0.0 };
    } else {
        var m = frac;
        var e = -1074;
        if be != 0 { m = frac | (1 << 52); e = be - 1075; }
        x = m;
        while e > 63 { x = x * POW2[127]; e -= 63; }
        while e < -64 { x = x * POW2[0]; e += 64; }
        x = x * POW2[e + 64];
    }
    return if neg { -x } else { x };
}

// --- errors ---------------------------------------------------------------------

// What went wrong and the byte it was found at; `ok` when nothing did.
struct Error { ok: bool = true, at: i64 = -1, message: u8[..48] = [] }

fn ::error(e: json::Error&, at: i64, message: const u8[:]) {
    if !e.ok { return; }
    e.ok = false;
    e.at = at;
    e.message.clear();
    e.message.append(message[..min(message.len, 48)]);
}
