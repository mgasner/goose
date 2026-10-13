// `i != n` makes `i <= n` strict, but a counter that may step past n has
// only `i <= n + 1`, and `i == n + 1` passes the test: the check stays and
// fires here.
import std;
fn after(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    while i < n {
        if s[i] == 13 { i += 2; } else { i++; } // bce:elide
    }
    if i == n { return -1; }
    return s[i - 1]; // bce:keep
}
fn main() {
    print(after("ab"));
    print(after("\r"));
}
