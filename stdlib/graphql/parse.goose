// Parsing: SDL into the schema tables, a query document into the request
// tables, JSON (a request's envelope and variables) into `values`.

namespace graphql;

import std;

// --- the request's tables ----------------------------------------------------

let OP_QUERY = 0;
let OP_MUTATION = 1;
let OP_SUBSCRIPTION = 2;

struct Op { kind: i64, name: Name, vfirst: i64 = 0, vcount: i64 = 0, dfirst: i64 = 0, dcount: i64 = 0, set: i64 = -1, at: i64 = 0 }

// A variable definition; `value` is its coerced value (a row of `values`),
// or -1 where the request gave none and there is no default.
struct VarDef { name: Name, tref: i64, default: i64 = -1, value: i64 = -1, at: i64 = 0, used: bool = false }

let S_FIELD = 0;
let S_SPREAD = 1;
let S_INLINE = 2;

// A selection. Sets are chains through `next`, from their first selection.
// Validation fills in `def` (a field's definition on its static parent
// type, or -1 for __typename and the like), `frag` (a spread's fragment) and
// `cost` (the fields at or below a field, for splitting work) and `ctype`
// (a fragment's type condition, as a row of `types`).
struct Sel {
    kind: i64, alias: Name, name: Name,
    afirst: i64 = 0, acount: i64 = 0, dfirst: i64 = 0, dcount: i64 = 0,
    set: i64 = -1, next: i64 = -1, cond: Name, has_cond: bool = false,
    at: i64 = 0, def: i64 = -1, frag: i64 = -1, cost: i64 = 1, ctype: i64 = -1,
}

struct Arg { name: Name, value: i64, at: i64 = 0 }
struct Dir { name: Name, afirst: i64 = 0, acount: i64 = 0, at: i64 = 0 }
struct Frag { name: Name, cond: Name, set: i64 = -1, dfirst: i64 = 0, dcount: i64 = 0, at: i64 = 0, used: bool = false }

var ops: Op[>..] = [];
var vardefs: VarDef[>..] = [];
var sels: Sel[>..] = [];
var args: Arg[>..] = [];
var dirs: Dir[>..] = [];
var frags: Frag[>..] = [];

// The schema block's root names, if it has one.
var schema_query: Name;
var schema_mutation: Name;

// --- driver ------------------------------------------------------------------------

// Parses `source` as `what`. A syntax error anywhere below is one error in
// `errs` and a false result.
fn parse_source(what: i64) -> bool {
    pos = 0;
    advance();
    if what == P_SDL { parse_sdl(); }
    else { parse_document(); }
    return true;
}

fn parse_text(s: const u8[:], what: i64) -> bool {
    source.clear();
    source.append(s);
    source_is_query = what == P_QUERY;
    return parse_source(what);
}

// --- values and types -------------------------------------------------------------

let M_CONST = 0;     // a literal with no variables in it
let M_VAR = 1;       // a literal in an operation, variables allowed

fn push_value(v: Value) -> i64 {
    values.push(v);
    return values.len - 1;
}

