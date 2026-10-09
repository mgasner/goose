// Stored calls in Rust, two idiomatic ways, with the same work, input and
// checksum as goose/calls_deferred.goose (bench/deferred/README.md):
//
//   calls_rs <boxed|enum> <n> <passes>  ->  build_ns run_ns checksum bytes_per_call
//
// boxed: Vec<Box<dyn Fn(u64) -> u64>> of closures, each capturing its
//        arguments; bytes_per_call counts the fat pointer and the closure's
//        heap block at the allocator's 16-byte minimum.
// enum:  Vec<Op> of an enum with a match.

use std::hint::black_box;
use std::time::Instant;

fn xs_next(mut v: u64) -> u64 {
    v ^= v << 13;
    v ^= v >> 7;
    v ^= v << 17;
    v
}

fn rotl(x: u64, n: u8) -> u64 { (x << n) | (x >> (64 - n)) }

fn generate(n: i64, mut add: impl FnMut(u64), mut mul: impl FnMut(u64),
            mut mix: impl FnMut(u32, u32), mut rot: impl FnMut(u8)) {
    let mut r: u64 = 88172645463325252;
    for _ in 0..n {
        r = xs_next(r);
        let (k, v) = (r % 4, r >> 8);
        match k {
            0 => add(v),
            1 => mul(v | 1),
            2 => mix(v as u32, (v >> 32) as u32),
            _ => rot((v % 63 + 1) as u8),
        }
    }
}

#[derive(Clone, Copy)]
enum Op { Add(u64), Mul(u64), Mix(u32, u32), Rot(u8) }

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: calls_rs <boxed|enum> <n> <passes>");
        std::process::exit(2);
    }
    let n: i64 = args[2].parse().unwrap();
    let passes: i64 = args[3].parse().unwrap();
    let mut x: u64 = 1;
    let (build, run, bytes);
    match args[1].as_str() {
        "boxed" => {
            let mut ops: Vec<Box<dyn Fn(u64) -> u64>> = Vec::new();
            let t0 = Instant::now();
            {
                let ops = std::cell::RefCell::new(&mut ops);
                generate(n,
                    |k| ops.borrow_mut().push(Box::new(move |x: u64| x.wrapping_add(k))),
                    |k| ops.borrow_mut().push(Box::new(move |x: u64| x.wrapping_mul(k))),
                    |a, b| ops.borrow_mut().push(Box::new(move |x: u64| (x ^ a as u64).wrapping_add(b as u64))),
                    |r| ops.borrow_mut().push(Box::new(move |x: u64| rotl(x, r))));
            }
            let t1 = Instant::now();
            for _ in 0..passes {
                for f in ops.iter() { x = f(x); }
            }
            let t2 = Instant::now();
            build = (t1 - t0).as_nanos();
            run = (t2 - t1).as_nanos();
            bytes = std::mem::size_of::<Box<dyn Fn(u64) -> u64>>() + 16;
            black_box(&ops);
        }
        "enum" => {
            let mut ops: Vec<Op> = Vec::new();
            let t0 = Instant::now();
            {
                let ops = std::cell::RefCell::new(&mut ops);
                generate(n,
                    |k| ops.borrow_mut().push(Op::Add(k)),
                    |k| ops.borrow_mut().push(Op::Mul(k)),
                    |a, b| ops.borrow_mut().push(Op::Mix(a, b)),
                    |r| ops.borrow_mut().push(Op::Rot(r)));
            }
            let t1 = Instant::now();
            for _ in 0..passes {
                for o in ops.iter() {
                    x = match *o {
                        Op::Add(k) => x.wrapping_add(k),
                        Op::Mul(k) => x.wrapping_mul(k),
                        Op::Mix(a, b) => (x ^ a as u64).wrapping_add(b as u64),
                        Op::Rot(r) => rotl(x, r),
                    };
                }
            }
            let t2 = Instant::now();
            build = (t1 - t0).as_nanos();
            run = (t2 - t1).as_nanos();
            bytes = std::mem::size_of::<Op>();
            black_box(&ops);
        }
        m => {
            eprintln!("unknown mode {}", m);
            std::process::exit(2);
        }
    }
    println!("{} {} {} {}", build, run, x, bytes);
}
