// The document: one pass over the text into a tape of 16-byte entries, in
// document order, and handles that read it.
//
// An entry's head holds its kind in bits 0-3, flags in bits 4-7 and a
// length or count above; its data word holds the value. A container's data
// is the index one past its last entry, so skipping it is one load; an
// object's entries alternate key and value. A string without escapes is a
// view of the source; one with escapes is unescaped into the text area,
// a run of entries after the tape's last whose bytes hold the text.

namespace json;

import std;
import math;

let K_NULL = 0;
let K_FALSE = 1;
let K_TRUE = 2;
let K_INT = 3;
let K_UINT = 4;
let K_FLOAT = 5;
let K_STRING = 6;
let K_ARRAY = 7;
let K_OBJECT = 8;
let K_MISSING = 15;          // what a lookup that found nothing gives

let F_ESC: u64 = 16;         // a string in the text area, not the source

struct Val { head: u64, data: u64 }

// A parsed document. `src` is the text it was parsed from, which strings
// without escapes are views of; it must outlive the document, which the
// compiler checks.
struct Doc {
    src: const u8[:],
    ntape: i64 = 0,
    error: Error = Error {},
    tape: Val[>..],
}

// A value of a document: the document and an entry of its tape. A value
// that is not there -- a missing key, an index past the end -- has entry
// -1, and reads as its kind's default.
struct Value { doc: const Doc&, entry: i64 }

var max_depth: i64 = 1024;

// --- parsing --------------------------------------------------------------------

// A container open around the value being read.
struct Open { at: i64, count: i64, obj: bool }

// Parses src. On malformed input the document's `error` says where and
// why, and its root is missing.
fn parse(src: const u8[:]) -> Doc {
    var d = Doc { src: src, tape: [] };
    var esc: u8[>..] = [];              // the text of strings with escapes
    var opens: Open[>..<] = [];
    if !parse_into(d, esc, opens) { return d; }
    d.ntape = d.tape.len;
    // The text area: the unescaped strings, sixteen bytes to an entry.
    if esc.len > 0 {
        while esc.len % 16 != 0 { esc.push(0); }
        var k = 0;
        while k < esc.len {
            d.tape.push(Val { head: load8(esc, k), data: load8(esc, k + 8) });
            k += 16;
        }
    }
    return d;
}

fn fail(d: Doc&, at: i64, message: const u8[:]) -> bool {
    d.error.error(at, message);
    return false;
}

fn parse_into(d: Doc&, esc: u8[>..]&, opens: Open[>..<]&) -> bool {
    let s = d.src;
    let n = s.len;
    var i = skip_ws(s, 0);
    var cur = -1;          // the tape entry of the innermost open container
    var count = 0;         // the values it has so far
    var obj = false;
    loop {
        // A value starts at i.
        guard i < n else { return fail(d, i, "unexpected end of input"); }
        let c = s[i];
        if c == '"' {
            i = parse_string(d, i, esc);
            if i < 0 { return false; }
        } else if c == '{' || c == '[' {
            guard opens.len < max_depth else { return fail(d, i, "nesting too deep"); }
            opens.push(Open { at: cur, count: count, obj: obj });
            obj = c == '{';
            cur = d.tape.len;
            count = 0;
            d.tape.push(Val { head: if obj { K_OBJECT } else { K_ARRAY }, data: 0 });
            i = skip_ws(s, i + 1);
            if i < n && s[i] == (if obj { '}' } else { ']' }) {
                d.tape[cur].data = d.tape.len as u64;
                let o = opens.pop();
                cur = o.at;
                count = o.count;
                obj = o.obj;
                i += 1;
            } else {
                if obj {
                    i = parse_key(d, i, esc);
                    if i < 0 { return false; }
                }
                continue;
            }
        } else if c == 't' {
            guard i + 4 <= n && s[i..i + 4] == "true" else { return fail(d, i, "invalid literal"); }
            d.tape.push(Val { head: K_TRUE, data: 0 });
            i += 4;
        } else if c == 'f' {
            guard i + 5 <= n && s[i..i + 5] == "false" else { return fail(d, i, "invalid literal"); }
            d.tape.push(Val { head: K_FALSE, data: 0 });
            i += 5;
        } else if c == 'n' {
            guard i + 4 <= n && s[i..i + 4] == "null" else { return fail(d, i, "invalid literal"); }
            d.tape.push(Val { head: K_NULL, data: 0 });
            i += 4;
        } else {
            let kind, bits, end = scan_number(s, i);
            if kind == NUM_BAD { return fail(d, end, if c == '-' || (c >= '0' && c <= '9') { "invalid number" } else { "unexpected character" }); }
            d.tape.push(Val { head: (K_INT + kind) as u64, data: bits });
            i = end;
        }
        // After a value: a comma and the next, or the end of containers.
        loop {
            count += 1;
            i = skip_ws(s, i);
            if cur < 0 {
                guard i == n else { return fail(d, i, "unexpected text after the value"); }
                return true;
            }
            guard i < n else { return fail(d, i, "unexpected end of input"); }
            let c2 = s[i];
            if c2 == ',' {
                i = skip_ws(s, i + 1);
                if obj {
                    i = parse_key(d, i, esc);
                    if i < 0 { return false; }
                }
                break;
            }
            guard c2 == (if obj { '}' } else { ']' }) else {
                return fail(d, i, if obj { "expected ',' or '}'" } else { "expected ',' or ']'" });
            }
            d.tape[cur].head = d.tape[cur].head | ((count as u64) << 8);
            d.tape[cur].data = d.tape.len as u64;
            let o = opens.pop();
            cur = o.at;
            count = o.count;
            obj = o.obj;
            i += 1;
        }
    }
    return true;
}