recursive fn parse_value(mode: i64) -> i64 {
    if at_punct('$') {
        guard mode == M_VAR else { unexpected(); }
        advance();
        let n = take_name();
        return push_value(Value { kind: V_VAR, s: n, .. });
    }
    if at_punct('[') || at_punct('{') {
        let obj = at_punct('{');
        let close: u8 = if obj { '}' } else { ']' };
        advance();
        let idx = push_value(Value { kind: if obj { V_OBJECT } else { V_LIST }, .. });
        var prev = -1;
        while !at_punct(close) {
            guard tok != T_EOF else { unexpected(); }
            var key = Name { .. };
            if obj {
                key = take_name();
                expect_punct(':');
            }
            let v = parse_value(mode);
            values[v].key = key;
            if prev >= 0 { values[prev].next = v; } else { values[idx].first = v; }
            prev = v;
        }
        advance();
        return idx;
    }
    if tok == T_INT {
        let i, ok = parse_int(token_text());
        if !ok {
            let f, fok = parse_flt(token_text());
            advance();
            return push_value(Value { kind: V_FLOAT, f: f, .. });
        }
        advance();
        return push_value(Value { kind: V_INT, i: i, f: i, .. });
    }
    if tok == T_FLOAT {
        let f, ok = parse_flt(token_text());
        advance();
        return push_value(Value { kind: V_FLOAT, f: f, .. });
    }
    if tok == T_STRING || tok == T_BLOCK {
        let s = take_string();
        return push_value(Value { kind: V_STRING, s: s, .. });
    }
    if tok == T_NAME {
        if at_name("true") || at_name("false") {
            let b = at_name("true");
            advance();
            return push_value(Value { kind: V_BOOL, i: if b { 1 } else { 0 }, .. });
        }
        if at_name("null") { advance(); return push_value(Value { kind: V_NULL, .. }); }
        let n = take_name();
        return push_value(Value { kind: V_ENUM, s: n, .. });
    }
    unexpected();
    return -1;
}

recursive fn parse_tref() -> i64 {
    var t = 0;
    if at_punct('[') {
        advance();
        let inner = parse_tref();
        expect_punct(']');
        trefs.push(TypeRef { kind: LIST, of: inner, .. });
        t = trefs.len - 1;
    } else {
        let n = take_name();
        trefs.push(TypeRef { kind: NAMED, name: n, .. });
        t = trefs.len - 1;
    }
    if at_punct('!') {
        advance();
        trefs.push(TypeRef { kind: NON_NULL, of: t, .. });
        t = trefs.len - 1;
    }
    return t;
}

fn parse_args(mode: i64) -> i64, i64 {
    let first = args.len;
    if !at_punct('(') { return first, 0; }
    advance();
    loop {
        let at = tstart;
        let n = take_name();
        expect_punct(':');
        let v = parse_value(mode);
        args.push(Arg { name: n, value: v, at: at });
        if at_punct(')') { break; }
    }
    advance();
    return first, args.len - first;
}

fn parse_directives(mode: i64) -> i64, i64 {
    let first = dirs.len;
    while at_punct('@') {
        let at = tstart;
        advance();
        let n = take_name();
        let af, ac = parse_args(mode);
        dirs.push(Dir { name: n, afirst: af, acount: ac, at: at });
    }
    return first, dirs.len - first;
}

// --- SDL ---------------------------------------------------------------------------

fn take_description() -> Name {
    if tok == T_STRING || tok == T_BLOCK { return take_string(); }
    return Name { .. };
}

// A definition's directives, of which only @deprecated means anything here.
fn parse_def_directives() -> bool, Name {
    let df, dc = parse_directives(M_CONST);
    for d in dirs[df..df + dc] {
        guard str_of(d.name) == "deprecated" else { continue; }
        for a in args[d.afirst..d.afirst + d.acount] {
            if str_of(a.name) == "reason" && values[a.value].kind == V_STRING { return true, values[a.value].s; }
        }
        return true, add_text("No longer supported");
    }
    return false, Name { .. };
}

// Arguments `( ... )` or input fields `{ ... }`.
fn parse_input_defs(open: u8, close: u8) -> i64, i64 {
    let first = inputs.len;
    if !at_punct(open) { return first, 0; }
    advance();
    while !at_punct(close) {
        guard tok != T_EOF else { unexpected(); }
        let desc = take_description();
        let n = take_name();
        expect_punct(':');
        let t = parse_tref();
        var def = -1;
        if at_punct('=') { advance(); def = parse_value(M_CONST); }
        let dep, reason = parse_def_directives();
        inputs.push(InputDef { name: n, desc: desc, tref: t, default: def, deprecated: dep, reason: reason });
    }
    advance();
    return first, inputs.len - first;
}

