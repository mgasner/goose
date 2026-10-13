// error: or the tail field of a struct named so
// The field path reaches the array through a reference field, whose root
// is what the reference was bound to, not the struct named (§5.1).
import std;
struct Response { status: i64, body: u8[>..] }
struct Holder { r: Response& }
fn main() {
    var res = Response { status: 200, body: [] };
    let h = Holder { r: res };
    h.r.body.clear();
    print(res.status);
}
