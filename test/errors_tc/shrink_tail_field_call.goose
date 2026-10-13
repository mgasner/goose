// error: which shrinks res while head is still used
// A call that shrinks a parameter's tail field shrinks the argument's
// storage (§5.1): a slice into it is still used after the call.
import std;
struct Response { status: i64, body: u8[>..] }
fn reset(r: Response&) { r.body.clear(); }
fn main() {
    var res = Response { status: 200, body: [] };
    res.body.append("hello");
    let head = res.body[..2];
    reset(res);
    print(head);
}
