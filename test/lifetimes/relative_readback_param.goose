// A caller's recorded plain links all point into this pool. A reference
// parameter preserves that identity when storing a self-relative link.
struct Node { key: i32, plain: Node&?, next: Node&<u32>? }
fn relink(pool: Node[>..]&) {
    let n = pool[0].plain;
    assert(n);
    pool[1].next .= n;
}
fn main() {
    var pool: Node[>..] = [];
    pool.push(Node { key: 1 });
    pool.push(Node { key: 2 });
    pool[0].plain .= pool[1];
    relink(pool);
    let n = pool[1].next;
    assert(n);
    assert(n.key == 2);
    print(n.key);
}
