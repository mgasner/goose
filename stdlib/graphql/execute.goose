// Execution, in two phases.
//
// Phase 1 resolves. It runs the request breadth-first, one level of objects
// at a time: it calls the program's batch hook once per object type at the
// level, then every resolver at the level. A resolver answers a field by
// appending result entries, and every object it gives becomes a node of the
// next level. Nothing recurses, so a resolver is plain code, and a backend
// sees one batch per type per level rather than one call per object.
//
// Phase 2 writes. It walks the nodes depth-first, checks every entry
// against its field's type and writes the response JSON. A non-null
// position that ends up null is `return false from guarded`: it lands at
// the innermost `guarded`, the nearest nullable position, and the
// `nullable` around it truncates the response back to where it was, then
// writes null.

namespace graphql;

import std;

// A handle: one of the program's, or one the introspection resolver made.
enum Handle<O> { App { o: O }, Meta { what: i64, i: i64 } }

let M_SCHEMA = 0;
let M_TYPE = 1;        // a named type: a row of `types`
let M_TREF = 2;        // a list or non-null wrapper: a row of `trefs`
let M_FIELD = 3;
let M_INPUT = 4;
let M_ENUM = 5;
let M_DIRECTIVE = 6;

// What a resolver hands to the program: the field and where its value goes.
struct Field { sel: i64, def: i64, parent: i64 }
struct Result<O> { handles: Handle<O>[>..<]& }

// An argument's value, or a part of one: a row of `values` (-1 for none)
// and the type it has.
struct Input { v: i64, t: i64 }

// --- result entries ----------------------------------------------------------

let E_NULL = 0;
let E_INT = 1;
let E_FLOAT = 2;
let E_STRING = 3;
let E_BOOL = 4;
let E_ENUM = 5;
let E_OBJECT = 6;     // i: a row of the handles; node: the object's node
let E_LIST = 7;       // i: the entry after the list's last item
let E_ERROR = 8;
let E_JSON = 9;       // a custom scalar's JSON, as given

struct Entry { kind: i64, i: i64 = 0, f: f64 = 0.0, at: i64 = 0, n: i64 = 0, node: i64 = -1 }

var entries: Entry[>..<] = [];
var etext: u8[>..<] = [];

fn put_text(kind: i64, s: const u8[:]) {
    let at = etext.len;
    etext.append(s);
    entries.push(Entry { kind: kind, at: at, n: s.len, .. });
}

fn entry_text(e: Entry) -> const u8[:] { etext[e.at..e.at + e.n] }

fn span_end(j: i64) -> i64 { if entries[j].kind == E_LIST { entries[j].i } else { j + 1 } }

// --- the request's execution tables -------------------------------------------------

// A step of the response path: a response key, or a list index.
struct Seg { key: Name, index: i64 = -1 }

// The fields of a plan, merged by response key, and the selections each one
// merges.
struct Group { key: Name, sel: i64, head: i64, tail: i64 }
struct Link { sel: i64, next: i64 = -1 }
var groups: Group[>..] = [];
var links: Link[>..] = [];
var group_base: i64 = 0;

// Selection sets: a plan's are heads[hfirst..hfirst + hcount], merged.
var heads: i64[>..] = [];

// What an object of type `ty` runs: its fields, collected once from its
// merged selection sets, for every object that gets the same sets. A child
// plan is found again by the plan, field and type it came from.
struct Plan {
    ty: i64, gfirst: i64 = 0, gcount: i64 = 0, hfirst: i64 = 0, hcount: i64 = 0,
    parent: i64 = -1, pgroup: i64 = -1, cost: i64 = 0,
}
var plans: Plan[>..] = [];

// An object being run: its handle (a row of the handles), its plan, and
// where its fields' results start in `fres`. `part` is the part of a split
// level it was sent away in, or -1; `remote`, once that part's results are
// back, is the row of `remotes` holding its JSON.
struct Node { handle: i64, plan: i64, ffirst: i64 = -1, part: i64 = -1, remote: i64 = -1 }
var nodes: Node[>..] = [];

// A field's result: the entry its value starts at and the field's
// definition on the node's type (-1, -1 for __typename).
struct FRes { entry: i64, def: i64 }
var fres: FRes[>..] = [];

