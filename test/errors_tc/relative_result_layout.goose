// error: a result containing relative links to its destination cannot change representation
struct Node { id: i64, next: Node&<u32>? }
fn make(first: Node&) -> Node[2] {
    [Node { id: 2, next: first }, Node { id: 3, next: first }]
}
fn main() {
    var a: Node[..4] = [Node { id: 1 }];
    a = make(a[0]);
}
