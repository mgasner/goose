// An element narrower than 64 bits, loaded from memory, lies in its type's
// range (§3.1), as a variable of that type does: a byte from a u8 slice is
// a valid index into any 256-entry table, nested directly in the index as
// well as bound with `let` first (§10.5).
import std;

const CLASS: u8[256] = [1; 256];
const SHORT: u8[255] = [1; 255];
const SIGNED: u8[128] = [1; 128];

fn nested(s: const u8[:]) -> i64 {
    var i = 0;
    while i < s.len && CLASS[s[i]] != 0 { i++; } // bce:elide
    return i;
}

fn bound(s: const u8[:]) -> i64 {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if CLASS[c] == 0 { break; } // bce:elide
        i++;
    }
    return i;
}

// The ranges of other narrow widths, and of struct fields.
struct Pair { lo: u16, hi: u8 }
fn widths(w: const u16[:], p: const Pair[:], t: const u8[65536]&) -> i64 {
    var sum = 0;
    for k in w.len { sum += t[w[k]]; } // bce:elide
    for k in p.len { sum += CLASS[p[k].hi] + t[p[k].lo]; } // bce:elide
    let one = p[0];
    sum += CLASS[one.hi] + t[one.lo]; // bce:elide
    return sum;
}

// Negative: the table is one short of the type's range.
fn short(s: const u8[:]) -> i64 {
    var t = 0;
    for k in s.len {
        t += SHORT[ // bce:keep
            s[k]];
    }
    return t;
}

// Negative: a signed byte may be negative.
fn signed(s: const i8[:]) -> i64 {
    var t = 0;
    for k in s.len {
        t += SIGNED[ // bce:keep
            s[k]];
    }
    return t;
}

// Negative: a 64-bit element says nothing about its value.
fn wide(s: const i64[:]) -> i64 {
    var t = 0;
    for k in s.len {
        t += CLASS[ // bce:keep
            s[k]];
    }
    return t;
}

fn main() {
    let s = "GET / HTTP/1.1";
    print(nested(s));
    print(bound(s));
    var big: u8[>..] = [];
    for k in 65536 { big.push(1); }
    let w: u16[3] = [0, 300, 65535];
    let p: Pair[2] = [Pair { lo: 7, hi: 200 }, Pair { lo: 65535, hi: 255 }];
    let table: u8[65536] = [2; 65536];
    print(widths(w, p, table));
    print(short(s));
    let neg: i8[2] = [5, 127];
    print(signed(neg));
    let ws: i64[2] = [1, 255];
    print(wide(ws));
}