// A key at i, its colon and the space after: the next value's position.
fn parse_key(d: Doc&, at: i64, esc: u8[>..]&) -> i64 {
    let s = d.src;
    guard at < s.len && s[at] == '"' else { fail(d, at, "expected a string key"); return -1; }
    var i = parse_string(d, at, esc);
    if i < 0 { return -1; }
    i = skip_ws(s, i);
    guard i < s.len && s[i] == ':' else { fail(d, i, "expected ':'"); return -1; }
    return skip_ws(s, i + 1);
}

// The first byte at or after `at` that is not JSON whitespace. Spaces go
// a byte at a time, which branch prediction makes cheap for an indent;
// after a line break, a deep indent goes eight spaces at a time.
fn skip_ws(s: const u8[:], at: i64) -> i64 {
    var i = at;
    while i < s.len {
        let c = s[i];
        if c == ' ' { i += 1; continue; }
        if c != '\n' && c != '\r' && c != '\t' { return i; }
        i += 1;
        while i + 8 <= s.len && load8(s, i) == 0x2020202020202020 { i += 8; }
    }
    return i;
}

// The string whose opening quote is at s[at]: its entry, and the byte
// after its closing quote; -1 on an error. The scan stops only at a quote,
// a backslash or a control character; a string with bytes from 0x80 up is
// then checked as UTF-8 whole.
fn parse_string(d: Doc&, at: i64, esc: u8[>..]&) -> i64 {
    let s = d.src;
    let start = at + 1;
    var i = start;
    var high: u64 = 0;
    loop {
        while i + 8 <= s.len {
            let x = load8(s, i);
            let m = lanes_eq(x, '"') | lanes_eq(x, '\\') | lanes_lt(x, 0x20);
            high = high | x;
            if m != 0 { i += first_lane(m); break; }
            i += 8;
        }
        guard i < s.len else { fail(d, at, "unterminated string"); return -1; }
        let c = s[i];
        if c == '"' {
            if high & HIGHS != 0 && !utf8_valid(s[start..i]) { fail(d, start + utf8_error(s[start..i]), "invalid UTF-8"); return -1; }
            d.tape.push(Val { head: K_STRING | (((i - start) as u64) << 8), data: start as u64 });
            return i + 1;
        }
        if c == '\\' { return parse_escaped(d, at, i, esc); }
        if c < 0x20 { fail(d, i, "control character in string"); return -1; }
        high = high | c;
        i += 1;
    }
    return -1;
}

// Whether s is valid UTF-8: ASCII eight bytes at a time, the rest through
// the DFA.
fn utf8_valid(s: const u8[:]) -> bool {
    var st: u64 = 0;
    var i = 0;
    while i < s.len {
        if st == 0 {
            while i + 8 <= s.len && load8(s, i) & HIGHS == 0 { i += 8; }
            if i >= s.len { break; }
        }
        st = (UTF8_DFA[s[i]] >> st) & 63;
        i += 1;
    }
    return st == 0;
}

// Where in s, which is not valid UTF-8, the first bad sequence starts.
fn utf8_error(s: const u8[:]) -> i64 {
    var i = 0;
    while i < s.len {
        if s[i] < 0x80 { i += 1; continue; }
        let l = utf8_len(s, i);
        if l == 0 { return i; }
        i += l;
    }
    return s.len;
}

