// runtime-debug: result locations travel through calls independently of
// their argument slots. Links to neighbours measure from the final slot.
struct Node { id: i64, next: Node&<u32>? }
struct Row { id: i64, next: Row&<u32>?, text: u8[] }
struct Pooled { id: i64, me: Pooled&<u32 in pool> }
enum Kind { A, B }
var pool: Pooled[>..] = [];
var calls: i64 = 0;
fn make(first: Node&, id: i64) -> Node { Node { id: id, next: first } }
fn forward(first: Node&, id: i64) -> Node { make(first, id) }
fn inferred(first: Node&) { make(first, 15) }
fn give<F>() { F() }
fn many(first: Node&) -> Node, i64 { return make(first, 17), 42; }
fn many_via(first: Node&) -> Node, i64 { return many(first); }
fn pick(k: Kind.A, first: Node&) -> Node { make(first, 18) }
fn pick(k: Kind.B, first: Node&) -> Node { make(first, 19) }
fn chosen(first: Node&, flag: bool) -> Node {
    loop { if flag { break make(first, 13); } break make(first, 14); }
}
fn append<F>(xs: Node[>..]&) { xs.push(F()); }
fn append_via<F>(xs: Node[>..]&) { append(xs, F); }
fn replace<F>(xs: Node[>..]&, at: i64) { xs[at] = F(); }
fn invoke<F>() { F(); }
fn distant(first: Node&) -> Node {
    invoke() { return make(first, 7) from distant; };
    make(first, 0)
}
recursive fn recurse(first: Node&, n: i64) -> Node {
    if n == 0 { return make(first, 8); }
    recurse(first, n - 1)
}
fn row(first: Row&) -> Row { Row { id: 10, next: first, text: "two" } }
fn pooled(id: i64) -> Pooled { Pooled { id: id, me: self } }
fn main() {
    var xs: Node[>..] = [];
    xs.push(Node { id: 1 });
    let first .= xs[0];
    xs.push(make(first, 2));
    xs.push(forward(first, 3));
    append(xs) { calls += 1; Node { id: 4, next: first } };
    append_via(xs) { calls += 1; forward(first, 5) };
    replace(xs, 1) { calls += 1; make(first, 6) };
    xs.push(distant(first));
    xs.push(recurse(first, 4));
    xs.push(chosen(first, true));
    append(xs) { block { if calls == 3 { break make(first, 14); } make(first, 0) } };
    xs.push(inferred(first));
    xs.push(give() { Node { id: 16, next: first } });
    xs.push(many_via(first));
    var k = Kind.A;
    for i in 2 { xs.push(pick(k, first)); k = Kind.B; }
    for &x in xs {
        let next = x.next;
        print(x.id, " ", if next { next.id } else { 0 });
    }
    print(calls);
    var rows: Row[>..] = [];
    let head .= rows.push(Row { id: 9, text: "one" });
    rows.push(row(head));
    for r in rows {
        let next = r.next;
        print(r.text, " ", if next { next.id } else { 0 });
    }
    pool.push(pooled(11));
    pool.push(pooled(12));
    print(pool[0].me.id, " ", pool[1].me.id);
}