// The nodes of the level being resolved.
var frontier: i64[>..<] = [];

var resp: u8[>..<] = [];
var path: Seg[>..<] = [];

var request_text: u8[>..] = [];     // the request, for parts sent to workers

// Counts requests; a program's per-request caches can compare it.
var request_serial: i64 = 0;

fn clear_execution() {
    resp.clear();
    entries.clear();
    etext.clear();
    path.clear();
    groups.clear();
    links.clear();
    heads.clear();
    plans.clear();
    nodes.clear();
    fres.clear();
    frontier.clear();
    last_parent = -1;
    last_plan = -1;
}

// --- errors --------------------------------------------------------------------------

// Set where a worker writes a part of another's request: paths start with
// a mark the other worker replaces with the path to the part.
var relative_paths = false;
let PATH_MARK: u8 = 1;

fn field_error(msg: const u8[:], sel: i64) {
    open_error(msg, if sel >= 0 { sels[sel].at } else { -1 });
    errs.append(",\"path\":[");
    if relative_paths { errs.push(PATH_MARK); }
    for p, k in path {
        if k > 0 || relative_paths { errs.push(','); }
        if p.index >= 0 { format(errs, p.index); } else { json_quote(errs, str_of(p.key)); }
    }
    errs.append("]}");
}

fn field_label(def: i64) -> u8[>..] { str(str_of(types[fields[def].owner].name), ".", str_of(fields[def].name)) }

// A value that cannot stand: an error, then null here or, at a non-null
// position, null for the nearest nullable one.
fn give_up(msg: const u8[:], sel: i64, nonnull: bool) {
    field_error(msg, sel);
    if nonnull { return false from guarded; }
    resp.append("null");
}

// --- arguments and directives ---------------------------------------------------------

// A value with variables replaced by theirs; -1 for a variable with none.
fn deref(v: i64) -> i64 {
    guard v >= 0 && values[v].kind == V_VAR else { return v; }
    let d = var_of(cur_op, str_of(values[v].s));
    return if d >= 0 { vardefs[d].value } else { -1 };
}

fn arg_input(afirst: i64, acount: i64, dfirst: i64, dcount: i64, n: const u8[:], what: const u8[:]) -> Input {
    let d = input_of(dfirst, dcount, n);
    guard d >= 0 else { abort(str("graphql: ", what, " has no argument \"", n, "\"")); }
    for a in args[afirst..afirst + acount] {
        guard str_of(a.name) == n else { continue; }
        let v = deref(a.value);
        if v >= 0 { return Input { v: v, t: inputs[d].tref }; }
    }
    return Input { v: inputs[d].default, t: inputs[d].tref };
}

fn field_arg(f: Field, n: const u8[:]) -> Input {
    let s = sels[f.sel];
    let fd = fields[f.def];
    return arg_input(s.afirst, s.acount, fd.afirst, fd.acount, n, field_label(f.def));
}

fn present(a: Input) -> bool { a.v >= 0 && values[a.v].kind != V_NULL }

fn need(a: Input, what: const u8[:]) -> Value {
    guard present(a) else { abort(str("graphql: ", what, " is null; check it with has() or present() first")); }
    return values[a.v];
}

fn input_member(a: Input, n: const u8[:]) -> Input {
    var t = a.t;
    if trefs[t].kind == NON_NULL { t = trefs[t].of; }
    let td = types[trefs[t].of];
    guard trefs[t].kind == NAMED && td.kind == INPUT else { abort(str("graphql: member \"", n, "\" of a value that is not an input object")); }
    let d = input_of(td.first, td.count, n);
    guard d >= 0 else { abort(str("graphql: input type ", str_of(td.name), " has no field \"", n, "\"")); }
    if present(a) {
        var c = values[a.v].first;
        while c >= 0 {
            if str_of(values[c].key) == n {
                let v = deref(c);
                if v >= 0 { return Input { v: v, t: inputs[d].tref }; }
            }
            c = values[c].next;
        }
    }
    return Input { v: inputs[d].default, t: inputs[d].tref };
}

