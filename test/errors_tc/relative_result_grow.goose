// error: the element pushed into a is still under construction
struct Node { id: i64, next: Node&<u32>? }
fn make(a: Node[>..]&) -> Node {
    a.push(Node { id: 2 });
    Node { id: 3, next: a[0] }
}
fn main() {
    var a: Node[>..] = [Node { id: 1 }];
    a.push(make(a));
}
