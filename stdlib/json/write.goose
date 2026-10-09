// The writer: JSON appended to a byte array the caller owns, with
// containers as trailing blocks.
//
//     var w = json::writer(out);
//     w.object() {
//         w.key("id"); w.int(7);
//         w.key("tags"); w.array() { w.string("a"); w.string("b"); };
//     };
//
// Commas take one bit: whether the next item needs one. Opening a container
// or writing a key clears it; a value or a closed container sets it, which
// is all the parent needs, so there is no stack. A second bit says a key
// was just written, so its value follows it on the same line. The writer
// checks nothing else -- a key outside an object or an object of bare
// values is written as asked.

namespace json;

import std;

struct Writer<A> {
    out: A&,
    comma: bool = false,
    keyed: bool = false,      // a key was just written: its value goes on its line
    indent: i64 = 0,          // spaces per level when pretty printing; 0 is compact
    depth: i64 = 0,
}

// A compact writer onto `out`, a u8[>..] or u8[>..<].
fn writer<A>(out: A&) -> Writer<A> { Writer<A> { out: out } }

// A writer that puts each item on a line of its own, indented by `indent`
// spaces per level.
fn pretty_writer<A>(out: A&, indent: i64) -> Writer<A> { Writer<A> { out: out, indent: indent } }

fn item<A>(w: Writer<A>&) {
    if w.keyed { w.keyed = false; return; }
    if w.comma { w.out.push(','); }
    if w.indent > 0 && w.depth > 0 { newline(w); }
}

fn newline<A>(w: Writer<A>&) {
    w.out.push('\n');
    for i in w.depth * w.indent { w.out.push(' '); }
}

fn open<A>(w: Writer<A>&, c: u8) {
    item(w);
    w.out.push(c);
    w.comma = false;
    w.depth += 1;
}

fn close<A>(w: Writer<A>&, c: u8) {
    w.depth -= 1;
    if w.indent > 0 && w.comma { newline(w); }
    w.out.push(c);
    w.comma = true;
}

// An object: what the block writes, keys and values, are its members.
fn ::object<A, F>(w: json::Writer<A>&) {
    json::open(w, '{');
    F();
    json::close(w, '}');
}

// An array: what the block writes are its items.
fn ::array<A, F>(w: json::Writer<A>&) {
    json::open(w, '[');
    F();
    json::close(w, ']');
}

fn ::key<A>(w: json::Writer<A>&, k: const u8[:]) {
    json::item(w);
    json::write_string(w.out, k);
    w.out.push(':');
    if w.indent > 0 { w.out.push(' '); }
    w.comma = false;
    w.keyed = true;
}

// A key already quoted and followed by its colon, as a constant: written
// with no scan.
fn ::raw_key<A>(w: json::Writer<A>&, quoted: const u8[:]) {
    json::item(w);
    w.out.append(quoted);
    w.comma = false;
    w.keyed = true;
}

fn ::string<A>(w: json::Writer<A>&, s: const u8[:]) {
    json::item(w);
    json::write_string(w.out, s);
    w.comma = true;
}

fn ::int<A>(w: json::Writer<A>&, v: i64) {
    json::item(w);
    json::write_int(w.out, v);
    w.comma = true;
}

fn ::uint<A>(w: json::Writer<A>&, v: u64) {
    json::item(w);
    json::write_uint(w.out, v);
    w.comma = true;
}

// A double, shortest round trip; NaN and the infinities as null.
fn ::float<A>(w: json::Writer<A>&, v: f64) {
    json::item(w);
    json::write_float(w.out, v);
    w.comma = true;
}

fn ::boolean<A>(w: json::Writer<A>&, v: bool) {
    json::item(w);
    w.out.append(if v { "true" } else { "false" });
    w.comma = true;
}

fn ::none<A>(w: json::Writer<A>&) {
    json::item(w);
    w.out.append("null");
    w.comma = true;
}

// Text that is already one JSON value, appended as it is.
fn ::raw<A>(w: json::Writer<A>&, value: const u8[:]) {
    json::item(w);
    w.out.append(value);
    w.comma = true;
}

// A key and its value in one call.
fn ::field<A>(w: json::Writer<A>&, k: const u8[:], v: const u8[:]) { w.key(k); w.string(v); }
fn ::field<A>(w: json::Writer<A>&, k: const u8[:], v: i64) { w.key(k); w.int(v); }
fn ::field<A>(w: json::Writer<A>&, k: const u8[:], v: f64) { w.key(k); w.float(v); }
fn ::field<A>(w: json::Writer<A>&, k: const u8[:], v: bool) { w.key(k); w.boolean(v); }

// --- strings -------------------------------------------------------------------------

const HEX: u8[16] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

// The escape of a byte that needs one: '"', '\' or a control character.
fn write_escape<A>(out: A&, c: u8) {
    if c == '"' { out.append("\\\""); }
    else if c == '\\' { out.append("\\\\"); }
    else if c == '\n' { out.append("\\n"); }
    else if c == '\r' { out.append("\\r"); }
    else if c == '\t' { out.append("\\t"); }
    else if c == 8 { out.append("\\b"); }
    else if c == 12 { out.append("\\f"); }
    else {
        out.append("\\u00");
        out.push(HEX[c >> 4]);
        out.push(HEX[c & 15]);
    }
}

// s as a JSON string. Clean runs are found eight bytes at a time and
// appended whole; bytes from 0x80 up pass through unchanged.
fn write_string<A>(out: A&, s: const u8[:]) {
    out.push('"');
    var run = 0;
    var i = 0;
    while i + 8 <= s.len {
        let x = load8(s, i);
        let m = lanes_eq(x, '"') | lanes_eq(x, '\\') | lanes_lt(x, 0x20);
        if m == 0 { i += 8; continue; }
        i += first_lane(m);
        out.append(s[run..i]);
        write_escape(out, s[i]);
        i += 1;
        run = i;
    }
    while i < s.len {
        let c = s[i];
        if c == '"' || c == '\\' || c < 0x20 {
            out.append(s[run..i]);
            write_escape(out, c);
            run = i + 1;
        }
        i += 1;
    }
    out.append(s[run..]);
    out.push('"');
}