// The items of a list value; a single value counts as a list of itself.
fn each_input<F>(a: Input) {
    guard present(a) else { return; }
    var t = a.t;
    if trefs[t].kind == NON_NULL { t = trefs[t].of; }
    let item = if trefs[t].kind == LIST { trefs[t].of } else { t };
    if values[a.v].kind != V_LIST { F(Input { v: a.v, t: item }); return; }
    var c = values[a.v].first;
    while c >= 0 {
        F(Input { v: deref(c), t: item });
        c = values[c].next;
    }
}

// Whether @skip and @include let a selection through.
fn included(first: i64, count: i64) -> bool {
    for d in dirs[first..first + count] {
        let n = str_of(d.name);
        guard n == "skip" || n == "include" else { continue; }
        let def = directives[directive_named(n)];
        let a = arg_input(d.afirst, d.acount, def.afirst, def.acount, "if", "@skip");
        let on = present(a) && values[a.v].i != 0;
        if n == "skip" && on { return false; }
        if n == "include" && !on { return false; }
    }
    return true;
}

// --- collecting fields --------------------------------------------------------------------

fn add_to_group(s: i64) {
    let key = sels[s].alias;
    for g in group_base..groups.len {
        guard same(groups[g].key, key) else { continue; }
        links.push(Link { sel: s });
        links[groups[g].tail].next = links.len - 1;
        groups[g].tail = links.len - 1;
        return;
    }
    links.push(Link { sel: s });
    groups.push(Group { key: key, sel: s, head: links.len - 1, tail: links.len - 1 });
}

recursive fn collect(ty: i64, set: i64) {
    var s = set;
    while s >= 0 {
        let sel = sels[s];
        if included(sel.dfirst, sel.dcount) {
            if sel.kind == S_FIELD { add_to_group(s); }
            else {
                let cond = if sel.kind == S_INLINE && !sel.has_cond { ty } else { sel.ctype };
                if is_possible(cond, ty) {
                    collect(ty, if sel.kind == S_SPREAD { frags[sel.frag].set } else { sel.set });
                }
            }
        }
        s = sels[s].next;
    }
}

// The fields at and below the merged sets heads[hf..hf + hc], per object.
fn heads_cost(hf: i64, hc: i64) -> i64 {
    var c = 0;
    for h in heads[hf..hf + hc] {
        var s = h;
        while s >= 0 { c += sels[s].cost; s = sels[s].next; }
    }
    return c;
}

// --- plans -----------------------------------------------------------------------------

fn make_plan(ty: i64, hf: i64, hc: i64, parent: i64, pgroup: i64) -> i64 {
    let gb = groups.len;
    group_base = gb;
    for k in hf..hf + hc { collect(ty, heads[k]); }
    plans.push(Plan { ty: ty, gfirst: gb, gcount: groups.len - gb, hfirst: hf, hcount: hc,
                      parent: parent, pgroup: pgroup, cost: heads_cost(hf, hc) });
    return plans.len - 1;
}

// The last child plan found, since an object's siblings usually share it.
var last_parent: i64 = -1;
var last_group: i64 = -1;
var last_ty: i64 = -1;
var last_plan: i64 = -1;

// The plan of an object of type ty given by field group g of plan p.
fn child_plan(p: i64, g: i64, ty: i64) -> i64 {
    if p == last_parent && g == last_group && ty == last_ty { return last_plan; }
    var found = -1;
    for q, qi in plans {
        if q.parent == p && q.pgroup == g && q.ty == ty { found = qi; break; }
    }
    if found < 0 {
        let hf = heads.len;
        var l = groups[g].head;
        while l >= 0 {
            let sub = sels[links[l].sel].set;
            if sub >= 0 { heads.push(sub); }
            l = links[l].next;
        }
        found = make_plan(ty, hf, heads.len - hf, p, g);
    }
    last_parent = p;
    last_group = g;
    last_ty = ty;
    last_plan = found;
    return found;
}

// --- phase 1: resolving ------------------------------------------------------------------

// What the batch hook learns about the objects it is given: which fields
// will be asked of them. The plans are those of the objects in the batch.
struct Selection { ty: i64 }
var sel_plans: i64[>..<] = [];
var level_types: i64[>..<] = [];

