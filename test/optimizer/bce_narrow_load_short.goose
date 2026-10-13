// A byte indexes a 256-entry table without a check, but not a 255-entry
// one: the check on the shorter table stays, and fires on the byte 255.
import std;
const SHORT: u8[255] = [1; 255];
fn count(s: const u8[:]) -> i64 {
    var t = 0;
    for k in s.len {
        t += SHORT[ // bce:keep
            s[k]];
    }
    return t;
}
fn main() {
    let a: u8[2] = [1, 254];
    print(count(a));
    let b: u8[2] = [1, 255];
    print(count(b));
}
