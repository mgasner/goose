// A function value's block, or a nested function, rebinding a reference
// variable outside it to what its call hands it, called in a loop: the
// variable points where each call passed, not at the class the body's check
// saw, so the loop's passes settle (§7.5).
import std;

fn each<F>(xs: i64[:]) { for i in 0..xs.len { F(&xs[i]); } }
fn apply<G>(ys: i64[:]) { each(ys) { q => G(q); }; }

fn block_rebind() {
    var arr: i64[>..] = [];
    arr.push(1);
    arr.push(2);
    var r: i64&? = null;
    for i in 0..3 {
        each(arr[..]) { p => if p == 2 { r .= p; } };
    }
    if r { print(r); }
}

fn nested_rebind() {
    var arr: i64[>..] = [];
    arr.push(3);
    var r: i64&? = null;
    fn keep(p: i64&) { r .= p; }
    for i in 0..3 { keep(arr[0]); }
    if r { print(r); }
}

// Through two function values: each's class stands for apply's, which
// stands for arr.
fn two_levels() {
    var arr: i64[>..] = [];
    arr.push(4);
    var r: i64&? = null;
    for i in 0..3 {
        apply(arr[..]) { p => r .= p; };
    }
    if r { print(r); }
}

// r already points where the loop's block rebinds it, and q's first binding
// takes the loop to a second pass, which finds r as the first did.
fn bound_before() {
    var arr: i64[>..] = [];
    arr.push(5);
    var r: i64&? = null;
    each(arr[..]) { p => r .= p; };
    var q: i64&? = null;
    for i in 0..3 {
        if q { print(q); }
        q .= arr[0];
        each(arr[..]) { p => r .= p; };
    }
    if r { print(r); }
}

// A block rebinding a reference to a tree node in a loop of a nested
// function, whose call from another block stores what it leads to. The tree
// is a pool of nodes linked by self-relative references, in the shape of
// {"x": {"a": 1, "b": 2}, "y": {"a": 3}}.
struct Node { next: Node&<u32>?, first: Node&<u32>?, key: const u8[:] }
struct P { name: const u8[:], n: i64 }

// F(child) for each child of n, in order.
fn each<F>(n: Node&) {
    var c = n.first;
    while c {
        F(c);
        c .= c.next;
    }
}

fn tree_members() -> i64 {
    var doc: Node[>..] = [];
    var ps: P[>..] = [];
    fn load(list: Node&) {
        for i in 2 {
            var chosen: Node? = null;
            each(list) { p => if p.key == "a" { chosen .= p; } };
            guard chosen else { continue; }
            ps.push(P { name: chosen.key, n: i });
        }
    }
    let root .= doc.push(Node { next: null, first: null, key: "" });
    let x .= doc.push(Node { next: null, first: null, key: "x" });
    root.first .= x;
    let xa .= doc.push(Node { next: null, first: null, key: "a" });
    x.first .= xa;
    let xb .= doc.push(Node { next: null, first: null, key: "b" });
    xa.next .= xb;
    let y .= doc.push(Node { next: null, first: null, key: "y" });
    x.next .= y;
    let ya .= doc.push(Node { next: null, first: null, key: "a" });
    y.first .= ya;
    each(root) { item => load(item); };
    for p in ps { print(p.name, " ", p.n); }
    return ps.len;
}

fn main() {
    block_rebind();
    nested_rebind();
    two_levels();
    bound_before();
    print(tree_members());
}
