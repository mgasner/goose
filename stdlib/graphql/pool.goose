// Parallel execution. Workers share nothing (spec §11.2): each one starts
// with a copy of the schema and of the program's data, taken when it is
// spawned, and answers whole requests. Changes are made on the main thread
// and broadcast to every worker between requests. A worker that reaches a
// level of objects worth splitting sends parts of it to the others.
//
// Every message is one of these flat types. qget waits on one type, so a
// worker's inbox is one type, `Msg`, whatever it asks the worker to do.

namespace graphql;

import std;

let K_QUERY = 0;      // run `body` as a request and reply
let K_SYNC = 1;       // park until a Go arrives, then apply its changes
let K_WAKE = 2;       // take a part of a split level, if one is left
let K_QUIT = 3;

struct Msg { kind: i64, id: i64, body: u8[] }

// A response, with the id `submit` gave its request.
struct Reply { id: i64, body: u8[] }

struct Ack { n: i64 }
struct Go<C> { changes: C[] }
struct Applied { n: i64 }

// Splitting a level takes the one token, so one level is split at a time
// and every part's result goes to the one worker waiting for it. `sync`
// holds the token while workers are parked, so no split is in flight then.
struct Token { n: i64 }

// A part of a split level: objects with these handles, each running plan
// pidx[k] -- a type and selection sets -- from the plans listed. The worker
// parses the request again; a parse is deterministic, so every row a part
// names means what it meant to the worker that sent it.
struct Chunk<O> {
    part: i64, request: u8[],
    ptypes: i64[], phf: i64[], phc: i64[], heads: i64[],
    pidx: i64[], items: Handle<O>[],
}

// What came of a part: per object its JSON, whether a non-null failure made
// the object itself null, and its errors, whose paths start with PATH_MARK
// where the path to the object goes.
struct ChunkDone {
    part: i64, lens: i64[], bubbled: bool[], elens: i64[], ecounts: i64[],
    body: u8[], errors: u8[],
}

var forking = false;          // set in workers of a pool with several
var pool_size: i64 = 1;

// --- the main thread's side --------------------------------------------------

struct Pool { workers: i64, next_id: i64 = 0 }

// A pool of `workers` workers, which the program spawns itself, each
// running `serve`. Call it after loading the schema and the data.
fn pool(workers: i64) -> Pool {
    qput(Token { n: 0 });
    return Pool { workers: workers };
}

// Hands a request to whichever worker is free; its Reply carries the id.
fn submit(p: Pool&, request: const u8[:]) -> i64 {
    let id = p.next_id;
    p.next_id++;
    qput(Msg { kind: K_QUERY, id: id, body: request });
    return id;
}

// The next response any worker has finished.
fn receive(p: Pool&) -> Reply { qget<Reply>() }

// Brings every worker's copy of the data up to date: waits for any split
// level to finish, parks each worker once it is between requests, hands
// each the same changes to apply, in order, and returns once all have. The
// requests submitted before it are answered from the data before them, and
// those after it from the data after them.
fn sync<C>(p: Pool&, changes: C[:]) {
    let tk = qget<Token>();
    for i in p.workers { qput(Msg { kind: K_SYNC, id: -1, body: "" }); }
    for i in p.workers { qget<Ack>(); }
    for i in p.workers { qput(Go<C> { changes: changes }); }
    // Every Go must be taken before the next sync's SYNCs go out: a worker
    // that applied its changes and took a later SYNC would otherwise take
    // a slower worker's Go from this round.
    for i in p.workers { qget<Applied>(); }
    qput(tk);
}

// Tells every worker to return from `serve`, once the requests before it
// are answered. The program then waits for its workers.
fn stop(p: Pool&) {
    for i in p.workers { qput(Msg { kind: K_QUIT, id: -1, body: "" }); }
}

// Whether a request is a valid mutation, which the main thread runs itself.
fn is_mutation(request: const u8[:]) -> bool {
    let ok = prepare(request);
    let m = ok && ops[cur_op].kind == OP_MUTATION;
    reset_request();
    return m;
}

// --- a worker's side --------------------------------------------------------------

