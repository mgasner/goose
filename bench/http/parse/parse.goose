// Suite P (bench/http/design.md): the Goose request parser, alone. Parses
// every request in a corpus file, R times per batch, and prints what
// bench/spawn's harnesses print, plus a checksum the C harness must match.
//
//   parse <corpus> <seq|fresh|prefix> <target_ns> <batches>
//
// seq parses the requests back to back, as the server does with pipelined
// input. fresh does too, on a new copy of the corpus each pass, for chunked
// bodies, whose decoding rewrites the input in place. prefix parses every
// proper prefix of the corpus's first request, each of which must be found
// incomplete.

import std;
import os;
import http;

var sink = 0;

// The requests back to back, `reps` times. One Request serves the whole
// run, as one serves a batch in the server: building one writes all its
// header slots, which would be most of the cost of a small request.
fn seq(work: u8[:], reps: i64) -> i64, i64 {
    var units = 0;
    var check = 0;
    let limits = http::Limits { max_body: 1 << 30, .. };
    var req = http::Request { .. };
    for r in reps {
        var at = 0;
        while at < work.len {
            let n, need = http::parse(work[at..], req, limits);
            if n <= 0 {
                print("parse failed at byte ", at, ": ", n, " ", need);
                exit(1);
            }
            check += req.method.len + req.target.len + 3 * req.headers.len + req.body.len + n;
            at += n;
            units++;
        }
    }
    return units, check;
}

// seq on a fresh copy of the corpus each pass, for chunked bodies, which
// parsing decodes in place.
fn fresh(text: const u8[:], work: u8[>..]&, reps: i64) -> i64, i64 {
    var units = 0;
    var check = 0;
    for r in reps {
        work.clear();
        work.append(text);
        let u, c = seq(work, 1);
        units += u;
        check += c;
    }
    return units, check;
}

fn prefixes(text: const u8[:], work: u8[>..]&, reps: i64) -> i64, i64 {
    var units = 0;
    var check = 0;
    let limits = http::Limits { max_body: 1 << 30, .. };
    var req = http::Request { .. };
    let whole, w0 = http::parse(work, req, limits);
    for r in reps {
        var part = http::Request { .. };
        for len in 1..whole {
            let n, need = http::parse(work[..len], part, limits);
            if n != 0 {
                print("prefix of ", len, " bytes parsed as ", n);
                exit(1);
            }
            check += need + 1;
            units++;
        }
    }
    return units, check;
}

fn main() {
    let a = args();
    guard a.len == 5 else { abort("usage: parse <corpus> <seq|fresh|prefix> <target_ns> <batches>"); }
    var text: u8[>..] = [];
    guard read_file(a[1], text) else { abort("cannot read the corpus"); }
    let mode = a[2];
    let target, tok = parse_int(a[3]);
    let batches, bok = parse_int(a[4]);
    guard tok && bok else { abort("bad numbers"); }
    var work: u8[>..] = [];
    work.append(text);

    fn run(reps: i64) -> i64, i64 {
        if mode == "prefix" { return prefixes(text, work, reps); }
        if mode == "fresh" { return fresh(text, work, reps); }
        return seq(work, reps);
    }

    let u1, c1 = run(1);
    print("check ", c1, " units ", u1);
    let w0 = clock_ns();
    var i = 0;
    while i < 50 && clock_ns() - w0 < target / 4 {
        let u, c = run(1);
        sink += c;
        i++;
    }
    var reps = 1;
    loop {
        let t = clock_ns();
        let u, c = run(reps);
        sink += c;
        if clock_ns() - t >= target { break; }
        reps *= 2;
    }
    for b in batches {
        let t = clock_ns();
        let u, c = run(reps);
        let dt = clock_ns() - t;
        sink += c;
        print("batch units=", u, " ns=", dt);
    }
    print("sink ", sink % 7);
}