fn selection_has(n: const u8[:]) -> bool {
    for p in sel_plans {
        let pl = plans[p];
        for g in groups[pl.gfirst..pl.gfirst + pl.gcount] {
            if str_of(sels[g.sel].name) == n { return true; }
        }
    }
    return false;
}

// Calls the batch hook once per object type of the program's among the
// level's nodes, with their handles in level order.
fn batch_level<O, B>(r: Result<O>&) {
    level_types.clear();
    for n in frontier {
        guard nodes[n].part < 0 else { continue; }
        match r.handles[nodes[n].handle] {
            App a => {
                let t = plans[nodes[n].plan].ty;
                if !contains(level_types, t) { level_types.push(t); }
            },
            Meta m => {},
        }
    }
    for t in level_types {
        sel_plans.clear();
        var objs: O[>..] = [];
        for n in frontier {
            let nd = nodes[n];
            guard nd.part < 0 && plans[nd.plan].ty == t else { continue; }
            match r.handles[nd.handle] {
                App a => {
                    objs.push(a.o);
                    if !contains(sel_plans, nd.plan) { sel_plans.push(nd.plan); }
                },
                Meta m => {},
            }
        }
        var sel = Selection { ty: t };
        B(objs[..], sel);
    }
}

fn no_batch<O>(objs: O[:], sel: Selection&) {}

// Resolves field group g of node n: calls the resolver, checks it gave one
// value, and makes a node of every object in that value.
fn resolve_field<O, T, F>(r: Result<O>&, n: i64, g: i64) {
    let nd = nodes[n];
    let ty = plans[nd.plan].ty;
    let s = groups[g].sel;
    let name = str_of(sels[s].name);
    if name == "__typename" { fres.push(FRes { entry: -1, def: -1 }); return; }
    var def = sels[s].def;
    if fields[def].owner != ty && fields[def].owner != t_meta { def = field_of(ty, name); }
    let em = entries.len;
    let f = Field { sel: s, def: def, parent: ty };
    if fields[def].owner == t_meta { resolve_root_meta(r, f); }
    else {
        match r.handles[nd.handle] {
            App a => F(a.o, f, r),
            Meta m => resolve_meta(r, m.what, m.i, f),
        }
    }
    if entries.len == em {
        put_text(E_ERROR, str("No value was given for ", field_label(def), "."));
    } else if span_end(em) != entries.len {
        entries.resize(em);
        put_text(E_ERROR, str("More than one value was given for ", field_label(def), "."));
    }
    fres.push(FRes { entry: em, def: def });
    let nt = named_of(fields[def].tref);
    guard is_composite(nt) else { return; }
    let td = types[nt];
    for j in em..entries.len {
        guard entries[j].kind == E_OBJECT else { continue; }
        var ct = nt;
        if td.kind != OBJECT {
            match r.handles[entries[j].i] {
                App a => {
                    let tn = T(a.o);
                    ct = type_named(tn);
                    if !(ct >= 0 && types[ct].kind == OBJECT && is_possible(nt, ct)) {
                        let msg = str("Abstract type \"", str_of(td.name), "\" must resolve to an object type that is possible for it at runtime for field ",
                                      field_label(def), ", but type_of gave \"", tn, "\".");
                        let at = etext.len;
                        etext.append(msg);
                        entries[j] = Entry { kind: E_ERROR, at: at, n: msg.len, .. };
                        continue;
                    }
                },
                Meta m => {},
            }
        }
        nodes.push(Node { handle: entries[j].i, plan: child_plan(nd.plan, g, ct), .. });
        entries[j].node = nodes.len - 1;
    }
}

fn resolve_node<O, T, F>(r: Result<O>&, n: i64) {
    nodes[n].ffirst = fres.len;
    let p = plans[nodes[n].plan];
    for g in p.gfirst..p.gfirst + p.gcount { resolve_field(r, n, g, T, F); }
}

// Resolves the frontier and every level below it.
fn resolve_levels<O, T, B, F>(r: Result<O>&, batching: bool) {
    while frontier.len > 0 {
        let lo = nodes.len;
        if forking { split_level(r, T, B, F); }
        if batching { batch_level(r, B); }
        for k in frontier.len {
            let n = frontier[k];
            if nodes[n].part < 0 { resolve_node(r, n, T, F); }
        }
        frontier.clear();
        for n in lo..nodes.len { frontier.push(n); }
    }
}

