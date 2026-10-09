// A request's front end: the envelope, the document, the operation,
// validation against the schema and the coercion of variables. Nothing a
// resolver runs before all of it has succeeded.

namespace graphql;

import std;

var cur_op: i64 = -1;          // the operation being validated or run
var cur_at: i64 = -1;          // the position values being checked come from
var reason: u8[>..] = [];      // why the last coercion failed
var frag_chain: i64[>..<] = [];

// --- printing types and values -------------------------------------------------

recursive fn print_tref(out: u8[>..]&, t: i64) {
    let r = trefs[t];
    if r.kind == NAMED { out.append(str_of(types[r.of].name)); return; }
    if r.kind == LIST { out.push('['); print_tref(out, r.of); out.push(']'); return; }
    print_tref(out, r.of);
    out.push('!');
}

fn type_string(t: i64) -> u8[>..] {
    var s: u8[>..] = [];
    print_tref(s, t);
    return s;
}

// A value as GraphQL literal syntax, or as JSON.
recursive fn print_value(out: u8[>..]&, v: i64, json: bool) {
    let x = values[v];
    match x.kind {
        V_NULL => out.append("null"),
        V_INT => format(out, x.i),
        V_FLOAT => format(out, x.f),
        V_STRING => json_quote(out, str_of(x.s)),
        V_BOOL => out.append(if x.i != 0 { "true" } else { "false" }),
        V_ENUM => if json { json_quote(out, str_of(x.s)); } else { out.append(str_of(x.s)); },
        V_VAR => { out.push('$'); out.append(str_of(x.s)); },
        V_LIST => {
            out.push('[');
            var c = x.first;
            var n = 0;
            while c >= 0 {
                if n > 0 { out.append(if json { "," } else { ", " }); }
                print_value(out, c, json);
                c = values[c].next;
                n++;
            }
            out.push(']');
        },
        _ => {
            out.push('{');
            var c = x.first;
            var n = 0;
            while c >= 0 {
                if n > 0 { out.append(if json { "," } else { ", " }); }
                if json { json_quote(out, str_of(values[c].key)); out.push(':'); }
                else { out.append(str_of(values[c].key)); out.append(": "); }
                print_value(out, c, json);
                c = values[c].next;
                n++;
            }
            out.push('}');
        },
    }
}

fn value_string(v: i64, json: bool) -> u8[>..] {
    var s: u8[>..] = [];
    print_value(s, v, json);
    return s;
}

// --- lookups --------------------------------------------------------------------------

fn field_of(t: i64, n: const u8[:]) -> i64 {
    let td = types[t];
    guard td.kind == OBJECT || td.kind == INTERFACE else { return -1; }
    for i in td.first..td.first + td.count { if str_of(fields[i].name) == n { return i; } }
    return -1;
}

fn input_of(first: i64, count: i64, n: const u8[:]) -> i64 {
    for i in first..first + count { if str_of(inputs[i].name) == n { return i; } }
    return -1;
}

fn enum_has(t: i64, n: const u8[:]) -> bool {
    let td = types[t];
    for e in enums[td.first..td.first + td.count] { if str_of(e.name) == n { return true; } }
    return false;
}

fn directive_named(n: const u8[:]) -> i64 {
    for d, i in directives { if str_of(d.name) == n { return i; } }
    return -1;
}

fn frag_named(n: const u8[:]) -> i64 {
    for f, i in frags { if str_of(f.name) == n { return i; } }
    return -1;
}

fn var_of(op: i64, n: const u8[:]) -> i64 {
    let o = ops[op];
    for i in o.vfirst..o.vfirst + o.vcount { if str_of(vardefs[i].name) == n { return i; } }
    return -1;
}

fn is_composite(t: i64) -> bool { let k = types[t].kind; k == OBJECT || k == INTERFACE || k == UNION }

// Whether object type `o` is `t` or one of its possible types.
fn is_possible(t: i64, o: i64) -> bool {
    if t == o { return true; }
    let td = types[t];
    if td.kind == UNION {
        for m in members[td.first..td.first + td.count] { if m.of == o { return true; } }
        return false;
    }
    if td.kind == INTERFACE {
        let od = types[o];
        for m in members[od.ifirst..od.ifirst + od.icount] { if m.of == t { return true; } }
    }
    return false;
}

