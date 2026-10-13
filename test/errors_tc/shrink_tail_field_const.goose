// error: non-writable
// A tail field reached through a `const` reference cannot shrink (§9.5).
import std;
struct Response { status: i64, body: u8[>..] }
fn reset(res: const Response&) { res.body.clear(); }
fn main() {
    var res = Response { status: 200, body: [] };
    reset(res);
    print(res.status);
}
