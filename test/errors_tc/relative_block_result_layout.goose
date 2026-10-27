// error: a block result containing relative links to its destination cannot change representation
struct Node { id: i64, next: Node&<u32>? }
fn replace<F>(a: Node[..4]&) { a = F(); }
fn main() {
    var a: Node[..4] = [Node { id: 1 }];
    let first .= a[0];
    replace(a) { [Node { id: 2, next: first }, Node { id: 3, next: first }] };
}