// Whether some object type is possible for both.
fn overlap(a: i64, b: i64) -> bool {
    if a == b { return true; }
    for t, i in types {
        if t.kind == OBJECT && is_possible(a, i) && is_possible(b, i) { return true; }
    }
    return false;
}

// --- coercion ---------------------------------------------------------------------------

fn fail_reason(a: const u8[:], v: i64, b: const u8[:]) -> bool {
    reason.clear();
    reason.append(a);
    print_value(reason, v, false);
    reason.append(b);
    return false;
}

fn int32(x: i64) -> bool { x >= -2147483648 && x <= 2147483647 }

// Whether input value `v` coerces to type reference `t`, converting it in
// place where the coercion changes its form (an ID given as an integer, an
// enum given as a JSON string). `json` says the value came from the
// variables, where enums are strings and variables cannot occur.
recursive fn coerce(v: i64, t: i64, json: bool) -> bool {
    let k = values[v].kind;
    if k == V_VAR {
        if json { reason.clear(); reason.append("Unexpected variable."); return false; }
        use_var(v, t);
        return true;
    }
    let r = trefs[t];
    if r.kind == NON_NULL {
        if k == V_NULL {
            reason.clear();
            format(reason, "Expected value of type \"", type_string(t), "\", found null.");
            return false;
        }
        return coerce(v, r.of, json);
    }
    if k == V_NULL { return true; }
    if r.kind == LIST {
        if k != V_LIST { return coerce(v, r.of, json); }
        var c = values[v].first;
        while c >= 0 {
            if !coerce(c, r.of, json) { return false; }
            c = values[c].next;
        }
        return true;
    }
    let td = types[r.of];
    let tn = str_of(td.name);
    if td.kind == SCALAR {
        if tn == "Int" {
            if k == V_FLOAT && values[v].f == (values[v].f as! i64) {
                values[v].i = values[v].f as! i64;
                values[v].kind = V_INT;
            }
            guard values[v].kind == V_INT else { return fail_reason("Int cannot represent non-integer value: ", v, ""); }
            guard int32(values[v].i) else { return fail_reason("Int cannot represent non 32-bit signed integer value: ", v, ""); }
            return true;
        }
        if tn == "Float" {
            guard k == V_INT || k == V_FLOAT else { return fail_reason("Float cannot represent non numeric value: ", v, ""); }
            return true;
        }
        if tn == "String" {
            guard k == V_STRING else { return fail_reason("String cannot represent a non string value: ", v, ""); }
            return true;
        }
        if tn == "Boolean" {
            guard k == V_BOOL else { return fail_reason("Boolean cannot represent a non boolean value: ", v, ""); }
            return true;
        }
        if tn == "ID" {
            if k == V_INT {
                values[v].s = add_text(str(values[v].i));
                values[v].kind = V_STRING;
                return true;
            }
            guard k == V_STRING else { return fail_reason("ID cannot represent value: ", v, ""); }
            return true;
        }
        return true;                      // a custom scalar takes any value
    }
    if td.kind == ENUM {
        if json && k == V_STRING && enum_has(r.of, str_of(values[v].s)) { values[v].kind = V_ENUM; return true; }
        guard !json && k == V_ENUM else {
            return fail_reason(str("Enum \"", tn, "\" cannot represent non-enum value: "), v, ".");
        }
        guard enum_has(r.of, str_of(values[v].s)) else {
            return fail_reason("Value \"", v, str("\" does not exist in \"", tn, "\" enum."));
        }
        return true;
    }
    guard k == V_OBJECT else { return fail_reason(str("Expected value of type \"", tn, "\", found "), v, "."); }
    var c = values[v].first;
    while c >= 0 {
        let f = input_of(td.first, td.count, str_of(values[c].key));
        guard f >= 0 else {
            reason.clear();
            format(reason, "Field \"", str_of(values[c].key), "\" is not defined by type \"", tn, "\".");
            return false;
        }
        if !coerce(c, inputs[f].tref, json) { return false; }
        c = values[c].next;
    }
    for f in inputs[td.first..td.first + td.count] {
        guard trefs[f.tref].kind == NON_NULL && f.default < 0 else { continue; }
        var given = false;
        var g = values[v].first;
        while g >= 0 { if same(values[g].key, f.name) { given = true; } g = values[g].next; }
        guard given else {
            reason.clear();
            format(reason, "Field \"", tn, ".", str_of(f.name), "\" of required type \"", type_string(f.tref), "\" was not provided.");
            return false;
        }
    }
    return true;
}

