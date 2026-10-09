// `roundtrip in.json out.json`: parses in.json and writes it back compactly.
// check.py compares the result with a Python serializer that writes
// doubles the same way.
import std;
import os;
import json;

fn main() {
    let a = args();
    var text: u8[>..] = [];
    guard a.len == 3 && read_file(a[1], text) else { print("usage: roundtrip in.json out.json"); exit(2); }
    let d = json::parse(text);
    guard d.ok() else { print("error at ", d.error.at, ": ", d.error.message); exit(1); }
    var out: u8[>..] = [];
    var w = json::writer(out);
    w.value(d.root());
    guard write_file(a[2], out) else { print("cannot write ", a[2]); exit(1); }
}
