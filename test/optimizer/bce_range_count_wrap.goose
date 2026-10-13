// A range loop's iteration count is hi - lo of the bounds the machine
// computed. `k + 3` wraps for the largest k (§6.2), and the loop then runs
// no iterations, so the three pushes are not known to have happened unless
// k is bounded: the read keeps its check, which fires here.
import std;
recursive fn bounded(k: i64) -> i64 {
    if k < 0 || k > 100 { return -1; }
    var a: i64[>..] = [];
    for i in k..k + 3 { a.push(i); }
    return a[2]; // bce:elide
}
recursive fn fill(k: i64) -> i64 {
    var a: i64[>..] = [];
    for i in k..k + 3 { a.push(i); }
    return a[2]; // bce:keep
}
fn main() {
    let ks: i64[2] = [5, 9223372036854775806];
    print(bounded(ks[0]));
    print(fill(ks[0]));
    print(fill(ks[1]));
}
