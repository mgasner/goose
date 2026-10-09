// The cursor: a structural index of the text, built in one pass, and lazy
// values that walk it. Nothing is parsed until it is read, and a value that
// is skipped costs only the walk over its index entries.
//
//     var c = json::cursor(text);
//     let q = c.root().get("query").string();
//
// Stage 1 is simdjson's, in SWAR: each 64-byte block becomes 64-bit masks
// of quotes, backslashes, structural characters and whitespace; escaped
// quotes are removed, the inside of strings is the prefix XOR of the
// quotes, and the positions of structural characters outside strings, of
// both quotes of every string and of the first byte of every other scalar
// are appended to the index.
//
// A cursor checks what it reads. A value it only skips is checked for no
// more than the brackets that bound it, as simdjson's On-Demand API does;
// use a document (json::parse) where the whole text must be valid.

namespace json;

import std;

// --- stage 1 ----------------------------------------------------------------------------

// Lanes of y that are zero, exactly: no borrow crosses lanes.
fn zero_lanes(y: u64) -> u64 { ~(((y & 0x7f7f7f7f7f7f7f7f) + 0x7f7f7f7f7f7f7f7f) | y) & HIGHS }
fn eq_lanes(x: u64, c: u64) -> u64 { zero_lanes(x ^ (c * ONES)) }

// A lane mask to one bit per lane, lane 0 in bit 0.
fn gather(m: u64) -> u64 { ((m >> 7) * 0x0102040810204080) >> 56 }

// The prefix XOR of x: bit i is the XOR of bits 0..i.
fn prefix_xor(x: u64) -> u64 {
    var p = x;
    p = p ^ (p << 1);
    p = p ^ (p << 2);
    p = p ^ (p << 4);
    p = p ^ (p << 8);
    p = p ^ (p << 16);
    p = p ^ (p << 32);
    return p;
}

let EVEN_BITS: u64 = 0x5555555555555555;

// What one block hands the next.
struct Stage1 { odd_bs: u64 = 0, in_string: u64 = 0, scalar: u64 = 0 }

// Indexes the 64 bytes of `b64`, which start at byte `base` of the text.
fn index_block(b64: const u8[:], base: i64, st: Stage1&, out: u32[>..]&) {
    var q: u64 = 0;
    var bs: u64 = 0;
    var op: u64 = 0;
    var ws: u64 = 0;
    for k in 8 {
        let x = load8(b64, 8 * k);
        let lo = x | 0x2020202020202020;        // '[' and ']' to '{' and '}'
        let sh = 8 * k;
        q = q | (gather(eq_lanes(x, '"')) << sh);
        bs = bs | (gather(eq_lanes(x, '\\')) << sh);
        op = op | (gather(eq_lanes(lo, '{') | eq_lanes(lo, '}') | eq_lanes(x, ':') | eq_lanes(x, ',')) << sh);
        ws = ws | (gather(eq_lanes(x, ' ') | eq_lanes(x, '\n') | eq_lanes(x, '\r') | eq_lanes(x, '\t')) << sh);
    }
    // The bytes escaped by a backslash: those after an odd-length run.
    let starts = bs & ~(bs << 1);
    let even_start = EVEN_BITS ^ st.odd_bs;
    let even_starts = starts & even_start;
    let odd_starts = starts & ~even_start;
    let even_carries = bs + even_starts;
    var odd_carries = bs + odd_starts;
    let carry_out: u64 = if odd_carries < bs { 1 } else { 0 };
    odd_carries = odd_carries | st.odd_bs;
    st.odd_bs = carry_out;
    let escaped = ((even_carries & ~bs) & ~EVEN_BITS) | ((odd_carries & ~bs) & EVEN_BITS);
    // The real quotes, and the inside of strings from each opening quote up
    // to its closing one.
    let quotes = q & ~escaped;
    let inside = prefix_xor(quotes) ^ st.in_string;
    st.in_string = 0 - (inside >> 63);
    // The first byte of each scalar: one that is not structure, space or
    // string, after one that is.
    let scalar = ~(op | ws | quotes | inside);
    let starts_scalar = scalar & ~((scalar << 1) | st.scalar);
    st.scalar = scalar >> 63;
    var bits = (op & ~inside) | quotes | starts_scalar;
    while bits != 0 {
        out.push((base + ctz64(bits)) as u32);
        bits = bits & (bits - 1);
    }
}

