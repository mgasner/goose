// runtime-debug: relative aggregates use destination channels through normal,
// multiple, dispatched, block and nonlocal returns, also without inlining.
struct Node { id: i64, me: Node&<u32> }
struct Pair { first: Node, second: Node }
enum Kind { A, B }
struct PoolNode { id: i64, next: PoolNode&<u32 in pool>? }
var pool: PoolNode[>..] = [];
enum Wrap { Box { n: PoolNode }, Empty }
fn node(i: i64) -> Node { Node { id: i, me: self } }
fn box(i: i64) -> Wrap.Box { Wrap.Box { n: PoolNode { id: i, next: null } } }
fn array(i: i64) -> Node[2] { [node(i), node(i + 1)] }
fn pair(i: i64) -> Pair { Pair { first: node(i), second: node(i + 1) } }
fn two(i: i64) -> Node, Node { return node(i), node(i + 1); }
fn forwarded(i: i64) -> Node, Node { return two(i); }
fn pick(k: Kind.A, i: i64) -> Node { node(i) }
fn pick(k: Kind.B, i: i64) -> Node { node(i + 1) }
fn invoke<F>() { F(); }
fn leave(i: i64) { return node(i) from distant; }
fn distant(i: i64) -> Node { leave(i); node(0) }
fn distant_block(i: i64) -> Node {
    invoke() { return node(i); };
    node(0)
}
fn leave_two(i: i64) { return two(i) from distant_two; }
fn distant_two(i: i64) -> Node, Node { leave_two(i); return two(0); }
fn main() {
    var ns: Node[>..] = [];
    ns.push(node(1));
    ns.push(distant(2));
    ns.push(distant_block(3));
    var k = Kind.A;
    for i in 2 { ns.push(pick(k, 4)); k = Kind.B; }
    for &n in ns { print(n.me.id); }
    let p = pair(6);
    print(p.first.me.id, " ", p.second.me.id);
    let a, b = forwarded(8);
    print(a.me.id, " ", b.me.id);
    let c, d = distant_two(10);
    print(c.me.id, " ", d.me.id);
    var fixed: Node[..2] = [];
    fixed.push(node(12));
    fixed.push(distant(13));
    print(fixed[0].me.id, " ", fixed[1].me.id);
    let w: Wrap = box(14);
    match w { Box b => print(b.n.id), Empty => print(0) };
    let adapted: Node[..3] = array(15);
    print(adapted[0].me.id, " ", adapted[1].me.id);
}