// The length of the UTF-8 sequence at s[i], whose first byte is 0x80 or
// above, or 0 if it is not a valid one (RFC 3629: no overlong forms, no
// surrogates, nothing above U+10FFFF).
fn utf8_len(s: const u8[:], i: i64) -> i64 {
    let c0 = s[i];
    let n = s.len - i;
    if c0 < 0xc2 || c0 > 0xf4 { return 0; }
    if n < 2 || s[i + 1] & 0xc0 != 0x80 { return 0; }
    let c1 = s[i + 1];
    if c0 < 0xe0 { return 2; }
    if n < 3 || s[i + 2] & 0xc0 != 0x80 { return 0; }
    if c0 == 0xe0 && c1 < 0xa0 { return 0; }
    if c0 == 0xed && c1 > 0x9f { return 0; }
    if c0 < 0xf0 { return 3; }
    if n < 4 || s[i + 3] & 0xc0 != 0x80 { return 0; }
    if c0 == 0xf0 && c1 < 0x90 { return 0; }
    if c0 == 0xf4 && c1 > 0x8f { return 0; }
    return 4;
}

fn hex4(s: const u8[:], at: i64) -> i64 {
    if at + 4 > s.len { return -1; }
    var v = 0;
    for c in s[at..at + 4] {
        var h = 0;
        if c >= '0' && c <= '9' { h = c - '0'; }
        else if c >= 'a' && c <= 'f' { h = c - 'a' + 10; }
        else if c >= 'A' && c <= 'F' { h = c - 'A' + 10; }
        else { return -1; }
        v = v * 16 + h;
    }
    return v;
}

fn put_utf8(out: u8[>..]&, cp: i64) {
    if cp < 0x80 { out.push(cp as u8); }
    else if cp < 0x800 { out.push((0xc0 | (cp >> 6)) as u8); out.push((0x80 | (cp & 0x3f)) as u8); }
    else if cp < 0x10000 {
        out.push((0xe0 | (cp >> 12)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3f)) as u8);
        out.push((0x80 | (cp & 0x3f)) as u8);
    } else {
        out.push((0xf0 | (cp >> 18)) as u8);
        out.push((0x80 | ((cp >> 12) & 0x3f)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3f)) as u8);
        out.push((0x80 | (cp & 0x3f)) as u8);
    }
}

// The rest of a string from its first backslash, at s[at]: unescaped into
// the text area.
fn parse_escaped(d: Doc&, quote: i64, at: i64, esc: u8[>..]&) -> i64 {
    let off = esc.len;
    let end = unescape(d.src, quote, at, esc, d.error);
    if end < 0 { return -1; }
    d.tape.push(Val { head: K_STRING | F_ESC | (((esc.len - off) as u64) << 8), data: off as u64 });
    return end + 1;
}

// Appends to `out` the text of the string whose opening quote is at
// s[quote], checking it, from its first backslash at s[at] (or any byte of
// it before one): returns the index of its closing quote, or -1 with `e`
// set.
fn unescape(s: const u8[:], quote: i64, at: i64, out: u8[>..]&, e: Error&) -> i64 {
    out.append(s[quote + 1..at]);
    var i = at;
    loop {
        // Copy the run up to the next quote, backslash, control or high byte.
        var j = i;
        while j < s.len {
            let c = s[j];
            if c == '"' || c == '\\' || c < 0x20 || c >= 0x80 { break; }
            j += 1;
        }
        out.append(s[i..j]);
        i = j;
        guard i < s.len else { e.error(quote, "unterminated string"); return -1; }
        let c = s[i];
        if c == '"' { return i; }
        if c < 0x20 { e.error(i, "control character in string"); return -1; }
        if c >= 0x80 {
            let l = utf8_len(s, i);
            if l == 0 { e.error(i, "invalid UTF-8"); return -1; }
            out.append(s[i..i + l]);
            i += l;
            continue;
        }
        // A backslash.
        guard i + 1 < s.len else { e.error(quote, "unterminated string"); return -1; }
        let x = s[i + 1];
        if x == '"' || x == '\\' || x == '/' { out.push(x); i += 2; }
        else if x == 'n' { out.push('\n'); i += 2; }
        else if x == 't' { out.push('\t'); i += 2; }
        else if x == 'r' { out.push('\r'); i += 2; }
        else if x == 'b' { out.push(8); i += 2; }
        else if x == 'f' { out.push(12); i += 2; }
        else if x == 'u' {
            var cp = hex4(s, i + 2);
            if cp < 0 { e.error(i, "invalid \\u escape"); return -1; }
            i += 6;
            if cp >= 0xd800 && cp <= 0xdbff {
                guard i + 1 < s.len && s[i] == '\\' && s[i + 1] == 'u' else { e.error(i, "unpaired surrogate"); return -1; }
                let lo = hex4(s, i + 2);
                guard lo >= 0xdc00 && lo <= 0xdfff else { e.error(i, "unpaired surrogate"); return -1; }
                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                i += 6;
            } else if cp >= 0xdc00 && cp <= 0xdfff {
                e.error(i - 6, "unpaired surrogate");
                return -1;
            }
            put_utf8(out, cp);
        } else {
            e.error(i, "invalid escape");
            return -1;
        }
    }
    return -1;
}