// Appends the index of `s` to `out`; false if a string is not closed.
fn index(s: const u8[:], out: u32[>..]&) -> bool {
    var st = Stage1 {};
    var b = 0;
    while b + 64 <= s.len {
        index_block(s[b..b + 64], b, st, out);
        b += 64;
    }
    if b < s.len {
        // The last part, padded with spaces, which add nothing.
        var last = default<u8[64]>();
        for i in 64 { last[i] = ' '; }
        for i in s.len - b { last[i] = s[b + i]; }
        index_block(last, b, st, out);
    }
    return st.in_string == 0;
}

// --- the cursor -------------------------------------------------------------------------

// The text, its index (the first `nix` words of `buf`), and the strings
// with escapes read so far, unescaped, in the words after it.
struct Cursor {
    src: const u8[:],
    nix: i64 = 0,
    error: Error = Error {},
    buf: u32[>..],
}

// A value of a cursor: the index entry it starts at, or -1 if it is not
// there.
struct Lazy { c: Cursor&, p: i64 }

fn cursor(src: const u8[:]) -> Cursor {
    var c = Cursor { src: src, buf: [] };
    if !index(src, c.buf) {
        c.error.error(src.len, "unterminated string");
        return c;
    }
    c.nix = c.buf.len;
    if c.nix == 0 { c.error.error(0, "no value"); return c; }
    // Nothing may follow the root: it must end at the last entry, which
    // counting brackets finds.
    if skip(c, 0) != c.nix { c.error.error(c.buf[c.nix - 1], "unexpected text after the value"); }
    return c;
}

fn ::ok(c: const json::Cursor&) -> bool { c.error.ok }

fn ::root(c: json::Cursor&) -> json::Lazy { json::Lazy { c: c, p: if c.error.ok { 0 } else { -1 } } }

// Where index entry p is in the text: the text's end past the last entry.
fn pos(c: const Cursor&, p: i64) -> i64 {
    if p >= 0 && p < c.nix { return c.buf[p]; }
    return c.src.len;
}

fn byte_at(c: const Cursor&, p: i64) -> u8 {
    let x = pos(c, p);
    if x < c.src.len { return c.src[x]; }
    return 0;
}

// The entry after the value at entry p.
fn skip(c: const Cursor&, p: i64) -> i64 {
    let b = byte_at(c, p);
    if b == '"' { return p + 2; }
    if b != '{' && b != '[' { return p + 1; }
    var depth = 1;
    var k = p + 1;
    while k < c.nix {
        let x = c.src[c.buf[k] as i64];
        if x == '{' || x == '[' { depth += 1; }
        else if x == '}' || x == ']' {
            depth -= 1;
            if depth == 0 { return k + 1; }
        }
        k += 1;
    }
    return k;
}

fn missing(c: Cursor&) -> Lazy { Lazy { c: c, p: -1 } }

fn bad(c: Cursor&, p: i64, message: const u8[:]) -> Lazy {
    c.error.error(pos(c, p), message);
    return Lazy { c: c, p: -1 };
}

// The text of the key or string at entry p, unescaped if it must be.
fn string_at(c: Cursor&, p: i64) -> const u8[:], bool {
    let from = pos(c, p);
    let to = pos(c, p + 1);
    let raw = c.src[from + 1..to];
    // Eight bytes at a time to the first backslash or control character.
    var i = 0;
    var high: u64 = 0;
    while i + 8 <= raw.len {
        let x = load8(raw, i);
        high = high | x;
        if lanes_eq(x, '\\') | lanes_lt(x, 0x20) != 0 { break; }
        i += 8;
    }
    var plain = true;
    while i < raw.len {
        let b = raw[i];
        if b == '\\' { plain = false; break; }
        if b < 0x20 { c.error.error(from + 1 + i, "control character in string"); return "", false; }
        high = high | b;
        i += 1;
    }
    if plain {
        if high & HIGHS != 0 && !utf8_valid(raw) { c.error.error(from + 1 + utf8_error(raw), "invalid UTF-8"); return "", false; }
        return raw, true;
    }
    // Unescaped into the words after the index; they never move.
    var t: u8[>..] = [];
    let end = unescape(c.src, from, from + 1, t, c.error);
    if end < 0 { return "", false; }
    let n = t.len;
    while t.len % 4 != 0 { t.push(0); }
    let at = c.buf.len;
    var k = 0;
    while k < t.len {
        c.buf.push(t[k] | (t[k + 1] as u32 << 8) | (t[k + 2] as u32 << 16) | (t[k + 3] as u32 << 24));
        k += 4;
    }
    return bytes_of(c.buf[at..])[0..n], true;
}