fn parse_field_defs(owner: i64) -> i64 {
    let first = fields.len;
    if !at_punct('{') { return 0; }
    advance();
    while !at_punct('}') {
        guard tok != T_EOF else { unexpected(); }
        let desc = take_description();
        let n = take_name();
        let af, ac = parse_input_defs('(', ')');
        expect_punct(':');
        let t = parse_tref();
        let dep, reason = parse_def_directives();
        fields.push(FieldDef { name: n, desc: desc, tref: t, owner: owner, afirst: af, acount: ac, deprecated: dep, reason: reason });
    }
    advance();
    return fields.len - first;
}

fn parse_implements() -> i64, i64 {
    let first = members.len;
    if !at_name("implements") { return first, 0; }
    advance();
    if at_punct('&') { advance(); }
    loop {
        members.push(Member { name: take_name(), .. });
        if !at_punct('&') { break; }
        advance();
    }
    return first, members.len - first;
}

fn push_type(t: TypeDef) -> i64 {
    for o in types {
        guard !same(o.name, t.name) else {
            parse_error(str("There can be only one type named \"", str_of(t.name), "\"."), tstart);
        }
    }
    types.push(t);
    return types.len - 1;
}

fn parse_sdl() {
    while tok != T_EOF {
        let desc = take_description();
        guard tok == T_NAME else { unexpected(); }
        if at_name("schema") {
            advance();
            parse_directives(M_CONST);
            expect_punct('{');
            while !at_punct('}') {
                guard tok != T_EOF else { unexpected(); }
                let op = take_name();
                expect_punct(':');
                let n = take_name();
                if str_of(op) == "query" { schema_query = n; }
                else if str_of(op) == "mutation" { schema_mutation = n; }
            }
            advance();
        } else if at_name("scalar") {
            advance();
            let n = take_name();
            parse_directives(M_CONST);
            push_type(TypeDef { name: n, desc: desc, kind: SCALAR, .. });
        } else if at_name("type") || at_name("interface") {
            let kind = if at_name("type") { OBJECT } else { INTERFACE };
            advance();
            let n = take_name();
            let mf, mc = parse_implements();
            parse_directives(M_CONST);
            let t = push_type(TypeDef { name: n, desc: desc, kind: kind, first: fields.len, ifirst: mf, icount: mc, .. });
            types[t].count = parse_field_defs(t);
        } else if at_name("union") {
            advance();
            let n = take_name();
            parse_directives(M_CONST);
            let first = members.len;
            if at_punct('=') {
                advance();
                if at_punct('|') { advance(); }
                loop {
                    members.push(Member { name: take_name(), .. });
                    if !at_punct('|') { break; }
                    advance();
                }
            }
            push_type(TypeDef { name: n, desc: desc, kind: UNION, first: first, count: members.len - first, .. });
        } else if at_name("enum") {
            advance();
            let n = take_name();
            parse_directives(M_CONST);
            let first = enums.len;
            if at_punct('{') {
                advance();
                while !at_punct('}') {
                    guard tok != T_EOF else { unexpected(); }
                    let vdesc = take_description();
                    let v = take_name();
                    let dep, reason = parse_def_directives();
                    enums.push(EnumDef { name: v, desc: vdesc, deprecated: dep, reason: reason });
                }
                advance();
            }
            push_type(TypeDef { name: n, desc: desc, kind: ENUM, first: first, count: enums.len - first, .. });
        } else if at_name("input") {
            advance();
            let n = take_name();
            parse_directives(M_CONST);
            let first, count = parse_input_defs('{', '}');
            push_type(TypeDef { name: n, desc: desc, kind: INPUT, first: first, count: count, .. });
        } else if at_name("directive") {
            advance();
            expect_punct('@');
            let n = take_name();
            let af, ac = parse_input_defs('(', ')');
            var rep = false;
            if at_name("repeatable") { advance(); rep = true; }
            expect_keyword("on");
            if at_punct('|') { advance(); }
            let lf = locations.len;
            loop {
                locations.push(take_name());
                if !at_punct('|') { break; }
                advance();
            }
            directives.push(DirDef { name: n, desc: desc, afirst: af, acount: ac, lfirst: lf, lcount: locations.len - lf, repeatable: rep });
        } else if at_name("extend") {
            syntax_error("Type extensions are not supported.", tstart);
        } else {
            unexpected();
        }
    }
}

