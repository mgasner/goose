// JSONTestSuite: `conformance file...` parses each file with json::parse and
// with a cursor walked to the end, and prints "<file> <doc> <cursor>", each
// accept or reject. bench/json/json_bench.py checks y_ files are accepted
// and n_ files rejected by both.
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

fn main() {
    let a = args();
    for k in 1..a.len {
        var text: u8[>..] = [];
        guard read_file(a[k], text) else { print(a[k], " unreadable"); continue; }
        let d = json::parse(text);
        var c = json::cursor(text);
        if c.ok() { walk(c.root(), 0); }
        print(a[k], if d.ok() { " accept" } else { " reject" }, if c.ok() { " accept" } else { " reject" });
    }
}
