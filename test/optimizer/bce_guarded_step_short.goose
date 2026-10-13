// A guard one short of the step: `i + 1 <= n` before `i += 2` leaves the
// counter at up to n + 1, so `i <= len` is no invariant and the read after
// the loop keeps its check, which fires here.
import std;
fn short(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    loop {
        if i + 1 > n { return -1; }
        if s[i] == 13 { i += 2; break; } // bce:keep
        i++;
    }
    return s[i - 1]; // bce:keep
}
fn main() {
    print(short("ab"));
    print(short("\r"));
}