// --- query documents -----------------------------------------------------------------

fn parse_document() {
    guard tok != T_EOF else { unexpected(); }
    while tok != T_EOF {
        let at = tstart;
        if at_punct('{') {
            let set = parse_set();
            ops.push(Op { kind: OP_QUERY, name: Name { .. }, vfirst: vardefs.len, set: set, at: at, .. });
        } else if at_name("query") || at_name("mutation") || at_name("subscription") {
            let kind = if at_name("query") { OP_QUERY } else if at_name("mutation") { OP_MUTATION } else { OP_SUBSCRIPTION };
            advance();
            var n = Name { .. };
            if tok == T_NAME { n = take_name(); }
            let vf = vardefs.len;
            if at_punct('(') {
                advance();
                while !at_punct(')') {
                    let vat = tstart;
                    expect_punct('$');
                    let vn = take_name();
                    expect_punct(':');
                    let t = parse_tref();
                    var def = -1;
                    if at_punct('=') { advance(); def = parse_value(M_CONST); }
                    parse_directives(M_CONST);
                    vardefs.push(VarDef { name: vn, tref: t, default: def, at: vat, .. });
                }
                advance();
            }
            let df, dc = parse_directives(M_VAR);
            let set = parse_set();
            ops.push(Op { kind: kind, name: n, vfirst: vf, vcount: vardefs.len - vf, dfirst: df, dcount: dc, set: set, at: at });
        } else if at_name("fragment") {
            advance();
            let n = take_name();
            guard str_of(n) != "on" else { syntax_error("Unexpected Name \"on\".", at); }
            expect_keyword("on");
            let cond = take_name();
            let df, dc = parse_directives(M_VAR);
            let set = parse_set();
            frags.push(Frag { name: n, cond: cond, set: set, dfirst: df, dcount: dc, at: at, .. });
        } else {
            unexpected();
        }
    }
}

recursive fn parse_set() -> i64 {
    expect_punct('{');
    var first = -1;
    var prev = -1;
    loop {
        if at_punct('}') {
            guard first >= 0 else { syntax_error("Expected Name, found \"}\".", tstart); }
            advance();
            break;
        }
        guard tok != T_EOF else { unexpected(); }
        let s = parse_selection();
        if prev >= 0 { sels[prev].next = s; } else { first = s; }
        prev = s;
    }
    return first;
}

recursive fn parse_selection() -> i64 {
    let at = tstart;
    if at_punct('.') {
        advance();
        if tok == T_NAME && !at_name("on") {
            let n = take_name();
            let df, dc = parse_directives(M_VAR);
            sels.push(Sel { kind: S_SPREAD, alias: n, name: n, dfirst: df, dcount: dc, at: at, cond: Name { .. }, .. });
            return sels.len - 1;
        }
        var cond = Name { .. };
        var has = false;
        if at_name("on") { advance(); cond = take_name(); has = true; }
        let df, dc = parse_directives(M_VAR);
        let idx = sels.len;
        sels.push(Sel { kind: S_INLINE, alias: cond, name: cond, dfirst: df, dcount: dc, cond: cond, has_cond: has, at: at, .. });
        let set = parse_set();
        sels[idx].set = set;
        return idx;
    }
    let alias = take_name();
    var n = alias;
    if at_punct(':') { advance(); n = take_name(); }
    let af, ac = parse_args(M_VAR);
    let df, dc = parse_directives(M_VAR);
    let idx = sels.len;
    sels.push(Sel { kind: S_FIELD, alias: alias, name: n, afirst: af, acount: ac, dfirst: df, dcount: dc, at: at, cond: Name { .. }, .. });
    if at_punct('{') {
        let set = parse_set();
        sels[idx].set = set;
    }
    return idx;
}

// --- the schema ----------------------------------------------------------------------

