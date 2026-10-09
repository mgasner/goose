// The graphql module on a pool of workers: requests answered by whichever
// worker is free, lists split across the pool, a mutation run on the main
// thread and its changes synced to every worker's copy of the data, and
// null propagation out of a split list. Every answer is compared with the
// same request run on the main thread, so the output does not depend on
// which worker did what.
import std;
import graphql;

struct User { name: u8[..16], friends: i64[..4], score: i64 }
var users: User[>..] = [];

struct Change { user: i64, score: i64 }
var changes: Change[>..] = [];
fn apply(c: Change) { users[c.user].score = c.score; }

enum Obj { Query, Mutation, User { i: i64 } }

fn resolve(o: Obj.Query, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("users") || f.is("strictUsers") { r.list() { for i in users.len { r.object(Obj.User { i: i }); } }; }
    else if f.is("total") { var t = 0; for u in users { t += u.score; } r.int(t); }
}

fn resolve(o: Obj.Mutation, f: graphql::Field&, r: graphql::Result<Obj>&) {
    if f.is("setScore") {
        let c = Change { user: f.int("user"), score: f.int("score") };
        apply(c);
        changes.push(c);
        r.int(c.score);
    }
}

fn resolve(o: Obj.User, f: graphql::Field&, r: graphql::Result<Obj>&) {
    let u = users[o.i];
    if f.is("name") { r.string(u.name); }
    else if f.is("score") { r.int(u.score); }
    else if f.is("friends") { r.list() { for k in u.friends { r.object(Obj.User { i: k }); } }; }
    else if f.is("mustHave") { if o.i == 150 { r.none(); } else { r.int(o.i); } }
    else if f.is("oops") { if o.i % 50 == 7 { r.error(str("no oops for ", o.i)); } else { r.int(1); } }
}

thread_fn worker(n: i64) {
    graphql::serve<Change>(n, Obj.Query, apply) { o, f, r => resolve(o, f, r) };
}

fn local(q: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    graphql::execute(q, Obj.Query, out) { o, f, r => resolve(o, f, r) };
    return out;
}

fn main() {
    let e = graphql::load_schema("""
        type Query { users: [User!]!, strictUsers: [User!], total: Int! }
        type Mutation { setScore(user: Int!, score: Int!): Int! }
        type User { name: String!, score: Int!, friends: [User!]!, mustHave: Int!, oops: Int }
        """);
    assert(e.len == 0);
    for i in 400 {
        users.push(User { name: "", friends: [(i + 1) % 400, (i * 7) % 400], score: i % 10 });
        format(users[i].name, "user", i);
    }
    // Small enough that every big request here is worth splitting.
    graphql::fork_min_fields = 64;
    graphql::fork_min_items = 8;

    let n = 4;
    var p = graphql::pool(n);
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker, n)); }

    let big = "{ users { name score friends { name } } }";
    let expect_big = local(big);
    let expect_total = local("{ total }");

    // One at a time, each big request can take the split token.
    var same = 0;
    for k in 3 {
        graphql::submit(p, big);
        if graphql::receive(p).body == expect_big { same++; }
    }
    print("split one at a time: ", same, "/3 match");

    // Many in flight at once: some split, some run whole.
    for k in 30 { graphql::submit(p, "{ total }"); }
    for k in 6 { graphql::submit(p, big); }
    var small_ok = 0;
    var big_ok = 0;
    for k in 36 {
        let reply = graphql::receive(p);
        if reply.body == expect_total { small_ok++; }
        if reply.body == expect_big { big_ok++; }
    }
    print("in flight together: ", small_ok, "/30 small and ", big_ok, "/6 big match");

    // Field errors inside parts keep their paths.
    let oops = "{ users { oops } }";
    graphql::submit(p, oops);
    let oops_reply = graphql::receive(p);
    print("errors from parts match: ", oops_reply.body == local(oops));

    // A non-null field failing inside a split list nulls the list.
    let strict = "{ strictUsers { name mustHave friends { name } } }";
    graphql::submit(p, strict);
    let strict_reply = graphql::receive(p);
    let ls = local(strict);
    print("null propagation matches: ", strict_reply.body == ls);
    print(ls[..30], "...", ls[ls.len - 110..]);

    // A mutation runs here; sync hands its changes to every worker.
    let m = "mutation { setScore(user: 3, score: 1000) }";
    print("is_mutation: ", graphql::is_mutation(m), " ", graphql::is_mutation("{ total }"),
          " ", graphql::is_mutation("mutation { nope }"));
    var out: u8[>..] = [];
    graphql::execute(m, Obj.Mutation, out) { o, f, r => resolve(o, f, r) };
    print(out);
    graphql::sync(p, changes);
    changes.clear();
    let after = local("{ total }");
    var agree = 0;
    for k in 20 { graphql::submit(p, "{ total }"); }
    for k in 20 { if graphql::receive(p).body == after { agree++; } }
    print("after sync: ", after, " from ", agree, "/20 replies");

    // Syncs back to back: each worker applies each round's changes once.
    for k in 30 {
        let c = Change { user: k, score: 100 + k };
        apply(c);
        changes.push(c);
        graphql::sync(p, changes);
        changes.clear();
    }
    let final = local("{ total }");
    agree = 0;
    for k in 40 { graphql::submit(p, "{ total }"); }
    for k in 40 { if graphql::receive(p).body == final { agree++; } }
    print("after 30 more syncs: ", final, " from ", agree, "/40 replies");

    graphql::stop(p);
    for id in ids { thread_wait(id); }
    print("stopped");
}