// Whether a variable's type fits where it is used (the spec's
// AreTypesCompatible, with a default value standing in for non-null).
recursive fn types_fit(var_t: i64, loc_t: i64) -> bool {
    let vr = trefs[var_t];
    let lr = trefs[loc_t];
    if lr.kind == NON_NULL {
        guard vr.kind == NON_NULL else { return false; }
        return types_fit(vr.of, lr.of);
    }
    if vr.kind == NON_NULL { return types_fit(vr.of, loc_t); }
    if lr.kind == LIST {
        guard vr.kind == LIST else { return false; }
        return types_fit(vr.of, lr.of);
    }
    guard vr.kind == NAMED else { return false; }
    return vr.of == lr.of;
}

fn use_var(v: i64, t: i64) {
    let n = str_of(values[v].s);
    let d = var_of(cur_op, n);
    guard d >= 0 else {
        if ops[cur_op].name.len > 0 {
            add_error(str("Variable \"$", n, "\" is not defined by operation \"", str_of(ops[cur_op].name), "\"."), cur_at);
        } else {
            add_error(str("Variable \"$", n, "\" is not defined."), cur_at);
        }
        return;
    }
    vardefs[d].used = true;
    let vt = vardefs[d].tref;
    // A nullable variable with a default may fill a non-null position.
    var fits = types_fit(vt, t);
    if !fits && trefs[t].kind == NON_NULL && trefs[vt].kind != NON_NULL && vardefs[d].default >= 0 &&
       values[vardefs[d].default].kind != V_NULL {
        fits = types_fit(vt, trefs[t].of);
    }
    guard fits else {
        add_error(str("Variable \"$", n, "\" of type \"", type_string(vt), "\" used in position expecting type \"", type_string(t), "\"."), cur_at);
    }
}

fn check_literal(v: i64, t: i64, at: i64) {
    cur_at = at;
    if !coerce(v, t, false) { add_error(reason, at); }
}

// --- validation ---------------------------------------------------------------------------

fn check_args(afirst: i64, acount: i64, dfirst: i64, dcount: i64, what: const u8[:], who: const u8[:], at: i64) {
    for i in afirst..afirst + acount {
        let a = args[i];
        let d = input_of(dfirst, dcount, str_of(a.name));
        guard d >= 0 else {
            add_error(str("Unknown argument \"", str_of(a.name), "\" on ", what, "."), a.at);
            continue;
        }
        for j in afirst..i {
            if same(args[j].name, a.name) {
                add_error(str("There can be only one argument named \"", str_of(a.name), "\"."), a.at);
            }
        }
        check_literal(a.value, inputs[d].tref, a.at);
    }
    for d in inputs[dfirst..dfirst + dcount] {
        guard trefs[d.tref].kind == NON_NULL && d.default < 0 else { continue; }
        var given = false;
        for a in args[afirst..afirst + acount] { if same(a.name, d.name) { given = true; } }
        guard given else {
            add_error(str(who, " argument \"", str_of(d.name), "\" of type \"", type_string(d.tref), "\" is required, but it was not provided."), at);
        }
    }
}

fn check_directives(first: i64, count: i64, location: const u8[:]) {
    for i in first..first + count {
        let d = dirs[i];
        let dd = directive_named(str_of(d.name));
        guard dd >= 0 else { add_error(str("Unknown directive \"@", str_of(d.name), "\"."), d.at); continue; }
        let def = directives[dd];
        var ok = false;
        for l in locations[def.lfirst..def.lfirst + def.lcount] { if str_of(l) == location { ok = true; } }
        guard ok else { add_error(str("Directive \"@", str_of(d.name), "\" may not be used on ", location, "."), d.at); continue; }
        check_args(d.afirst, d.acount, def.afirst, def.acount, str("directive \"@", str_of(d.name), "\""), str("Directive \"@", str_of(d.name), "\""), d.at);
    }
}

fn type_name_at(n: Name, at: i64) -> i64 {
    let t = type_named(str_of(n));
    guard t >= 0 else { add_error(str("Unknown type \"", str_of(n), "\"."), at); return -1; }
    return t;
}

