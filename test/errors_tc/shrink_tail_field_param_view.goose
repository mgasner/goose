// error: cannot clear r while first is still used
// A view of the parameter's tail field, still used after the callee shrinks
// it through the field (§5.1).
import std;
struct Response { status: i64, body: u8[>..] }
fn reset(r: Response&) -> i64 {
    let first = r.body[..1];
    r.body.clear();
    return first.len;
}
fn main() {
    var res = Response { status: 200, body: [] };
    res.body.append("hello");
    print(reset(res));
}
