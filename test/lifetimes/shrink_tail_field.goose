// A grow-only array that is a struct's tail field shrinks through the
// field, `res.body.clear()`, as the struct's own resizable part (§5.1): the
// struct's root is what shrinks, so a reference parameter's callers judge
// it, as they would a shrink of the struct.
import std;

struct Response { status: i64, body: u8[>..] }
struct Outer { id: i64, res: Response }

fn reset(res: Response&) {
    res.body.clear();
    res.status = 0;
}
fn refill(res: Response&, n: i64) {
    res.body.resize(n, 'x');
    res.body.pop();
}
fn nested(o: Outer&) { o.res.body.clear(); }

var global = Response { status: 1, body: [] };

fn main() {
    var res = Response { status: 200, body: [] };
    res.body.append("hello");
    let head = res.body[..2];
    print(head);
    reset(res);
    print(res.status, " [", res.body, "]");
    refill(res, 4);
    print(res.body);
    res.body.clear();
    res.body.append("ok");
    res.body.pop();
    print(res.body);
    var o = Outer { id: 1, res: Response { status: 2, body: [] } };
    o.res.body.append("abc");
    nested(o);
    o.res.body.append("d");
    print(o.res.body);
    global.body.append("g");
    global.body.clear();
    print(global.body.len);
}