// Phase 1 for the operation: the root node, then every level. A mutation's
// top-level fields run one at a time, each with everything below it, as
// the spec requires.
fn resolve_operation<O, T, B, F>(r: Result<O>&, root: O, batching: bool) {
    let op = ops[cur_op];
    let root_t = if op.kind == OP_MUTATION { mutation_type } else { query_type };
    heads.push(op.set);
    let p = make_plan(root_t, 0, 1, -1, -1);
    r.handles.push(Handle<O>.App { o: root });
    nodes.push(Node { handle: 0, plan: p, .. });
    if op.kind != OP_MUTATION {
        frontier.push(0);
        resolve_levels(r, batching, T, B, F);
        return;
    }
    nodes[0].ffirst = fres.len;
    let pl = plans[p];
    for g in pl.gfirst..pl.gfirst + pl.gcount {
        let lo = nodes.len;
        resolve_field(r, 0, g, T, F);
        frontier.clear();
        for n in lo..nodes.len { frontier.push(n); }
        resolve_levels(r, batching, T, B, F);
    }
}

// --- phase 2: writing ------------------------------------------------------------------------

recursive fn write_node(n: i64) {
    let nd = nodes[n];
    if nd.remote >= 0 { write_remote(n); return; }
    let p = plans[nd.plan];
    resp.push('{');
    for k in p.gcount {
        if k > 0 { resp.push(','); }
        let g = p.gfirst + k;
        json_quote(resp, str_of(groups[g].key));
        resp.push(':');
        let fr = fres[nd.ffirst + k];
        if fr.def < 0 { json_quote(resp, str_of(types[p.ty].name)); continue; }
        path.push(Seg { key: groups[g].key, .. });
        complete(fields[fr.def].tref, fr.entry, groups[g].sel, fr.def);
        path.pop();
    }
    resp.push('}');
}

// Writes entry i as a value of type reference t.
recursive fn complete(t: i64, i: i64, sel: i64, def: i64) {
    if trefs[t].kind == NON_NULL { complete_value(trefs[t].of, i, sel, def, true); }
    else { nullable(t, i, sel, def); }
}

recursive fn nullable(t: i64, i: i64, sel: i64, def: i64) {
    let rm = resp.len;
    let pm = path.len;
    if !guarded(G_VALUE, t, i, sel, def) {
        resp.resize(rm);
        path.resize(pm);
        resp.append("null");
    }
}

// The one target of `return false from guarded`, so that it always lands
// at the innermost of these: a nullable value (G_VALUE: entry i of type t)
// or an object written whole (G_NODE: node i).
let G_VALUE = 0;
let G_NODE = 1;

recursive fn guarded(mode: i64, t: i64, i: i64, sel: i64, def: i64) -> bool {
    if mode == G_VALUE { complete_value(t, i, sel, def, false); } else { write_node(i); }
    return true;
}

// `t` has no non-null wrapper of its own; `nonnull` says whether the
// position had one.
recursive fn complete_value(t: i64, i: i64, sel: i64, def: i64, nonnull: bool) {
    let e = entries[i];
    if e.kind == E_NULL {
        if nonnull {
            give_up(str("Cannot return null for non-nullable field ", field_label(def), "."), sel, true);
        }
        resp.append("null");
        return;
    }
    if e.kind == E_ERROR { give_up(entry_text(e), sel, nonnull); return; }
    if trefs[t].kind == LIST {
        guard e.kind == E_LIST else {
            give_up(str("Expected a list for field ", field_label(def), "."), sel, nonnull);
            return;
        }
        let item = trefs[t].of;
        resp.push('[');
        var j = i + 1;
        var k = 0;
        while j < e.i {
            if k > 0 { resp.push(','); }
            path.push(Seg { key: Name { .. }, index: k });
            complete(item, j, sel, def);
            path.pop();
            j = span_end(j);
            k++;
        }
        resp.push(']');
        return;
    }
    let nt = trefs[t].of;
    let td = types[nt];
    if td.kind == SCALAR || td.kind == ENUM {
        guard write_leaf(e, nt) else {
            give_up(str(reason, " (field ", field_label(def), ")"), sel, nonnull);
            return;
        }
        return;
    }
    guard e.kind == E_OBJECT && e.node >= 0 else {
        give_up(str("Expected an object of type ", str_of(td.name), " for field ", field_label(def), "."), sel, nonnull);
        return;
    }
    write_node(e.node);
}