// Validates a selection set against its parent type; the fields at and
// below it, for cost estimates.
recursive fn check_set(set: i64, ty: i64, depth: i64) -> i64 {
    var cost = 0;
    var s = set;
    while s >= 0 {
        let sel = sels[s];
        if sel.kind == S_FIELD {
            check_directives(sel.dfirst, sel.dcount, "FIELD");
            cost += check_field(s, ty, depth);
        } else {
            check_directives(sel.dfirst, sel.dcount, if sel.kind == S_SPREAD { "FRAGMENT_SPREAD" } else { "INLINE_FRAGMENT" });
            var set2 = sel.set;
            var cond = ty;
            var f = -1;
            var ok = true;
            if sel.kind == S_SPREAD {
                f = frag_named(str_of(sel.name));
                if f < 0 {
                    add_error(str("Unknown fragment \"", str_of(sel.name), "\"."), sel.at);
                    ok = false;
                } else {
                    frags[f].used = true;
                    sels[s].frag = f;
                    set2 = frags[f].set;
                    for g in frag_chain {
                        if g == f {
                            add_error(str("Cannot spread fragment \"", str_of(sel.name), "\" within itself."), sel.at);
                            ok = false;
                        }
                    }
                    if ok { cond = type_name_at(frags[f].cond, frags[f].at); ok = cond >= 0; }
                }
            } else if sel.has_cond {
                cond = type_name_at(sel.cond, sel.at);
                ok = cond >= 0;
            }
            if ok && !is_composite(cond) {
                add_error(str("Fragment cannot condition on non composite type \"", str_of(types[cond].name), "\"."), sel.at);
                ok = false;
            }
            if ok && !overlap(ty, cond) {
                add_error(str("Fragment cannot be spread here as objects of type \"", str_of(types[ty].name),
                              "\" can never be of type \"", str_of(types[cond].name), "\"."), sel.at);
                ok = false;
            }
            if ok {
                if f >= 0 { frag_chain.push(f); }
                let c = check_set(set2, cond, depth);
                if f >= 0 { frag_chain.pop(); }
                sels[s].cost = c;
                sels[s].ctype = cond;
                cost += c;
            }
        }
        s = sels[s].next;
    }
    return cost;
}

recursive fn check_field(s: i64, ty: i64, depth: i64) -> i64 {
    let sel = sels[s];
    let n = str_of(sel.name);
    if n == "__typename" {
        if sel.set >= 0 {
            add_error("Field \"__typename\" must not have a selection since type \"String!\" has no subfields.", sel.at);
        }
        return 1;
    }
    var def = -1;
    if (n == "__schema" || n == "__type") && ty == query_type && introspection {
        def = field_of(t_meta, n);
    } else {
        def = field_of(ty, n);
    }
    guard def >= 0 else {
        add_error(str("Cannot query field \"", n, "\" on type \"", str_of(types[ty].name), "\"."), sel.at);
        return 1;
    }
    sels[s].def = def;
    let fd = fields[def];
    check_args(sel.afirst, sel.acount, fd.afirst, fd.acount,
               str("field \"", str_of(types[ty].name), ".", n, "\""), str("Field \"", n, "\""), sel.at);
    let nt = named_of(fd.tref);
    if is_leaf_kind(types[nt].kind) {
        if sel.set >= 0 {
            add_error(str("Field \"", n, "\" must not have a selection since type \"", type_string(fd.tref), "\" has no subfields."), sel.at);
        }
        return 1;
    }
    guard sel.set >= 0 else {
        add_error(str("Field \"", n, "\" of type \"", type_string(fd.tref), "\" must have a selection of subfields. Did you mean \"", n, " { ... }\"?"), sel.at);
        return 1;
    }
    guard depth < max_depth else {
        add_error(str("Query is nested too deeply: more than ", max_depth, " levels."), sel.at);
        return 1;
    }
    let cost = 1 + check_set(sel.set, nt, depth + 1);
    sels[s].cost = cost;
    return cost;
}

