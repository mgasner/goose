// Checks json's double conversions against a file of cases that
// check.py writes from Python's correctly rounded repr and float():
//   W <bits> <text>   write_float of the double with these bits gives text
//   R <text> <bits>   parse_float of text gives the double with these bits
// Prints the counts and the first mismatches.
import std;
import os;
import json;

fn hex(s: const u8[:]) -> u64 {
    var v: u64 = 0;
    for c in s { v = v * 16 + (if c <= '9' { (c - '0') as u64 } else { (c - 'a' + 10) as u64 }); }
    return v;
}

fn main() {
    let a = args();
    var text: u8[>..] = [];
    guard a.len == 2 && read_file(a[1], text) else { print("usage: numcheck cases.txt"); exit(2); }
    var bad = 0;
    var nw = 0;
    var nr = 0;
    var out: u8[>..] = [];
    for line in split(text, '\n') {
        if line.len < 3 { continue; }
        let parts = split(line, ' ');
        if line[0] == 'W' {
            nw++;
            out.clear();
            json::write_float(out, json::f64_of(hex(parts[1])));
            if out != parts[2] {
                bad++;
                if bad <= 20 { print("write ", parts[1], ": got ", out, ", want ", parts[2]); }
            }
        } else {
            nr++;
            let x, ok = json::parse_float(parts[1]);
            if !ok || json::bits_of(x) != hex(parts[2]) {
                bad++;
                if bad <= 20 { print("read ", parts[1], ": got ", json::bits_of(x), ", want ", hex(parts[2])); }
            }
        }
    }
    print(nw, " writes, ", nr, " reads, ", bad, " wrong");
    if bad > 0 { exit(1); }
}
