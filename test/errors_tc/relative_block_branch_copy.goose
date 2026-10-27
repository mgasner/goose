// error: copying a value of type Node, which contains self-relative references, is not supported
struct Node { id: i64, me: Node&<u32> }
fn give<F>(b: bool) { F(b) }
fn main() {
    let n = Node { id: 1, me: self };
    let x = give(true) { if it { Node { id: 2, me: self } } else { n } };
    print(x.id);
}
