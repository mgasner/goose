// error: cannot call consume, which shrinks out while h is still used
// The callback rebinds the holder after the first consume; the next
// iteration reads that view of out, even though h entered with other data.
struct Holder { data: u8[:] }
fn invoke<F>() { F(); }
fn transfer(h: Holder&, out: u8[>..]&) {
    fn consume(data: const u8[:]) { out.clear(); out.append(data); }
    for i in 2 {
        consume(h.data);
        invoke() { h.data = out[..]; }
    }
}
fn main() {
    var source: u8[>..] = [7];
    var out: u8[>..] = [1, 2];
    var h = Holder { data: source[..] };
    transfer(h, out);
}
