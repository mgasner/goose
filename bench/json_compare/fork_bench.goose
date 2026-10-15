// The fork's json module (stdlib/json.goose, stdlib/json/) on one task:
//   fork_bench <task> <file> <reps> [out]
// Tasks, each timed per rep after one untimed warmup rep:
//   parse          json::parse to a document
//   kostya_dom     json::parse, then the average x, y, z of root.coordinates
//   kostya_stream  json::cursor, then the same averages
//   write          a parsed document written back compactly with w.value()
//   write_walk     the same, by a user walk over the document calling the
//                  writer per value, as ujson_bench must (the like-for-like row)
//   read           the file only (baseline for peak RSS)
//   hash           not timed: a content hash of the document (common.goose)
//   roundtrip      not timed: write the document to [out]
// Prints "ns=<t1>,<t2>,..." and a result line.
import std;
import os;
import json;
import common;

recursive fn hash(h: common::Hash&, v: json::Value) {
    let k = v.kind();
    if k == json::K_ARRAY {
        common::container(h, 'a', v.count());
        v.each() { x => hash(h, x); };
    } else if k == json::K_OBJECT {
        common::container(h, 'o', v.count());
        v.members() { key, x => common::key(h, key); hash(h, x); };
    } else if k == json::K_STRING { common::string(h, v.string()); }
    else if k == json::K_INT || k == json::K_UINT || k == json::K_FLOAT { common::number(h, v.float()); }
    else if k == json::K_TRUE { common::kind(h, 't'); }
    else if k == json::K_FALSE { common::kind(h, 'f'); }
    else { common::kind(h, 'z'); }
}

// What ujson_bench's writer does, through this module's writer.
recursive fn write_walk(w: json::Writer<u8[>..]>&, v: json::Value) {
    let k = v.kind();
    if k == json::K_ARRAY { w.array() { v.each() { x => write_walk(w, x); }; }; }
    else if k == json::K_OBJECT { w.object() { v.members() { key, x => w.key(key); write_walk(w, x); }; }; }
    else if k == json::K_STRING { w.string(v.string()); }
    else if k == json::K_INT { w.int(v.int()); }
    else if k == json::K_UINT { w.uint(v.uint()); }
    else if k == json::K_FLOAT { w.float(v.float()); }
    else if k == json::K_TRUE { w.boolean(true); }
    else if k == json::K_FALSE { w.boolean(false); }
    else { w.none(); }
}

fn kostya_dom(text: const u8[:]) -> f64, f64, f64 {
    let d = json::parse(text);
    guard d.ok() else { abort(str("parse error at ", d.error.at)); }
    let coords = d.root().get("coordinates");
    let len: f64 = coords.count();
    var x = 0.0;
    var y = 0.0;
    var z = 0.0;
    coords.each() { c =>
        x += c.get("x").float();
        y += c.get("y").float();
        z += c.get("z").float();
    };
    return x / len, y / len, z / len;
}

fn kostya_stream(text: const u8[:]) -> f64, f64, f64 {
    var c = json::cursor(text);
    let coords = c.root().get("coordinates");
    var n = 0;
    var x = 0.0;
    var y = 0.0;
    var z = 0.0;
    coords.each() { p =>
        x += p.get("x").float();
        y += p.get("y").float();
        z += p.get("z").float();
        n++;
    };
    guard c.ok() else { abort(str("cursor error at ", c.error.at)); }
    let len: f64 = n;
    return x / len, y / len, z / len;
}

// The write tasks: the document is parsed once, untimed, and written per rep.
fn time_write(text: const u8[:], reps: i64, walk: bool) {
    let pre = json::parse(text);
    guard pre.ok() else { abort("parse failed"); }
    var times: u8[>..] = [];
    var outlen = 0;
    for r in reps + 1 {
        let t0 = clock_ns();
        var out: u8[>..] = [];
        var w = json::writer(out);
        if walk { write_walk(w, pre.root()); } else { w.value(pre.root()); }
        outlen = out.len;
        let t1 = clock_ns();
        if r > 0 {
            if times.len > 0 { times.push(','); }
            format(times, t1 - t0);
        }
    }
    print("ns=", times);
    print("bytes=", text.len, " outbytes=", outlen, " sink=0");
}

fn main() {
    let a = args();
    guard a.len >= 3 else { print("usage: fork_bench task file reps [out]"); exit(2); }
    let task = a[1];
    var text: u8[>..] = [];
    guard read_file(a[2], text) else { print("cannot read ", a[2]); exit(2); }
    var reps = 1;
    if a.len > 3 { let r, ok = parse_int(a[3]); reps = r; }

    if task == "hash" {
        let d = json::parse(text);
        guard d.ok() else { print("reject at ", d.error.at, ": ", d.error.message); exit(1); }
        var h = common::Hash {};
        hash(h, d.root());
        common::report(h);
        return;
    }
    if task == "roundtrip" {
        let d = json::parse(text);
        guard d.ok() else { print("reject"); exit(1); }
        var out: u8[>..] = [];
        var w = json::writer(out);
        w.value(d.root());
        guard write_file(a[4], out) else { exit(1); }
        print("bytes=", out.len);
        return;
    }

    if task == "write" || task == "write_walk" { time_write(text, reps, task == "write_walk"); return; }

    var times: u8[>..] = [];
    var sink = 0.0;
    var outlen = 0;
    for r in reps + 1 {
        let t0 = clock_ns();
        if task == "parse" {
            let d = json::parse(text);
            if !d.ok() { abort("parse failed"); }
            sink += d.ntape;
        } else if task == "kostya_dom" {
            let x, y, z = kostya_dom(text);
            sink += x + y + z;
            if r == 0 { print("avg=", x, " ", y, " ", z); }
        } else if task == "kostya_stream" {
            let x, y, z = kostya_stream(text);
            sink += x + y + z;
            if r == 0 { print("avg=", x, " ", y, " ", z); }
        } else if task == "read" {
            sink += text.len;
        } else { print("unknown task ", task); exit(2); }
        let t1 = clock_ns();
        if r > 0 {
            if times.len > 0 { times.push(','); }
            format(times, t1 - t0);
        }
    }
    print("ns=", times);
    print("bytes=", text.len, " outbytes=", outlen, " sink=", sink);
}