let BUILTIN_SDL = """
    scalar Int
    scalar Float
    scalar String
    scalar Boolean
    scalar ID
    directive @skip(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT
    directive @include(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT
    directive @deprecated(reason: String = "No longer supported") on FIELD_DEFINITION | ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION | ENUM_VALUE
    directive @specifiedBy(url: String!) on SCALAR
    type __Schema {
      description: String
      types: [__Type!]!
      queryType: __Type!
      mutationType: __Type
      subscriptionType: __Type
      directives: [__Directive!]!
    }
    type __Type {
      kind: __TypeKind!
      name: String
      description: String
      specifiedByURL: String
      fields(includeDeprecated: Boolean = false): [__Field!]
      interfaces: [__Type!]
      possibleTypes: [__Type!]
      enumValues(includeDeprecated: Boolean = false): [__EnumValue!]
      inputFields(includeDeprecated: Boolean = false): [__InputValue!]
      ofType: __Type
      isOneOf: Boolean
    }
    type __Meta {
      __schema: __Schema!
      __type(name: String!): __Type
    }
    enum __TypeKind { SCALAR OBJECT INTERFACE UNION ENUM INPUT_OBJECT LIST NON_NULL }
    type __Field {
      name: String!
      description: String
      args(includeDeprecated: Boolean = false): [__InputValue!]!
      type: __Type!
      isDeprecated: Boolean!
      deprecationReason: String
    }
    type __InputValue {
      name: String!
      description: String
      type: __Type!
      defaultValue: String
      isDeprecated: Boolean!
      deprecationReason: String
    }
    type __EnumValue {
      name: String!
      description: String
      isDeprecated: Boolean!
      deprecationReason: String
    }
    type __Directive {
      name: String!
      description: String
      locations: [__DirectiveLocation!]!
      args(includeDeprecated: Boolean = false): [__InputValue!]!
      isRepeatable: Boolean!
    }
    enum __DirectiveLocation {
      QUERY MUTATION SUBSCRIPTION FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT
      VARIABLE_DEFINITION SCHEMA SCALAR OBJECT FIELD_DEFINITION ARGUMENT_DEFINITION INTERFACE
      UNION ENUM ENUM_VALUE INPUT_OBJECT INPUT_FIELD_DEFINITION
    }
    """;

// The row of `types` named `n`, or -1.
fn type_named(n: const u8[:]) -> i64 {
    for t, i in types { if str_of(t.name) == n { return i; } }
    return -1;
}

// The row of `types` a reference names, under its wrappers.
fn named_of(t: i64) -> i64 {
    var r = t;
    while trefs[r].kind != NAMED { r = trefs[r].of; }
    return trefs[r].of;
}

fn is_input_kind(k: i64) -> bool { k == SCALAR || k == ENUM || k == INPUT }
fn is_leaf_kind(k: i64) -> bool { k == SCALAR || k == ENUM }

// Types the introspection resolver answers for, found once.
var t_schema: i64 = -1;
var t_type: i64 = -1;
var t_field: i64 = -1;
var t_input: i64 = -1;
var t_enum: i64 = -1;
var t_directive: i64 = -1;
var t_meta: i64 = -1;              // holds the definitions of __schema and __type

fn schema_fail(msg: const u8[:]) {
    add_error(msg, -1);
    return false from link_schema;
}

