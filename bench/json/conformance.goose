// JSONTestSuite: `conformance file...` reads each file four ways and prints
// "<file> <doc> <cursor> <reader> <skip>", each accept or reject: json::parse;
// a cursor walked to the end; a reader reading every value; and a reader
// that reads nothing, so that `finish` skips the root. bench/json/json_bench.py
// checks y_ files are accepted and n_ files rejected by all four, and that
// the four agree on every i_ file.
import std;
import os;
import json;

recursive fn walk(v: json::Lazy, depth: i64) {
    if depth > json::max_depth { v.c.error.error(0, "nesting too deep"); return; }
    let k = v.kind();
    if k == json::K_ARRAY { v.each() { x => walk(x, depth + 1); }; }
    else if k == json::K_OBJECT { v.members() { key, x => walk(x, depth + 1); }; }
    else if k == json::K_STRING { v.string(); }
    else if k == json::K_INT || k == json::K_UINT || k == json::K_FLOAT { v.float(); }
    else if k == json::K_MISSING { v.c.error.error(json::pos(v.c, v.p), "not a value"); }
}

// Every value through the reader's own calls; what it does not take is
// skipped, which checks it.
recursive fn read(r: json::Reader&) {
    let k = r.kind();
    if k == json::K_ARRAY { r.each() { read(r); }; }
    else if k == json::K_OBJECT { r.members() { key => read(r); }; }
    else if k == json::K_STRING { r.string(); }
    else if k == json::K_INT || k == json::K_UINT || k == json::K_FLOAT { r.float(); }
    else if k == json::K_TRUE || k == json::K_FALSE { r.boolean(); }
    else { r.skip(); }
}

fn verdict(ok: bool) -> const u8[:] { if ok { " accept" } else { " reject" } }

fn main() {
    let a = args();
    for k in 1..a.len {
        var text: u8[>..] = [];
        guard read_file(a[k], text) else { print(a[k], " unreadable"); continue; }
        let d = json::parse(text);
        var c = json::cursor(text);
        if c.ok() { walk(c.root(), 0); }
        var r = json::reader(text);
        read(r);
        var s = json::reader(text);
        print(a[k], verdict(d.ok()), verdict(c.ok()), verdict(r.finish()), verdict(s.finish()));
    }
}