// A worker's loop: answers requests from the pool's inbox on its own copy
// of the data, and applies the changes `sync` sends with `apply`. `C` is
// the program's change type:
//
//     graphql::serve<Change>(n, Obj.Query, apply, type_of, batch) { o, f, r => resolve(o, f, r) };
fn serve_loop<C, O, A, T, B, F>(workers: i64, root: O, batching: bool) {
    pool_size = workers;
    forking = workers > 1;
    loop {
        let m = qget<Msg>();
        if m.kind == K_QUIT { break; }
        if m.kind == K_SYNC {
            qput(Ack { n: 0 });
            let g = qget<Go<C>>();
            for c in g.changes { A(c); }
            qput(Applied { n: 0 });
            continue;
        }
        if m.kind == K_WAKE {
            let ch, got = qpoll<Chunk<O>>();
            if got { qput(run_chunk(ch, batching, T, B, F)); }
            continue;
        }
        var out: u8[>..] = [];
        run(m.body, root, out, batching, T, B, F);
        qput(Reply { id: m.id, body: out[..] });
    }
}

fn serve<C, O, A, F>(workers: i64, root: O) {
    serve_loop<C, O>(workers, root, false, A, no_type_of, no_batch, F);
}

fn serve<C, O, A, T, F>(workers: i64, root: O) {
    serve_loop<C, O>(workers, root, false, A, T, no_batch, F);
}

fn serve<C, O, A, T, B, F>(workers: i64, root: O) {
    serve_loop<C, O>(workers, root, true, A, T, B, F);
}

// Runs a part of a level another worker split: both phases for its
// objects, each written whole, with paths relative to it.
fn run_chunk<O, T, B, F>(ch: Chunk<O>&, batching: bool) -> ChunkDone {
    clear_execution();
    if !prepare(ch.request) { abort("graphql: a part of a split level did not parse again"); }
    in_part = true;
    var handles: Handle<O>[>..<] = [];
    var r = Result<O> { handles: handles };
    let pbase = plans.len;
    for p in ch.ptypes.len {
        let hf = heads.len;
        for h in ch.heads[ch.phf[p]..ch.phf[p] + ch.phc[p]] { heads.push(h); }
        make_plan(ch.ptypes[p], hf, ch.phc[p], -2 - p, -1);
    }
    for h, k in ch.items {
        handles.push(h);
        nodes.push(Node { handle: handles.len - 1, plan: pbase + ch.pidx[k], .. });
        frontier.push(nodes.len - 1);
    }
    let count = ch.items.len;
    resolve_levels(r, batching, T, B, F);
    relative_paths = true;
    var lens: i64[>..] = [];
    var bubbled: bool[>..] = [];
    var elens: i64[>..] = [];
    var ecounts: i64[>..] = [];
    var etexts: u8[>..] = [];
    for k in count {
        let rm = resp.len;
        let em = errs.len;
        let en = nerrs;
        let ok = guarded(G_NODE, 0, k, -1, -1);
        path.clear();
        if !ok { resp.resize(rm); }
        lens.push(resp.len - rm);
        bubbled.push(!ok);
        let skip = if en > 0 && nerrs > en { 1 } else { 0 };
        elens.push(errs.len - em - skip);
        ecounts.push(nerrs - en);
        etexts.append(errs[em + skip..]);
    }
    relative_paths = false;
    in_part = false;
    let done = ChunkDone { part: ch.part, lens: lens[..], bubbled: bubbled[..], elens: elens[..], ecounts: ecounts[..],
                           body: resp[..], errors: etexts[..] };
    clear_execution();
    reset_request();
    return done;
}

// --- splitting a level ----------------------------------------------------------------

var in_part = false;          // running a part: never split again
var splitting = false;        // this request holds the token
var split_parts: i64 = 0;

// What came back for the objects of the parts other workers ran.
struct Remote { at: i64 = 0, len: i64 = 0, eat: i64 = 0, elen: i64 = 0, ecount: i64 = 0, bubbled: bool = false }
var remotes: Remote[>..] = [];
var remote_text: u8[>..] = [];

