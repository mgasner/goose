// Shared by fork_bench.goose and ujson_bench.goose: a content hash for
// checking that two parsers built the same document, and the timing output.
namespace common;

import std;

// FNV-1a over a document in text order: each value's kind, each key and
// string's bytes, each number as the IEEE bits of its f64 value, and each
// container's count. Two parsers that agree on the data agree on the hash.
struct Hash { h: u64 = 14695981039346656037, values: i64 = 0, strings: i64 = 0, numbers: i64 = 0 }

fn byte(h: Hash&, b: u64) { h.h = (h.h ^ b) * 1099511628211; }

fn word(h: Hash&, w: u64) { for i in 8 { byte(h, (w >> (i * 8)) & 255); } }

fn bits_of(x: f64) -> u64 {
    let a: f64[1] = [x];
    let w = bytes_of(a)[0..8];
    return w[0] | (w[1] as u64 << 8) | (w[2] as u64 << 16) | (w[3] as u64 << 24) |
           (w[4] as u64 << 32) | (w[5] as u64 << 40) | (w[6] as u64 << 48) | (w[7] as u64 << 56);
}

fn text(h: Hash&, s: const u8[:]) {
    word(h, s.len as! u64);
    for b in s { byte(h, b); }
}

fn kind(h: Hash&, k: u8) { byte(h, k); h.values++; }
fn number(h: Hash&, x: f64) { kind(h, 'n'); h.numbers++; word(h, bits_of(x)); }
fn string(h: Hash&, s: const u8[:]) { kind(h, 's'); h.strings++; text(h, s); }
fn key(h: Hash&, s: const u8[:]) { byte(h, 'k'); text(h, s); }
fn container(h: Hash&, k: u8, count: i64) { kind(h, k); word(h, count as! u64); }

fn report(h: Hash&) {
    print("values=", h.values, " numbers=", h.numbers, " strings=", h.strings, " hash=", h.h);
}

// LangArena's generator (bench/kostya/goose/src/helper.goose).
var rng_last: i32 = 42;
fn next_float(max: f64) -> f64 {
    rng_last = (rng_last * 3877 + 29573) % 139968;
    return max * rng_last / 139968;
}
fn next_int(max: i64) -> i32 {
    rng_last = (rng_last * 3877 + 29573) % 139968;
    return (rng_last / 139968 as f64 * max) as! i32;
}
