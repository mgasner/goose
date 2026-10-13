// A guard on a counter nothing bounds above: `i + 2` wraps past the largest i64 in
// a release build, the guard passes, and the read keeps its check, which
// fires here (§6.2). The guard is trusted only for a counter whose bound
// the analysis already has.
import std;
recursive fn at(s: const u8[:], k: i64) -> i64 {
    if k < 0 { return -1; }
    var i = k;
    if i + 2 > s.len { return -1; }
    return s[i]; // bce:keep
}
fn main() {
    let ks: i64[2] = [3, 9223372036854775806];
    let s = "GET /";
    print(at(s, ks[0]));
    print(at(s, ks[1]));
}