// --- reading -----------------------------------------------------------------------

fn ::ok(d: const json::Doc&) -> bool { d.error.ok }

// The document's value: missing if it did not parse.
fn ::root(d: const json::Doc&) -> json::Value {
    json::Value { doc: d, entry: if d.error.ok && d.ntape > 0 { 0 } else { -1 } }
}

fn ::kind(v: json::Value) -> i64 {
    if v.entry < 0 { return json::K_MISSING; }
    return (v.doc.tape[v.entry].head & 15) as i64;
}

fn ::exists(v: json::Value) -> bool { v.entry >= 0 }
fn ::is_null(v: json::Value) -> bool { v.kind() == json::K_NULL }
fn ::is_string(v: json::Value) -> bool { v.kind() == json::K_STRING }
fn ::is_number(v: json::Value) -> bool { let k = v.kind(); k == json::K_INT || k == json::K_UINT || k == json::K_FLOAT }
fn ::is_array(v: json::Value) -> bool { v.kind() == json::K_ARRAY }
fn ::is_object(v: json::Value) -> bool { v.kind() == json::K_OBJECT }
fn ::is_bool(v: json::Value) -> bool { let k = v.kind(); k == json::K_TRUE || k == json::K_FALSE }

// The entry after entry i and everything in it.
fn next(d: const Doc&, i: i64) -> i64 {
    let h = d.tape[i].head & 15;
    if h >= K_ARRAY { return d.tape[i].data as i64; }
    return i + 1;
}

// The text of the string at entry i.
fn text_of(d: const Doc&, i: i64) -> const u8[:] {
    let h = d.tape[i].head;
    let len = (h >> 8) as i64;
    let at = d.tape[i].data as i64;
    if h & F_ESC != 0 { return bytes_of(d.tape[d.ntape..])[at..at + len]; }
    return d.src[at..at + len];
}

// Items of an array, members of an object; 0 for anything else.
fn ::count(v: json::Value) -> i64 {
    let k = v.kind();
    if k != json::K_ARRAY && k != json::K_OBJECT { return 0; }
    return (v.doc.tape[v.entry].head >> 8) as i64;
}

// The value of an object's first member with this key.
fn ::get(v: json::Value, key: const u8[:]) -> json::Value {
    if v.kind() != json::K_OBJECT { return json::Value { doc: v.doc, entry: -1 }; }
    let d = v.doc;
    let end = d.tape[v.entry].data as i64;
    var i = v.entry + 1;
    let want: u64 = (key.len as u64) << 8;
    while i < end {
        let h = d.tape[i].head;
        if h & 0xffffffffffffff00 == want && json::text_of(d, i) == key { return json::Value { doc: d, entry: i + 1 }; }
        i = json::next(d, i + 1);
    }
    return json::Value { doc: d, entry: -1 };
}

// An array's item.
fn ::at(v: json::Value, index: i64) -> json::Value {
    if v.kind() != json::K_ARRAY || index < 0 { return json::Value { doc: v.doc, entry: -1 }; }
    let d = v.doc;
    let end = d.tape[v.entry].data as i64;
    var i = v.entry + 1;
    var k = 0;
    while i < end {
        if k == index { return json::Value { doc: d, entry: i }; }
        i = json::next(d, i);
        k += 1;
    }
    return json::Value { doc: d, entry: -1 };
}

// Each item of an array, in order: `v.each() { x => … }`.
fn ::each<F>(v: json::Value) {
    if v.kind() != json::K_ARRAY { return; }
    let d = v.doc;
    let end = d.tape[v.entry].data as i64;
    var i = v.entry + 1;
    while i < end {
        F(json::Value { doc: d, entry: i });
        i = json::next(d, i);
    }
}