// Resolves every name the schema's definitions use and checks that each is
// a type of the kind its position needs.
fn link_schema() -> bool {
    for &r in trefs {
        guard r.kind == NAMED else { continue; }
        let t = type_named(str_of(r.name));
        guard t >= 0 else { schema_fail(str("Unknown type \"", str_of(r.name), "\".")); return false; }
        r.of = t;
    }
    for t, ti in types {
        if t.kind == OBJECT || t.kind == INTERFACE {
            for &m in members[t.ifirst..t.ifirst + t.icount] {
                m.of = type_named(str_of(m.name));
                guard m.of >= 0 && types[m.of].kind == INTERFACE else {
                    schema_fail(str("Type \"", str_of(t.name), "\" must only implement Interface types, it cannot implement ", str_of(m.name), ".")); return false;
                }
            }
            for f in fields[t.first..t.first + t.count] {
                guard !is_input_kind(types[named_of(f.tref)].kind) || is_leaf_kind(types[named_of(f.tref)].kind) else {
                    schema_fail(str("The type of ", str_of(t.name), ".", str_of(f.name), " must be Output Type.")); return false;
                }
                for a in inputs[f.afirst..f.afirst + f.acount] {
                    guard is_input_kind(types[named_of(a.tref)].kind) else {
                        schema_fail(str("The type of ", str_of(t.name), ".", str_of(f.name), "(", str_of(a.name), ":) must be Input Type.")); return false;
                    }
                }
            }
        }
        if t.kind == UNION {
            for &m in members[t.first..t.first + t.count] {
                m.of = type_named(str_of(m.name));
                guard m.of >= 0 && types[m.of].kind == OBJECT else {
                    schema_fail(str("Union type ", str_of(t.name), " can only include Object types, it cannot include ", str_of(m.name), ".")); return false;
                }
            }
        }
        if t.kind == INPUT {
            for a in inputs[t.first..t.first + t.count] {
                guard is_input_kind(types[named_of(a.tref)].kind) else {
                    schema_fail(str("The type of ", str_of(t.name), ".", str_of(a.name), " must be Input Type.")); return false;
                }
            }
        }
    }
    // An object or interface has every field of the interfaces it implements.
    for t in types {
        guard t.kind == OBJECT || t.kind == INTERFACE else { continue; }
        for m in members[t.ifirst..t.ifirst + t.icount] {
            let it = types[m.of];
            for f in fields[it.first..it.first + it.count] {
                var found = false;
                for g in fields[t.first..t.first + t.count] { if same(g.name, f.name) { found = true; } }
                guard found else {
                    schema_fail(str("Interface field ", str_of(it.name), ".", str_of(f.name), " expected but ",
                                    str_of(t.name), " does not provide it.")); return false;
                }
            }
        }
    }
    query_type = type_named(if schema_query.len > 0 { str_of(schema_query) } else { "Query" });
    guard query_type >= 0 && types[query_type].kind == OBJECT else { schema_fail("Query root type must be provided."); return false; }
    mutation_type = type_named(if schema_mutation.len > 0 { str_of(schema_mutation) } else { "Mutation" });
    guard mutation_type < 0 || types[mutation_type].kind == OBJECT else { schema_fail("Mutation root type must be Object type."); return false; }
    t_schema = type_named("__Schema");
    t_type = type_named("__Type");
    t_field = type_named("__Field");
    t_input = type_named("__InputValue");
    t_enum = type_named("__EnumValue");
    t_directive = type_named("__Directive");
    t_meta = type_named("__Meta");
    return true;
}

// Empties the request's tables, leaving the schema's rows.
fn reset_request() {
    ops.clear();
    vardefs.clear();
    sels.clear();
    args.clear();
    dirs.clear();
    frags.clear();
    errs.clear();
    nerrs = 0;
    text.resize(schema_text);
    values.resize(schema_values);
    trefs.resize(schema_trefs);
}

// Loads the program's schema from SDL: "" on success, else what is wrong
// with it, with its line and column. Call it once, in main, before any
// worker is spawned.
fn load_schema(sdl: const u8[:]) -> u8[>..] {
    types.clear(); fields.clear(); inputs.clear(); enums.clear();
    trefs.clear(); members.clear(); directives.clear(); locations.clear();
    text.clear(); values.clear();
    schema_query = Name { .. };
    schema_mutation = Name { .. };
    schema_text = 0; schema_values = 0; schema_trefs = 0;
    reset_request();
    loaded = false;
    if !parse_text(BUILTIN_SDL, P_SDL) { abort("graphql: the built-in schema does not parse"); }
    if !parse_text(sdl, P_SDL) {
        let line, col = line_col(err_at);
        return str(first_message, " (line ", line, ", column ", col, ")");
    }
    if !link_schema() { return str(first_message); }
    schema_text = text.len;
    schema_values = values.len;
    schema_trefs = trefs.len;
    reset_request();
    loaded = true;
    return str("");
}