fn check_document() {
    var anonymous = false;
    for o, i in ops {
        if o.name.len == 0 { anonymous = true; }
        for j in 0..i {
            if o.name.len > 0 && same(ops[j].name, o.name) {
                add_error(str("There can be only one operation named \"", str_of(o.name), "\"."), o.at);
            }
        }
    }
    if anonymous && ops.len > 1 {
        for o in ops { if o.name.len == 0 { add_error("This anonymous operation must be the only defined operation.", o.at); } }
    }
    for f, i in frags {
        for j in 0..i {
            if same(frags[j].name, f.name) { add_error(str("There can be only one fragment named \"", str_of(f.name), "\"."), f.at); }
        }
    }
    for o, i in ops {
        cur_op = i;
        var root = query_type;
        if o.kind == OP_MUTATION {
            root = mutation_type;
            if root < 0 { add_error("Schema is not configured to execute mutation operation.", o.at); continue; }
        }
        if o.kind == OP_SUBSCRIPTION { add_error("Subscriptions are not supported.", o.at); continue; }
        check_directives(o.dfirst, o.dcount, if o.kind == OP_MUTATION { "MUTATION" } else { "QUERY" });
        for vi in o.vfirst..o.vfirst + o.vcount {
            let v = vardefs[vi];
            for vj in o.vfirst..vi {
                if same(vardefs[vj].name, v.name) { add_error(str("There can be only one variable named \"$", str_of(v.name), "\"."), v.at); }
            }
            let t = named_of_checked(v.tref, v.at);
            guard t >= 0 else { continue; }
            guard is_input_kind(types[t].kind) else {
                add_error(str("Variable \"$", str_of(v.name), "\" cannot be non-input type \"", type_string(v.tref), "\"."), v.at);
                continue;
            }
            if v.default >= 0 { check_literal(v.default, v.tref, v.at); }
        }
        frag_chain.clear();
        check_set(o.set, root, 1);
        for v in vardefs[o.vfirst..o.vfirst + o.vcount] {
            guard v.used else {
                if o.name.len > 0 {
                    add_error(str("Variable \"$", str_of(v.name), "\" is never used in operation \"", str_of(o.name), "\"."), v.at);
                } else {
                    add_error(str("Variable \"$", str_of(v.name), "\" is never used."), v.at);
                }
            }
        }
    }
    for f in frags {
        guard f.used else { add_error(str("Fragment \"", str_of(f.name), "\" is never used."), f.at); }
    }
}

// Resolves a request type reference's names; the named type, or -1.
fn named_of_checked(t: i64, at: i64) -> i64 {
    var r = t;
    while trefs[r].kind != NAMED { r = trefs[r].of; }
    if trefs[r].of < 0 {
        let n = type_named(str_of(trefs[r].name));
        guard n >= 0 else { add_error(str("Unknown type \"", str_of(trefs[r].name), "\"."), at); return -1; }
        trefs[r].of = n;
    }
    return trefs[r].of;
}

// --- variables -------------------------------------------------------------------------------

fn coerce_variables(given: i64) {
    let o = ops[cur_op];
    for vi in o.vfirst..o.vfirst + o.vcount {
        let d = vardefs[vi];
        let n = str_of(d.name);
        var v = -1;
        if given >= 0 {
            var c = values[given].first;
            while c >= 0 { if str_of(values[c].key) == n { v = c; } c = values[c].next; }
        }
        if v < 0 {
            if d.default >= 0 { vardefs[vi].value = d.default; continue; }
            if trefs[d.tref].kind == NON_NULL {
                add_error(str("Variable \"$", n, "\" of required type \"", type_string(d.tref), "\" was not provided."), d.at);
            }
            continue;
        }
        if values[v].kind == V_NULL && trefs[d.tref].kind == NON_NULL {
            add_error(str("Variable \"$", n, "\" of non-null type \"", type_string(d.tref), "\" must not be null."), d.at);
            continue;
        }
        guard coerce(v, d.tref, true) else {
            add_error(str("Variable \"$", n, "\" got invalid value ", value_string(v, true), "; ", reason), d.at);
            continue;
        }
        vardefs[vi].value = v;
    }
}

// --- the front end ------------------------------------------------------------------------------

fn request_error(msg: const u8[:]) {
    add_error(msg, -1);
    return false from prepare;
}