// The text of the scalar at entry p, up to the next entry, without the
// whitespace before it.
fn scalar_text(c: const Cursor&, p: i64) -> const u8[:] {
    let from = pos(c, p);
    var to = pos(c, p + 1);
    while to > from && (c.src[to - 1] == ' ' || c.src[to - 1] == '\n' || c.src[to - 1] == '\r' || c.src[to - 1] == '\t') { to -= 1; }
    return c.src[from..to];
}

fn ::exists(v: json::Lazy) -> bool { v.p >= 0 }

fn ::kind(v: json::Lazy) -> i64 {
    if v.p < 0 { return json::K_MISSING; }
    let b = json::byte_at(v.c, v.p);
    if b == '{' { return json::K_OBJECT; }
    if b == '[' { return json::K_ARRAY; }
    if b == '"' { return json::K_STRING; }
    let t = json::scalar_text(v.c, v.p);
    if b == 't' { return if t == "true" { json::K_TRUE } else { json::K_MISSING }; }
    if b == 'f' { return if t == "false" { json::K_FALSE } else { json::K_MISSING }; }
    if b == 'n' { return if t == "null" { json::K_NULL } else { json::K_MISSING }; }
    let kind, bits, end = json::scan_number(t, 0);
    if kind == json::NUM_BAD || end != t.len { return json::K_MISSING; }
    return json::K_INT + kind;
}

fn ::is_null(v: json::Lazy) -> bool { v.p >= 0 && json::byte_at(v.c, v.p) == 'n' && json::scalar_text(v.c, v.p) == "null" }
fn ::is_object(v: json::Lazy) -> bool { v.p >= 0 && json::byte_at(v.c, v.p) == '{' }
fn ::is_array(v: json::Lazy) -> bool { v.p >= 0 && json::byte_at(v.c, v.p) == '[' }
fn ::is_string(v: json::Lazy) -> bool { v.p >= 0 && json::byte_at(v.c, v.p) == '"' }

// The value of an object's first member with this key.
fn ::get(v: json::Lazy, key: const u8[:]) -> json::Lazy {
    let c = v.c;
    guard v.p >= 0 && json::byte_at(c, v.p) == '{' else { return json::missing(c); }
    var p = v.p + 1;
    if json::byte_at(c, p) == '}' { return json::missing(c); }
    loop {
        guard json::byte_at(c, p) == '"' else { return json::bad(c, p, "expected a string key"); }
        guard json::byte_at(c, p + 2) == ':' else { return json::bad(c, p + 2, "expected ':'"); }
        // A key without escapes compares as it is.
        let raw = c.src[json::pos(c, p) + 1..json::pos(c, p + 1)];
        var hit = raw == key;
        if !hit && raw.len >= key.len && position(raw, '\\') >= 0 {
            let k, ok = json::string_at(c, p);
            hit = ok && k == key;
        }
        if hit { return json::Lazy { c: c, p: p + 3 }; }
        p = json::skip(c, p + 3);
        let b = json::byte_at(c, p);
        if b == '}' { return json::missing(c); }
        guard b == ',' else { return json::bad(c, p, "expected ',' or '}'"); }
        p += 1;
    }
    return json::missing(c);
}

// An array's item.
fn ::at(v: json::Lazy, index: i64) -> json::Lazy {
    let c = v.c;
    guard v.p >= 0 && json::byte_at(c, v.p) == '[' && index >= 0 else { return json::missing(c); }
    var p = v.p + 1;
    if json::byte_at(c, p) == ']' { return json::missing(c); }
    var k = 0;
    loop {
        if k == index { return json::Lazy { c: c, p: p }; }
        p = json::skip(c, p);
        let b = json::byte_at(c, p);
        if b == ']' { return json::missing(c); }
        guard b == ',' else { return json::bad(c, p, "expected ',' or ']'"); }
        p += 1;
        k += 1;
    }
    return json::missing(c);
}

// Each item of an array, in order: `v.each() { x => … }`.
fn ::each<F>(v: json::Lazy) {
    let c = v.c;
    guard v.p >= 0 && json::byte_at(c, v.p) == '[' else { return; }
    var p = v.p + 1;
    if json::byte_at(c, p) == ']' { return; }
    loop {
        F(json::Lazy { c: c, p: p });
        p = json::skip(c, p);
        let b = json::byte_at(c, p);
        if b == ']' { return; }
        guard b == ',' else { json::bad(c, p, "expected ',' or ']'"); return; }
        p += 1;
    }
}

