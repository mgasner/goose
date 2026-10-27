// error: a result containing relative links to its destination cannot be a resize fill value
struct Node { id: i64, next: Node&<u32>? }
fn make(first: Node&) -> Node { Node { id: 2, next: first } }
fn main() {
    var a: Node[>..] = [Node { id: 1 }];
    a.resize(3, make(a[0]));
}
