// error: copying a value of type Node, which contains self-relative references, is not supported
struct Node { id: i64, me: Node&<u32> }
var n = Node { id: 1, me: self };
fn ref() -> Node& { n }
fn give<F>() { F() }
fn main() { let x = give() { ref() }; print(x.id); }