// Each member of an object, in order: `v.members() { k, x => … }`.
fn ::members<F>(v: json::Lazy) {
    let c = v.c;
    guard v.p >= 0 && json::byte_at(c, v.p) == '{' else { return; }
    var p = v.p + 1;
    if json::byte_at(c, p) == '}' { return; }
    loop {
        guard json::byte_at(c, p) == '"' else { json::bad(c, p, "expected a string key"); return; }
        guard json::byte_at(c, p + 2) == ':' else { json::bad(c, p + 2, "expected ':'"); return; }
        let k, ok = json::string_at(c, p);
        if !ok { return; }
        F(k, json::Lazy { c: c, p: p + 3 });
        p = json::skip(c, p + 3);
        let b = json::byte_at(c, p);
        if b == '}' { return; }
        guard b == ',' else { json::bad(c, p, "expected ',' or '}'"); return; }
        p += 1;
    }
}

// Items of an array or members of an object, counted by walking them.
fn ::count(v: json::Lazy) -> i64 {
    var n = 0;
    if v.is_array() { v.each() { x => n += 1; }; }
    else if v.is_object() { v.members() { k, x => n += 1; }; }
    return n;
}

// The value's own text, exactly as it appears in the source.
fn ::raw(v: json::Lazy) -> const u8[:] {
    if v.p < 0 { return ""; }
    let c = v.c;
    let b = json::byte_at(c, v.p);
    if b == '"' { return c.src[json::pos(c, v.p)..json::pos(c, v.p + 1) + 1]; }
    if b == '{' || b == '[' { return c.src[json::pos(c, v.p)..json::pos(c, json::skip(c, v.p) - 1) + 1]; }
    return json::scalar_text(c, v.p);
}

fn ::try_string(v: json::Lazy) -> const u8[:], bool {
    if v.p < 0 || json::byte_at(v.c, v.p) != '"' { return "", false; }
    return json::string_at(v.c, v.p);
}

// The number at v: its kind and bits as a document stores them.
fn number_at(v: Lazy) -> i64, u64 {
    if v.p < 0 { return NUM_BAD, 0; }
    let b = byte_at(v.c, v.p);
    if b != '-' && (b < '0' || b > '9') { return NUM_BAD, 0; }
    let t = scalar_text(v.c, v.p);
    let kind, bits, end = scan_number(t, 0);
    if kind == NUM_BAD || end != t.len { v.c.error.error(pos(v.c, v.p), "invalid number"); return NUM_BAD, 0; }
    return kind, bits;
}

fn ::try_int(v: json::Lazy) -> i64, bool {
    let kind, bits = json::number_at(v);
    if kind == json::NUM_INT { return bits as! i64, true; }
    if kind == json::NUM_FLOAT {
        let x = json::f64_of(bits);
        if x >= -9223372036854775808.0 && x < 9223372036854775808.0 && x == floor(x) { return x as! i64, true; }
    }
    return 0, false;
}

fn ::try_uint(v: json::Lazy) -> u64, bool {
    let kind, bits = json::number_at(v);
    if kind == json::NUM_UINT || (kind == json::NUM_INT && bits >> 63 == 0) { return bits, true; }
    return 0, false;
}

fn ::try_float(v: json::Lazy) -> f64, bool {
    let kind, bits = json::number_at(v);
    if kind == json::NUM_FLOAT { return json::f64_of(bits), true; }
    if kind == json::NUM_INT { return bits as! i64, true; }
    if kind == json::NUM_UINT { return bits, true; }
    return 0.0, false;
}

fn ::try_boolean(v: json::Lazy) -> bool, bool {
    if v.p < 0 { return false, false; }
    let t = json::scalar_text(v.c, v.p);
    if t == "true" { return true, true; }
    if t == "false" { return false, true; }
    return false, false;
}

fn ::int(v: json::Lazy) -> i64 { let x, ok = v.try_int(); return x; }
fn ::uint(v: json::Lazy) -> u64 { let x, ok = v.try_uint(); return x; }
fn ::float(v: json::Lazy) -> f64 { let x, ok = v.try_float(); return x; }
fn ::string(v: json::Lazy) -> const u8[:] { let x, ok = v.try_string(); return x; }
fn ::boolean(v: json::Lazy) -> bool { let x, ok = v.try_boolean(); return x; }
