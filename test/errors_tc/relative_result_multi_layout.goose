// error: a result containing relative links to its destination cannot change representation
struct Node { id: i64, next: Node&<u32>? }
fn make(first: Node&) -> i64, Node[2] {
    return 1, [Node { id: 2, next: first }, Node { id: 3, next: first }];
}
fn forward(first: Node&) -> i64, Node[..4] { return make(first); }
fn main() {
    var a: Node[>..] = [Node { id: 1 }];
    let n, nodes = forward(a[0]);
    print(n, nodes.len);
}
