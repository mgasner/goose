// A global's `x >= 0` is checked assuming every candidate invariant, `y >= 0`
// among them; `y = -5`, in a body checked later, drops y's, and x's must be
// checked again without it. `x` is negative here, so the check stays and
// fires.
import std;
var x = 0;
var y = 0;
fn a() { x = y; }
fn b() { y = -5; }
fn main() {
    let arr: i64[4] = [1, 2, 3, 4];
    print(arr[x]); // bce:keep
    b();
    a();
    if x < 4 { print(arr[x]); } // bce:keep
}