// Splits the frontier into parts when it holds enough work: keeps the
// first part and sends the others to whichever workers are free.
fn split_level<O, T, B, F>(r: Result<O>&) {
    guard !splitting && !in_part else { return; }
    let count = frontier.len;
    guard count >= 2 * fork_min_items else { return; }
    var cost = 0;
    for n in frontier {
        match r.handles[nodes[n].handle] { App a => {}, Meta m => { return; } }
        cost += plans[nodes[n].plan].cost;
    }
    guard cost >= fork_min_fields else { return; }
    let tk, got = qpoll<Token>();
    guard got else { return; }
    splitting = true;
    remotes.clear();
    remote_text.clear();
    let nparts = min(pool_size, count / fork_min_items);
    let per = (count + nparts - 1) / nparts;
    split_parts = nparts;
    for p in 1..nparts {
        var cplans: i64[>..] = [];
        var ptypes: i64[>..] = [];
        var phf: i64[>..] = [];
        var phc: i64[>..] = [];
        var cheads: i64[>..] = [];
        var pidx: i64[>..] = [];
        var items: Handle<O>[>..] = [];
        for k in p * per..min(count, (p + 1) * per) {
            let n = frontier[k];
            nodes[n].part = p;
            let pl = nodes[n].plan;
            var at = position(cplans, pl);
            if at < 0 {
                at = cplans.len;
                cplans.push(pl);
                ptypes.push(plans[pl].ty);
                phf.push(cheads.len);
                phc.push(plans[pl].hcount);
                for h in heads[plans[pl].hfirst..plans[pl].hfirst + plans[pl].hcount] { cheads.push(h); }
            }
            pidx.push(at);
            items.push(r.handles[nodes[n].handle]);
        }
        qput(Chunk<O> { part: p, request: request_text[..], ptypes: ptypes[..], phf: phf[..], phc: phc[..],
                        heads: cheads[..], pidx: pidx[..], items: items[..] });
    }
    for p in 1..nparts { qput(Msg { kind: K_WAKE, id: -1, body: "" }); }
}

// After phase 1: runs here the parts no other worker took, collects the
// rest, and gives the token back.
fn finish_split<O, T, B, F>(r: Result<O>&, batching: bool) {
    guard splitting else { return; }
    var done = 0;
    loop {
        var got = false;
        var part = 0;
        {
            let ch, ok = qpoll<Chunk<O>>();
            got = ok;
            part = ch.part;
        }
        guard got else { break; }
        frontier.clear();
        for n, ni in nodes { if n.part == part { nodes[ni].part = -1; frontier.push(ni); } }
        resolve_levels(r, batching, T, B, F);
        done++;
    }
    while done < split_parts - 1 {
        let d = qget<ChunkDone>();
        var k = 0;
        var at = 0;
        var eat = 0;
        for n, ni in nodes {
            guard n.part == d.part else { continue; }
            remotes.push(Remote { at: remote_text.len, len: d.lens[k], eat: remote_text.len + d.lens[k],
                                  elen: d.elens[k], ecount: d.ecounts[k], bubbled: d.bubbled[k] });
            remote_text.append(d.body[at..at + d.lens[k]]);
            remote_text.append(d.errors[eat..eat + d.elens[k]]);
            at += d.lens[k];
            eat += d.elens[k];
            nodes[ni].remote = remotes.len - 1;
            k++;
        }
        done++;
    }
    splitting = false;
    qput(Token { n: 0 });
}

// Writes an object another worker ran: its errors, with the path to it put
// in, then its JSON, or a non-null failure if it had one.
fn write_remote(n: i64) {
    let rm = remotes[nodes[n].remote];
    if rm.ecount > 0 {
        if nerrs > 0 { errs.push(','); }
        for c in remote_text[rm.eat..rm.eat + rm.elen] {
            guard c == PATH_MARK else { errs.push(c); continue; }
            for p, k in path {
                if k > 0 { errs.push(','); }
                if p.index >= 0 { format(errs, p.index); } else { json_quote(errs, str_of(p.key)); }
            }
        }
        nerrs += rm.ecount;
    }
    if rm.bubbled { return false from guarded; }
    resp.append(remote_text[rm.at..rm.at + rm.len]);
}
