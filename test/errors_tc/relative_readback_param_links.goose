// error: a relative reference must point within the same root as its location (§3.9); this reference is rooted at pool
// The holder's links name the caller's other pool, so they cannot be stored
// as self-relative links in this pool.
struct Node { key: i32, plain: Node&?, next: Node&<u32>? }
fn relink(pool: Node[>..]&) {
    var keep: (Node&?)[>..] = [];
    keep.push(pool[0].plain);
    let n = keep[0];
    assert(n);
    pool[1].next .= n;
}
fn main() {
    var other: Node[>..] = [];
    other.push(Node { key: 3 });
    var pool: Node[>..] = [];
    pool.push(Node { key: 1 });
    pool.push(Node { key: 2 });
    pool[0].plain .= other[0];
    relink(pool);
}