// Writes a scalar or enum entry; false, with `reason`, if it cannot be one.
fn write_leaf(e: Entry, nt: i64) -> bool {
    let td = types[nt];
    let tn = str_of(td.name);
    reason.clear();
    if td.kind == ENUM {
        guard (e.kind == E_ENUM || e.kind == E_STRING) && enum_has(nt, entry_text(e)) else {
            format(reason, "Enum \"", tn, "\" cannot represent value");
            if e.kind == E_ENUM || e.kind == E_STRING { format(reason, ": \"", entry_text(e), "\""); }
            return false;
        }
        json_quote(resp, entry_text(e));
        return true;
    }
    if tn == "Int" {
        if e.kind == E_FLOAT && e.f == (e.f as! i64) && int32(e.f as! i64) { format(resp, e.f as! i64); return true; }
        guard e.kind == E_INT && int32(e.i) else {
            format(reason, "Int cannot represent ", if e.kind == E_INT { "non 32-bit signed integer value: " } else { "non-integer value" });
            if e.kind == E_INT { format(reason, e.i); }
            return false;
        }
        format(resp, e.i);
        return true;
    }
    if tn == "Float" {
        if e.kind == E_INT { format(resp, e.i); return true; }
        guard e.kind == E_FLOAT && e.f == e.f && e.f - e.f == 0.0 else {
            reason.append("Float cannot represent non numeric value");
            return false;
        }
        json::write_float(resp, e.f);
        return true;
    }
    if tn == "Boolean" {
        guard e.kind == E_BOOL else { reason.append("Boolean cannot represent a non boolean value"); return false; }
        resp.append(if e.i != 0 { "true" } else { "false" });
        return true;
    }
    if tn == "String" || tn == "ID" {
        if e.kind == E_STRING || e.kind == E_ENUM { json_quote(resp, entry_text(e)); return true; }
        if e.kind == E_INT { resp.push('"'); format(resp, e.i); resp.push('"'); return true; }
        if tn == "String" && e.kind == E_FLOAT { resp.push('"'); json::write_float(resp, e.f); resp.push('"'); return true; }
        if tn == "String" && e.kind == E_BOOL { resp.append(if e.i != 0 { "\"true\"" } else { "\"false\"" }); return true; }
        format(reason, tn, " cannot represent value");
        return false;
    }
    // A custom scalar: what the resolver gave, as JSON.
    if e.kind == E_STRING || e.kind == E_ENUM { json_quote(resp, entry_text(e)); return true; }
    if e.kind == E_INT { format(resp, e.i); return true; }
    if e.kind == E_FLOAT { json::write_float(resp, e.f); return true; }
    if e.kind == E_BOOL { resp.append(if e.i != 0 { "true" } else { "false" }); return true; }
    if e.kind == E_JSON { resp.append(entry_text(e)); return true; }
    format(reason, tn, " cannot represent an object or list value");
    return false;
}

// --- introspection -----------------------------------------------------------------------------

fn meta<O>(r: Result<O>&, what: i64, i: i64) {
    r.handles.push(Handle<O>.Meta { what: what, i: i });
    entries.push(Entry { kind: E_OBJECT, i: r.handles.len - 1, .. });
}

fn meta_tref<O>(r: Result<O>&, t: i64) {
    if trefs[t].kind == NAMED { meta(r, M_TYPE, trefs[t].of); } else { meta(r, M_TREF, t); }
}

fn text_or_null(n: Name) {
    if n.len > 0 { put_text(E_STRING, str_of(n)); } else { entries.push(Entry { kind: E_NULL, .. }); }
}

fn put_null() { entries.push(Entry { kind: E_NULL, .. }); }
fn put_bool(b: bool) { entries.push(Entry { kind: E_BOOL, i: if b { 1 } else { 0 }, .. }); }