// Entry i of a JSON document as rows of `values`: the variables of a
// request's envelope.
recursive fn import_json(d: const json::Doc&, i: i64) -> i64 {
    let k = (d.tape[i].head & 15) as i64;
    let x = d.tape[i].data;
    if k == json::K_OBJECT || k == json::K_ARRAY {
        let obj = k == json::K_OBJECT;
        let idx = push_value(Value { kind: if obj { V_OBJECT } else { V_LIST }, .. });
        var prev = -1;
        var j = i + 1;
        while j < x as i64 {
            var key = Name { .. };
            if obj { key = add_text(json::text_of(d, j)); j += 1; }
            let v = import_json(d, j);
            values[v].key = key;
            if prev >= 0 { values[prev].next = v; } else { values[idx].first = v; }
            prev = v;
            j = json::next(d, j);
        }
        return idx;
    }
    if k == json::K_STRING { return push_value(Value { kind: V_STRING, s: add_text(json::text_of(d, i)), .. }); }
    if k == json::K_INT { let n = x as! i64; return push_value(Value { kind: V_INT, i: n, f: n, .. }); }
    if k == json::K_UINT { return push_value(Value { kind: V_FLOAT, f: x, .. }); }
    if k == json::K_FLOAT { return push_value(Value { kind: V_FLOAT, f: json::f64_of(x), .. }); }
    if k == json::K_TRUE || k == json::K_FALSE { return push_value(Value { kind: V_BOOL, i: if k == json::K_TRUE { 1 } else { 0 }, .. }); }
    return push_value(Value { kind: V_NULL, .. });
}

fn is_envelope(r: const u8[:]) -> bool {
    var i = 0;
    while i < r.len && (r[i] == ' ' || r[i] == '\n' || r[i] == '\r' || r[i] == '\t') { i++; }
    guard i < r.len && r[i] == '{' else { return false; }
    i++;
    while i < r.len && (r[i] == ' ' || r[i] == '\n' || r[i] == '\r' || r[i] == '\t') { i++; }
    return i < r.len && r[i] == '"';
}

// Takes a request through everything before execution: true when it may
// run, with `cur_op` its operation; otherwise its errors are in `errs`.
// A request is either a GraphQL document or a JSON object with "query" and,
// optionally, "operationName" and "variables".
fn prepare(request: const u8[:]) -> bool {
    guard loaded else { abort("graphql: no schema is loaded; call graphql::load_schema first"); }
    reset_request();
    var given = -1;
    var opname = Name { .. };
    var query = Name { .. };
    var have_query = !is_envelope(request);
    if !have_query {
        let d = json::parse(request);
        guard d.ok() else {
            request_error(str("The request is not valid JSON: ", d.error.message, " (byte ", d.error.at, ")."));
            return false;
        }
        let end = d.tape[0].data as i64;
        var j = 1;
        while j < end {
            let k = json::text_of(d, j);
            let vk = (d.tape[j + 1].head & 15) as i64;
            if k == "query" {
                guard vk == json::K_STRING else { request_error("The \"query\" of a request must be a string."); return false; }
                query = add_text(json::text_of(d, j + 1));
                have_query = true;
            } else if k == "operationName" {
                guard vk == json::K_STRING || vk == json::K_NULL else { request_error("The \"operationName\" of a request must be a string."); return false; }
                if vk == json::K_STRING { opname = add_text(json::text_of(d, j + 1)); }
            } else if k == "variables" {
                guard vk == json::K_OBJECT || vk == json::K_NULL else { request_error("The \"variables\" of a request must be an object."); return false; }
                if vk == json::K_OBJECT { given = import_json(d, j + 1); }
            }
            j = json::next(d, j + 1);
        }
        guard have_query else { request_error("A request must have a \"query\"."); return false; }
        if !parse_text(str_of(query), P_QUERY) { return false; }
    } else {
        if !parse_text(request, P_QUERY) { return false; }
    }
    check_document();
    guard nerrs == 0 else { return false; }
    cur_op = -1;
    if opname.len > 0 {
        for o, i in ops { if same(o.name, opname) { cur_op = i; } }
        guard cur_op >= 0 else { request_error(str("Unknown operation named \"", str_of(opname), "\".")); return false; }
    } else {
        guard ops.len == 1 else { request_error("Must provide operation name if query contains multiple operations."); return false; }
        cur_op = 0;
    }
    coerce_variables(given);
    return nerrs == 0;
}
