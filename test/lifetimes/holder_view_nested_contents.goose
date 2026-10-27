// A nested store is part of the parameter holder's contents. Reading it
// into another helper preserves that source through the caller's loops.
import std;
struct Holder { data: u8[:] }
fn nested(h: Holder&, out: u8[>..]&, source: u8[>..]&) {
    fn store() { h.data = source[..]; }
    fn consume(data: const u8[:]) { out.clear(); out.append(data); }
    for i in 2 {
        store();
        consume(h.data);
    }
}
fn invoke<F>() { F(); }
fn callback(h: Holder&, out: u8[>..]&, source: u8[>..]&) {
    fn consume(data: const u8[:]) { out.clear(); out.append(data); }
    invoke() { h.data = source[..]; }
    consume(h.data);
}
fn main() {
    var source: u8[>..] = [7, 8];
    var holders: Holder[>..] = [];
    holders.push(Holder { .. });
    var out: u8[>..] = [1, 2, 3];
    for i in 2 {
        nested(holders[0], out, source);
        assert(out == source && source.len == 2);
    }
    var h = Holder { .. };
    for i in 2 {
        callback(h, out, source);
        assert(out == source && source.len == 2);
    }
    print("nested holder contents");
}
