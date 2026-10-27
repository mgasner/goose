// error: cannot infer the element type of []: a block's value is checked without its call's destination
// A block infers its value's type independently of its call's destination
// type (§7.6), so the u8[] the call initializes gives [] no element type.
fn count<F>() -> i64 {
    let x: u8[] = F();
    return x.len;
}
fn main() {
    print(count() { [] });
}
