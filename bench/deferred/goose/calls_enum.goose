// The same stored calls as a hand-written enum and case functions: n calls of
// four kinds, chosen at random, built into an array and then run `passes`
// times, each pass threading one u64 through all of them.
//
//   calls_enum <n> <passes>   ->   build_ns run_ns checksum bytes_per_call
import os;
import std;

enum Op { Add { k: u64 }, Mul { k: u64 }, Mix { a: u32, b: u32 }, Rot { n: u8 } }

fn call(o: Op.Add, x: u64) -> u64 { x + o.k }
fn call(o: Op.Mul, x: u64) -> u64 { x * o.k }
fn call(o: Op.Mix, x: u64) -> u64 { (x ^ o.a) + o.b }
fn call(o: Op.Rot, x: u64) -> u64 { (x << o.n) | (x >> (64 - o.n)) }

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
        if k == 0 { ops.push(Op.Add { k: v }); }
        else if k == 1 { ops.push(Op.Mul { k: v | 1 }); }
        else if k == 2 { ops.push(Op.Mix { a: v as! u32, b: (v >> 32) as! u32 }); }
        else { ops.push(Op.Rot { n: (v % 63 + 1) as! u8 }); }
    }
}

fn run(ops: Op[:], passes: i64) -> u64 {
    var x: u64 = 1;
    for p in passes {
        for o in ops { x = call(o, x); }
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
