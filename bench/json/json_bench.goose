// The json module on one file: `json_bench file.json reps [key1 key2]`.
// Prints one line of name=value pairs, each the best of `reps` runs:
//   parse      json::parse, MB/s of input
//   walk       every value of the document visited and its scalars read, MB/s
//   write      the document written back compactly, MB/s of output
//   index      the cursor's stage 1 alone, MB/s
//   find       json::cursor, then root.get(key1).get(key2), MB/s
//   find_doc   json::parse, then the same lookup, MB/s
//   fwrite     json::write_float on the file's doubles, ns each
//   fread      json::scan_number on that text, ns each
// bench/json/json_bench.py builds and runs it.
import std;
import os;
import json;

recursive fn walk(v: json::Value) -> i64 {
    let k = v.kind();
    var n = 1;
    if k == json::K_ARRAY { v.each() { x => n += walk(x); }; }
    else if k == json::K_OBJECT { v.members() { key, x => n += walk(x); }; }
    else if k == json::K_STRING { n += v.string().len; }
    else if k == json::K_INT || k == json::K_UINT || k == json::K_FLOAT { n += v.float() as! i64; }
    return n;
}

fn mbs(bytes: i64, ns: i64) -> i64 { bytes * 1000 / max(ns, 1) }

fn main() {
    let a = args();
    var text: u8[>..] = [];
    guard a.len >= 3 && read_file(a[1], text) else { print("usage: json_bench file.json reps [key1 key2]"); exit(2); }
    let reps, ok = parse_int(a[2]);
    let k1 = if a.len > 3 { a[3] } else { "" };
    let k2 = if a.len > 4 { a[4] } else { "" };
    var best = default<i64[8]>();
    for i in 8 { best[i] = 1 << 62; }
    var outlen = 0;
    var sink: i64 = 0;
    for r in reps {
        let t0 = clock_ns();
        let d = json::parse(text);
        let t1 = clock_ns();
        sink += walk(d.root());
        let t2 = clock_ns();
        var out: u8[>..] = [];
        var w = json::writer(out);
        w.value(d.root());
        let t3 = clock_ns();
        var ix: u32[>..] = [];
        json::index(text, ix);
        let t4 = clock_ns();
        var c = json::cursor(text);
        sink += c.root().get(k1).get(k2).int();
        let t5 = clock_ns();
        let d2 = json::parse(text);
        sink += d2.root().get(k1).get(k2).int();
        let t6 = clock_ns();
        outlen = out.len;
        best[0] = min(best[0], t1 - t0);
        best[1] = min(best[1], t2 - t1);
        best[2] = min(best[2], t3 - t2);
        best[3] = min(best[3], t4 - t3);
        best[4] = min(best[4], t5 - t4);
        best[5] = min(best[5], t6 - t5);
    }
    // The doubles alone.
    let d = json::parse(text);
    var xs: f64[>..] = [];
    for v in d.tape[..d.ntape] { if v.head & 15 == json::K_FLOAT { xs.push(json::f64_of(v.data)); } }
    var fw = 0;
    var fr = 0;
    if xs.len > 0 {
        var best_w: i64 = 1 << 62;
        var best_r: i64 = 1 << 62;
        var out: u8[>..] = [];
        for r in reps {
            out.clear();
            let t0 = clock_ns();
            for x in xs { json::write_float(out, x); out.push(','); }
            let t1 = clock_ns();
            var i = 0;
            while i < out.len {
                let kind, b, end = json::scan_number(out, i);
                sink += b as! i64;
                i = end + 1;
            }
            let t2 = clock_ns();
            best_w = min(best_w, t1 - t0);
            best_r = min(best_r, t2 - t1);
        }
        fw = best_w * 1000 / xs.len;
        fr = best_r * 1000 / xs.len;
    }
    let n = text.len;
    print("bytes=", n, " entries=", d.ntape, " doubles=", xs.len,
          " parse=", mbs(n, best[0]), " walk=", mbs(n, best[0] + best[1]), " write=", mbs(outlen, best[2]),
          " index=", mbs(n, best[3]), " find=", mbs(n, best[4]), " find_doc=", mbs(n, best[5]),
          " fwrite_ps=", fw, " fread_ps=", fr, " sink=", sink % 2);
}