fn begin_list() -> i64 { entries.push(Entry { kind: E_LIST, .. }); return entries.len - 1; }
fn end_list(i: i64) { entries[i].i = entries.len; }

fn wants_deprecated(f: Field) -> bool {
    let a = field_arg(f, "includeDeprecated");
    return present(a) && values[a.v].i != 0;
}

fn resolve_root_meta<O>(r: Result<O>&, f: Field) {
    if str_of(fields[f.def].name) == "__schema" { meta(r, M_SCHEMA, 0); return; }
    let a = field_arg(f, "name");
    let t = type_named(str_of(values[a.v].s));
    if t >= 0 && t != t_meta { meta(r, M_TYPE, t); } else { put_null(); }
}

fn kind_name(k: i64) -> const u8[:] {
    match k {
        SCALAR => "SCALAR", OBJECT => "OBJECT", INTERFACE => "INTERFACE", UNION => "UNION",
        ENUM => "ENUM", _ => "INPUT_OBJECT",
    }
}

fn resolve_meta<O>(r: Result<O>&, what: i64, i: i64, f: Field) {
    let n = str_of(fields[f.def].name);
    if what == M_SCHEMA {
        if n == "types" {
            let l = begin_list();
            for t, ti in types { if ti != t_meta { meta(r, M_TYPE, ti); } }
            end_list(l);
        }
        else if n == "queryType" { meta(r, M_TYPE, query_type); }
        else if n == "mutationType" { if mutation_type >= 0 { meta(r, M_TYPE, mutation_type); } else { put_null(); } }
        else if n == "directives" {
            let l = begin_list();
            for d, di in directives { meta(r, M_DIRECTIVE, di); }
            end_list(l);
        }
        else { put_null(); }
        return;
    }
    if what == M_TREF {
        let tr = trefs[i];
        if n == "kind" { put_text(E_ENUM, if tr.kind == LIST { "LIST" } else { "NON_NULL" }); }
        else if n == "ofType" { meta_tref(r, tr.of); }
        else { put_null(); }
        return;
    }
    if what == M_TYPE {
        let td = types[i];
        if n == "kind" { put_text(E_ENUM, kind_name(td.kind)); }
        else if n == "name" { put_text(E_STRING, str_of(td.name)); }
        else if n == "description" { text_or_null(td.desc); }
        else if n == "fields" {
            guard td.kind == OBJECT || td.kind == INTERFACE else { put_null(); return; }
            let all = wants_deprecated(f);
            let l = begin_list();
            for k in td.first..td.first + td.count { if all || !fields[k].deprecated { meta(r, M_FIELD, k); } }
            end_list(l);
        }
        else if n == "interfaces" {
            guard td.kind == OBJECT || td.kind == INTERFACE else { put_null(); return; }
            let l = begin_list();
            for m in members[td.ifirst..td.ifirst + td.icount] { meta(r, M_TYPE, m.of); }
            end_list(l);
        }
        else if n == "possibleTypes" {
            guard td.kind == INTERFACE || td.kind == UNION else { put_null(); return; }
            let l = begin_list();
            for o, oi in types { if o.kind == OBJECT && is_possible(i, oi) { meta(r, M_TYPE, oi); } }
            end_list(l);
        }
        else if n == "enumValues" {
            guard td.kind == ENUM else { put_null(); return; }
            let all = wants_deprecated(f);
            let l = begin_list();
            for k in td.first..td.first + td.count { if all || !enums[k].deprecated { meta(r, M_ENUM, k); } }
            end_list(l);
        }
        else if n == "inputFields" {
            guard td.kind == INPUT else { put_null(); return; }
            let all = wants_deprecated(f);
            let l = begin_list();
            for k in td.first..td.first + td.count { if all || !inputs[k].deprecated { meta(r, M_INPUT, k); } }
            end_list(l);
        }
        else if n == "isOneOf" { if td.kind == INPUT { put_bool(false); } else { put_null(); } }
        else { put_null(); }
        return;
    }
    if what == M_FIELD {
        let fd = fields[i];
        if n == "name" { put_text(E_STRING, str_of(fd.name)); }
        else if n == "description" { text_or_null(fd.desc); }
        else if n == "args" {
            let all = wants_deprecated(f);
            let l = begin_list();
            for k in fd.afirst..fd.afirst + fd.acount { if all || !inputs[k].deprecated { meta(r, M_INPUT, k); } }
            end_list(l);
        }
        else if n == "type" { meta_tref(r, fd.tref); }
        else if n == "isDeprecated" { put_bool(fd.deprecated); }
        else if n == "deprecationReason" { if fd.deprecated { text_or_null(fd.reason); } else { put_null(); } }
        else { put_null(); }
        return;
    }
    if what == M_INPUT {
        let d = inputs[i];
        if n == "name" { put_text(E_STRING, str_of(d.name)); }
        else if n == "description" { text_or_null(d.desc); }
        else if n == "type" { meta_tref(r, d.tref); }
        else if n == "defaultValue" { if d.default >= 0 { put_text(E_STRING, value_string(d.default, false)); } else { put_null(); } }
        else if n == "isDeprecated" { put_bool(d.deprecated); }
        else if n == "deprecationReason" { if d.deprecated { text_or_null(d.reason); } else { put_null(); } }
        else { put_null(); }
        return;
    }
    if what == M_ENUM {
        let d = enums[i];
        if n == "name" { put_text(E_STRING, str_of(d.name)); }
        else if n == "description" { text_or_null(d.desc); }
        else if n == "isDeprecated" { put_bool(d.deprecated); }
        else if n == "deprecationReason" { if d.deprecated { text_or_null(d.reason); } else { put_null(); } }
        else { put_null(); }
        return;
    }
    let d = directives[i];
    if n == "name" { put_text(E_STRING, str_of(d.name)); }
    else if n == "description" { text_or_null(d.desc); }
    else if n == "locations" {
        let l = begin_list();
        for loc in locations[d.lfirst..d.lfirst + d.lcount] { put_text(E_ENUM, str_of(loc)); }
        end_list(l);
    }
    else if n == "args" {
        let l = begin_list();
        for k in d.afirst..d.afirst + d.acount { meta(r, M_INPUT, k); }
        end_list(l);
    }
    else if n == "isRepeatable" { put_bool(d.repeatable); }
    else { put_null(); }
}

