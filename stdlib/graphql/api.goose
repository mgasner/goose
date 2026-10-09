// What a resolver calls. These are declared in the global namespace, so
// that a resolver written outside `graphql` reaches them with UFCS --
// `r.int(42)`, `f.string("id")` -- which looks in the caller's namespace
// (docs/design/namespaces.md). They take only graphql's own types.

namespace graphql;

import std;

// --- the field ------------------------------------------------------------

// Whether this is the field named n (its schema name, not its alias).
fn ::is(f: graphql::Field&, n: const u8[:]) -> bool { graphql::str_of(graphql::fields[f.def].name) == n }

fn ::field_name(f: graphql::Field&) -> const u8[:] { graphql::str_of(graphql::fields[f.def].name) }

// The name of the object type the field is being run on.
fn ::parent_type(f: graphql::Field&) -> const u8[:] { graphql::str_of(graphql::types[f.parent].name) }

// Argument n: the request's value, a variable's, or the schema's default.
// Asking for an argument the field does not declare aborts.
fn ::arg(f: graphql::Field&, n: const u8[:]) -> graphql::Input { graphql::field_arg(f, n) }

// Whether argument n has a value that is not null.
fn ::has(f: graphql::Field&, n: const u8[:]) -> bool { graphql::present(graphql::field_arg(f, n)) }

// Argument n's value. Validation has checked it against the schema; an
// absent or null one aborts, so check a nullable one with has() first.
fn ::int(f: graphql::Field&, n: const u8[:]) -> i64 { graphql::field_arg(f, n).int() }
fn ::float(f: graphql::Field&, n: const u8[:]) -> f64 { graphql::field_arg(f, n).float() }
fn ::string(f: graphql::Field&, n: const u8[:]) -> const u8[:] { graphql::field_arg(f, n).string() }
fn ::boolean(f: graphql::Field&, n: const u8[:]) -> bool { graphql::field_arg(f, n).boolean() }

// --- the batch hook's selection ----------------------------------------------

// Whether any of the batch's objects will be asked for field n.
fn ::has(s: graphql::Selection&, n: const u8[:]) -> bool { graphql::selection_has(n) }

// The object type of the batch's objects.
fn ::type_name(s: graphql::Selection&) -> const u8[:] { graphql::str_of(graphql::types[s.ty].name) }

// --- input values ----------------------------------------------------------------

fn ::present(a: graphql::Input) -> bool { graphql::present(a) }

fn ::int(a: graphql::Input) -> i64 { graphql::need(a, "an Int argument").i }

fn ::float(a: graphql::Input) -> f64 {
    let v = graphql::need(a, "a Float argument");
    if v.kind == graphql::V_INT { return v.i; }
    return v.f;
}

// A String, an ID, or an enum value's name.
fn ::string(a: graphql::Input) -> const u8[:] { graphql::str_of(graphql::need(a, "a String argument").s) }

fn ::boolean(a: graphql::Input) -> bool { graphql::need(a, "a Boolean argument").i != 0 }

// Field n of an input object, with its default where it was not given.
fn ::member(a: graphql::Input, n: const u8[:]) -> graphql::Input { graphql::input_member(a, n) }

// Each item of a list, in order; a single value is a list of itself.
fn ::each<F>(a: graphql::Input) { graphql::each_input(a, F); }

// --- the result -------------------------------------------------------------------

fn ::int<O>(r: graphql::Result<O>&, v: i64) {
    graphql::entries.push(graphql::Entry { kind: graphql::E_INT, i: v, f: v, .. });
}

fn ::float<O>(r: graphql::Result<O>&, v: f64) {
    graphql::entries.push(graphql::Entry { kind: graphql::E_FLOAT, f: v, .. });
}

fn ::boolean<O>(r: graphql::Result<O>&, v: bool) {
    graphql::entries.push(graphql::Entry { kind: graphql::E_BOOL, i: if v { 1 } else { 0 }, .. });
}

// A String or ID; for an enum, the value's name works too.
fn ::string<O>(r: graphql::Result<O>&, s: const u8[:]) { graphql::put_text(graphql::E_STRING, s); }

fn ::enum_value<O>(r: graphql::Result<O>&, s: const u8[:]) { graphql::put_text(graphql::E_ENUM, s); }

// A custom scalar's value as JSON, written to the response as it is.
fn ::json<O>(r: graphql::Result<O>&, s: const u8[:]) { graphql::put_text(graphql::E_JSON, s); }

// null. (`null` is a keyword, hence the name.)
fn ::none<O>(r: graphql::Result<O>&) { graphql::put_null(); }

// An object: the executor runs the field's selection set on it.
fn ::object<O>(r: graphql::Result<O>&, o: O) {
    r.handles.push(graphql::Handle<O>.App { o: o });
    graphql::entries.push(graphql::Entry { kind: graphql::E_OBJECT, i: r.handles.len - 1, .. });
}

// A list: what the block gives, in order, are its items. Lists nest.
fn ::list<O, F>(r: graphql::Result<O>&) {
    let l = graphql::begin_list();
    F();
    graphql::end_list(l);
}

// A field error: the field is null and the response's errors say why.
fn ::error<O>(r: graphql::Result<O>&, msg: const u8[:]) { graphql::put_text(graphql::E_ERROR, msg); }
