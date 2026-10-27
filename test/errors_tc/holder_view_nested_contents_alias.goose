// error: cannot call consume: it shrinks out while data is still used
// A nested store really puts a view of out in h, through the aliased source.
struct Holder { data: u8[:] }
fn transfer(h: Holder&, out: u8[>..]&, source: u8[>..]&) {
    fn store() { h.data = source[..]; }
    fn consume(data: const u8[:]) { out.clear(); out.append(data); }
    store();
    consume(h.data);
}
fn main() {
    var out: u8[>..] = [1, 2];
    var holders: Holder[>..] = [];
    holders.push(Holder { .. });
    for i in 2 { transfer(holders[0], out, out); }
}