// --- the entry points ---------------------------------------------------------------------------

fn run<O, T, B, F>(request: const u8[:], root: O, out: u8[>..]&, batching: bool) {
    clear_execution();
    request_serial++;
    request_text.clear();
    request_text.append(request);
    if !prepare(request) {
        out.append("{\"errors\":[");
        out.append(errs);
        out.append("]}");
        reset_request();
        return;
    }
    var handles: Handle<O>[>..<] = [];
    var r = Result<O> { handles: handles };
    resolve_operation(r, root, batching, T, B, F);
    finish_split(r, batching, T, B, F);
    resp.append("{\"data\":");
    let rm = resp.len;
    if !guarded(G_NODE, 0, 0, -1, -1) {
        resp.resize(rm);
        path.clear();
        resp.append("null");
    }
    if nerrs > 0 {
        resp.append(",\"errors\":[");
        resp.append(errs);
        resp.push(']');
    }
    resp.push('}');
    out.append(resp);
    clear_execution();
    reset_request();
}

fn no_type_of<O>(o: O) -> const u8[:] { "" }

// Runs a request and appends its JSON response to `out`. The resolver,
// usually the trailing block, answers field f of the object with handle o:
//
//     graphql::execute(request, Obj.Query, out) { o, f, r => resolve(o, f, r) };
fn execute<O, F>(request: const u8[:], root: O, out: u8[>..]&) {
    run(request, root, out, false, no_type_of, no_batch, F);
}

// The same, with `type_of(o)` naming the object type of a handle, for
// fields of interface and union types.
fn execute<O, T, F>(request: const u8[:], root: O, out: u8[>..]&) {
    run(request, root, out, false, T, no_batch, F);
}

// The same, with a batch hook: `batch(objs, sel)` is called once per object
// type at each level of the request, before any of those objects' fields
// are resolved, with their handles and the fields that will be asked.
fn execute<O, T, B, F>(request: const u8[:], root: O, out: u8[>..]&) {
    run(request, root, out, true, T, B, F);
}
