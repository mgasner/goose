// error: cannot clear res while head is still used
// A tail field shrinks as its struct does (§5.1): a slice into the field is
// still used after the shrink.
import std;
struct Response { status: i64, body: u8[>..] }
fn main() {
    var res = Response { status: 200, body: [] };
    res.body.append("hello");
    let head = res.body[..2];
    res.body.clear();
    print(head);
}
