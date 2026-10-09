// Stored calls as deferred calls (docs/design/deferred_calls.md): n calls of
// four kinds, chosen at random, built into an array and then run `passes`
// times, each pass threading one u64 through all of them.
//
//   calls_deferred <n> <passes>   ->   build_ns run_ns checksum bytes_per_call
import os;
import std;

deferred Op(x: u64) -> u64;

fn add(k: u64, x: u64) -> u64 { x + k }
fn mul(k: u64, x: u64) -> u64 { x * k }
fn mix(a: u32, b: u32, x: u64) -> u64 { (x ^ a) + b }
fn rot(n: u8, x: u64) -> u64 { (x << n) | (x >> (64 - n)) }

fn xs_next(x: u64) -> u64 {
    var v = x;
    v ^= v << 13;
    v ^= v >> 7;
    v ^= v << 17;
    v
}

fn build(ops: Op[>..<]&, n: i64) {
    var r: u64 = 88172645463325252;
    for i in n {
        r = xs_next(r);
        let k = r % 4;
        let v = r >> 8;
        if k == 0 { ops.push(Op(add, v)); }
        else if k == 1 { ops.push(Op(mul, v | 1)); }
        else if k == 2 { ops.push(Op(mix, v as! u32, (v >> 32) as! u32)); }
        else { ops.push(Op(rot, (v % 63 + 1) as! u8)); }
    }
}

fn run(ops: Op[:], passes: i64) -> u64 {
    var x: u64 = 1;
    for p in passes {
        for o in ops { x = o(x); }
    }
    x
}

fn main() {
    let a = args();
    let n = parse_int(a[1]);
    let passes = parse_int(a[2]);
    var ops: Op[>..<] = [];
    let t0 = clock_ns();
    build(ops, n);
    let t1 = clock_ns();
    let x = run(ops[..], passes);
    let t2 = clock_ns();
    print(t1 - t0, " ", t2 - t1, " ", x, " ", bytes_of(ops[..]).len / n);
}