// Each member of an object, in order: `v.members() { k, x => … }`.
fn ::members<F>(v: json::Value) {
    if v.kind() != json::K_OBJECT { return; }
    let d = v.doc;
    let end = d.tape[v.entry].data as i64;
    var i = v.entry + 1;
    while i < end {
        F(json::text_of(d, i), json::Value { doc: d, entry: i + 1 });
        i = json::next(d, i + 1);
    }
}

// The scalars, each with whether the value was one: a number of another
// kind converts (an integer to a double, a whole double in range to an
// integer); anything else gives the default and false.
fn ::try_int(v: json::Value) -> i64, bool {
    let k = v.kind();
    if k == json::K_INT { return v.doc.tape[v.entry].data as! i64, true; }
    if k == json::K_FLOAT {
        let x = json::f64_of(v.doc.tape[v.entry].data);
        if x >= -9223372036854775808.0 && x < 9223372036854775808.0 && x == floor(x) { return x as! i64, true; }
    }
    return 0, false;
}

fn ::try_uint(v: json::Value) -> u64, bool {
    let k = v.kind();
    if k == json::K_UINT || (k == json::K_INT && v.doc.tape[v.entry].data >> 63 == 0) { return v.doc.tape[v.entry].data, true; }
    return 0, false;
}

fn ::try_float(v: json::Value) -> f64, bool {
    let k = v.kind();
    if k == json::K_FLOAT { return json::f64_of(v.doc.tape[v.entry].data), true; }
    if k == json::K_INT { return v.doc.tape[v.entry].data as! i64, true; }
    if k == json::K_UINT { return v.doc.tape[v.entry].data, true; }
    return 0.0, false;
}

fn ::try_string(v: json::Value) -> const u8[:], bool {
    if v.kind() == json::K_STRING { return json::text_of(v.doc, v.entry), true; }
    return "", false;
}

fn ::try_boolean(v: json::Value) -> bool, bool {
    let k = v.kind();
    if k == json::K_TRUE { return true, true; }
    if k == json::K_FALSE { return false, true; }
    return false, false;
}

fn ::int(v: json::Value) -> i64 { let x, ok = v.try_int(); return x; }
fn ::uint(v: json::Value) -> u64 { let x, ok = v.try_uint(); return x; }
fn ::float(v: json::Value) -> f64 { let x, ok = v.try_float(); return x; }
fn ::string(v: json::Value) -> const u8[:] { let x, ok = v.try_string(); return x; }
fn ::boolean(v: json::Value) -> bool { let x, ok = v.try_boolean(); return x; }

// --- writing a value back out --------------------------------------------------------

struct Close { end: i64, obj: bool }

// A value of a document, written through a writer: a whole document is
// re-serialized compactly (or pretty printed, by a pretty writer).
fn ::value<A>(w: json::Writer<A>&, v: json::Value) {
    guard v.entry >= 0 else { w.none(); return; }
    let d = v.doc;
    var closes: json::Close[>..<] = [];
    let base = 0;
    let end = json::next(d, v.entry);
    var i = v.entry;
    while i < end {
        // Close what ends here.
        while closes.len > base && closes[closes.len - 1].end == i {
            let c = closes.pop();
            json::close(w, if c.obj { '}' } else { ']' });
        }
        let inobj = closes.len > base && closes[closes.len - 1].obj;
        if inobj {
            w.key(json::text_of(d, i));
            i += 1;
        }
        let h = d.tape[i].head;
        let k = (h & 15) as i64;
        if k == json::K_OBJECT || k == json::K_ARRAY {
            json::open(w, if k == json::K_OBJECT { '{' } else { '[' });
            closes.push(json::Close { end: d.tape[i].data as i64, obj: k == json::K_OBJECT });
        } else if k == json::K_STRING { w.string(json::text_of(d, i)); }
        else if k == json::K_INT { w.int(d.tape[i].data as! i64); }
        else if k == json::K_UINT { w.uint(d.tape[i].data); }
        else if k == json::K_FLOAT { w.float(json::f64_of(d.tape[i].data)); }
        else if k == json::K_TRUE { w.boolean(true); }
        else if k == json::K_FALSE { w.boolean(false); }
        else { w.none(); }
        i += 1;
    }
    while closes.len > base {
        let c = closes.pop();
        json::close(w, if c.obj { '}' } else { ']' });
    }
}
