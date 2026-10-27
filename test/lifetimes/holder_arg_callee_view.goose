// A reference holder filled with a local array cannot refer to a same-typed
// global, so a live view of that global survives replacement through it.
var cfg: u8[>..] = ['c', 'f', 'g'];
struct S { text: u8[>..]&, refs: (i64&)[>..] }
fn prepare(s: S&) {
    let v: const u8[:] = cfg[..];
    s.text = ['x'];
    print(v);
    assert(s.text.len == 1 && s.text[0] == 120);
}
fn main() {
    var text: u8[>..] = [];
    var s = S { text: text, refs: [] };
    prepare(s);
}
