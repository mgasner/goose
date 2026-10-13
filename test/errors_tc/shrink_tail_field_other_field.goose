// error: cannot clear res while s is still used
// The shrink is of the struct's root, so a reference into another of its
// fields is judged as one into the array (§5.1): conservative, never stale.
import std;
struct Response { status: i64, body: u8[>..] }
fn main() {
    var res = Response { status: 200, body: [] };
    let s = &res.status;
    res.body.clear();
    print(s);
}
