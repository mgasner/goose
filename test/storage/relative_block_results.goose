// runtime-debug: fresh block results, including chosen branches and forwarded
// calls, construct self-contained relative links at their receiver.
import std;
struct Node { id: i64, me: Node&<u32> }
struct Row { id: i64, me: Row&<u32>, text: u8[] }
fn give<F>() { F() }
fn forward<F>() { give(F) }
fn named(i: i64) -> Node { Node { id: i, me: self } }
fn main() {
    let xs = [1, 2, 3];
    let ns = map(xs) { Node { id: it, me: self } };
    for &n in ns { print(n.me.id); }
    let rs = map(xs) { Row { id: it, me: self, text: str(it) } };
    for r in rs { print(r.me.id, " ", r.me.text); }
    for i in 3 {
        let a = give() { if i == 0 { Node { id: 10, me: self } } else { named(20) } };
        let b = forward() { match i { 0 => named(30), _ => Node { id: 40, me: self } } };
        let c = give() { loop { if i == 0 { break named(50); } break Node { id: 60, me: self }; } };
        let d = give() { block { if i == 0 { break named(70); } Node { id: 80, me: self } } };
        print(a.me.id, " ", b.me.id, " ", c.me.id, " ", d.me.id);
    }
}
