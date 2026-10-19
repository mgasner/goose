// The reader: one forward pass over the text, reading values as the
// program asks for them, with nothing built and no index.
//
//     var r = json::reader(text);
//     r.members() { k =>
//         if k == "x" { x = r.float(); }      // a member not read is skipped
//     };
//     guard r.finish() else { ... r.error ... }
//
// A read takes the value at the reader and moves past it. A read of the
// wrong kind leaves the value where it is and gives the default, as a
// document's values do; inside `members` and `each`, a value the block did
// not take is skipped. Skipping checks the value as fully as `parse` does
// -- grammar, UTF-8, escapes, depth -- so a program that reads with a
// reader and ends with `finish` has checked the whole text, exactly as
// strictly as a document would. An error stops the reader: the first one
// is kept in `error`, and every read after it gives the default.

namespace json;

import std;

struct Reader {
    src: const u8[:],
    pos: i64 = 0,
    depth: i64 = 0,           // containers open around the reader
    root: i64 = -1,           // where the root value starts, once seen
    error: Error = Error {},
    text: u8[>..],            // strings with escapes, unescaped; never moves
}

fn reader(src: const u8[:]) -> Reader { Reader { src: src, text: [] } }

fn ::ok(r: const json::Reader&) -> bool { r.error.ok }

// Records the first error and moves to the end, so that every read after
// it finds nothing and every loop ends.
fn stop(r: Reader&, at: i64, message: const u8[:]) {
    r.error.error(at, message);
    r.pos = r.src.len;
}

// The first byte of the next value, not consumed; 0 at the end, after an
// error, or past the root value. Inside a container, with no space before
// the value, that is one load.
inline fn next_byte(r: Reader&) -> u8 {
    let s = r.src;
    let i = r.pos;
    if r.depth > 0 && i < s.len && s[i] > ' ' { return s[i]; }
    return next_byte_slow(r);
}

// skip_ws, with no call when no space comes first, as is usual in text
// that is not pretty printed.
inline fn ws(s: const u8[:], at: i64) -> i64 {
    if at < s.len && s[at] > ' ' { return at; }
    return skip_ws(s, at);
}

fn next_byte_slow(r: Reader&) -> u8 {
    let s = r.src;
    r.pos = skip_ws(s, r.pos);
    if r.pos >= s.len { return 0; }
    if r.depth == 0 {
        if r.root < 0 { r.root = r.pos; }
        else if r.pos != r.root { stop(r, r.pos, "unexpected text after the value"); return 0; }
    }
    return s[r.pos];
}

// --- checking without building ----------------------------------------------------------

// The end of the number at s[at], checked against the grammar, or -1.
fn number_end(s: const u8[:], at: i64) -> i64 {
    let n = s.len;
    var p = at;
    if p < n && s[p] == '-' { p += 1; }
    if p < n && s[p] == '0' { p += 1; }
    else {
        let first = p;
        while p < n && s[p] - '0' <= 9 { p += 1; }
        if p == first { return -1; }
    }
    if p < n && s[p] == '.' {
        p += 1;
        let first = p;
        while p < n && s[p] - '0' <= 9 { p += 1; }
        if p == first { return -1; }
    }
    if p < n && (s[p] | 0x20) == 'e' {
        p += 1;
        if p < n && (s[p] == '-' || s[p] == '+') { p += 1; }
        let first = p;
        while p < n && s[p] - '0' <= 9 { p += 1; }
        if p == first { return -1; }
    }
    return p;
}

// The string whose opening quote is at s[at], checked up to its first
// backslash: the index of its closing quote, or of that backslash with
// true; -1 with e set if it is malformed before either. The scan is the
// document's: eight bytes at a time to a quote, backslash or control
// character, with UTF-8 checked whole at the end if any byte was high.
fn string_scan(s: const u8[:], at: i64, e: Error&) -> i64, bool {
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
        guard i < s.len else { e.error(at, "unterminated string"); return -1, false; }
        let c = s[i];
        if c == '"' {
            if high & HIGHS != 0 && !utf8_valid(s[start..i]) { e.error(start + utf8_error(s[start..i]), "invalid UTF-8"); return -1, false; }
            return i, false;
        }
        if c == '\\' { return i, true; }
        if c < 0x20 { e.error(i, "control character in string"); return -1, false; }
        high = high | c;
        i += 1;
    }
    return -1, false;
}

// The index of the closing quote of the string at s[at], the whole of it
// checked; -1 with e set if it is malformed. A string with escapes is
// checked by unescaping it into a scratch array that is then dropped.
fn string_end(s: const u8[:], at: i64, e: Error&) -> i64 {
    let i, esc = string_scan(s, at, e);
    if !esc { return i; }
    var t: u8[>..] = [];
    return unescape(s, at, i, t, e);
}

// The string at the reader, whose first byte is a quote: its text, a view
// of the source or, if it has escapes, of the reader's own text.
fn take_string(r: Reader&) -> const u8[:], bool {
    let s = r.src;
    let at = r.pos;
    let i, esc = string_scan(s, at, r.error);
    if i >= 0 && !esc { r.pos = i + 1; return s[at + 1..i], true; }
    if i >= 0 {
        let off = r.text.len;
        let end = unescape(s, at, i, r.text, r.error);
        if end >= 0 { r.pos = end + 1; return r.text[off..], true; }
    }
    r.pos = s.len;
    return "", false;
}

// The literal word at the reader, checked.
fn take_word(r: Reader&, w: const u8[:]) -> bool {
    let s = r.src;
    if r.pos + w.len <= s.len && s[r.pos..r.pos + w.len] == w { r.pos += w.len; return true; }
    stop(r, r.pos, "invalid literal");
    return false;
}

// Moves past the value at the reader, checking it. The containers inside
// it are tracked in a word of bits, a bit per level (set for an object),
// and past 64 levels on a stack.
fn ::skip(r: json::Reader&) {
    let s = r.src;
    var c = json::next_byte(r);
    if c == '"' {
        let end = json::string_end(s, r.pos, r.error);
        r.pos = if end < 0 { s.len } else { end + 1 };
        return;
    }
    if c != '{' && c != '[' { json::skip_scalar(r, c); return; }
    var low: u64 = 0;
    var high: bool[>..<] = [];
    var d = 0;
    var obj = false;
    var i = r.pos;
    loop {
        // A value starts at i, its first byte c.
        if c == '{' || c == '[' {
            guard r.depth + d < json::max_depth else { json::stop(r, i, "nesting too deep"); return; }
            obj = c == '{';
            if d < 64 { low = (low & ~(1 << d)) | ((if obj { 1 } else { 0 }) << d); } else { high.push(obj); }
            d += 1;
            i = json::ws(s, i + 1);
            if i < s.len && s[i] == (if obj { '}' } else { ']' }) {
                i += 1;
                d -= 1;
                if d >= 64 { high.pop(); }
                if d == 0 { r.pos = i; return; }
                obj = if d - 1 < 64 { (low >> (d - 1)) & 1 != 0 } else { high[high.len - 1] };
            } else if obj {
                guard i < s.len && s[i] == '"' else { json::stop(r, i, "expected a string key"); return; }
                let end = json::string_end(s, i, r.error);
                if end < 0 { r.pos = s.len; return; }
                i = json::ws(s, end + 1);
                guard i < s.len && s[i] == ':' else { json::stop(r, i, "expected ':'"); return; }
                i = json::ws(s, i + 1);
                guard i < s.len else { json::stop(r, i, "unexpected end of input"); return; }
                c = s[i];
                continue;
            } else {
                guard i < s.len else { json::stop(r, i, "unexpected end of input"); return; }
                c = s[i];
                continue;
            }
        } else if c == '"' {
            let end = json::string_end(s, i, r.error);
            if end < 0 { r.pos = s.len; return; }
            i = end + 1;
        } else {
            r.pos = i;
            json::skip_scalar(r, c);
            if !r.error.ok { return; }
            i = r.pos;
        }
        // After a value: a comma and the next, or the end of containers.
        loop {
            i = json::ws(s, i);
            guard i < s.len else { json::stop(r, i, "unexpected end of input"); return; }
            let c2 = s[i];
            if c2 == ',' {
                i = json::ws(s, i + 1);
                if obj {
                    guard i < s.len && s[i] == '"' else { json::stop(r, i, "expected a string key"); return; }
                    let end = json::string_end(s, i, r.error);
                    if end < 0 { r.pos = s.len; return; }
                    i = json::ws(s, end + 1);
                    guard i < s.len && s[i] == ':' else { json::stop(r, i, "expected ':'"); return; }
                    i = json::ws(s, i + 1);
                }
                guard i < s.len else { json::stop(r, i, "unexpected end of input"); return; }
                c = s[i];
                break;
            }
            guard c2 == (if obj { '}' } else { ']' }) else {
                json::stop(r, i, if obj { "expected ',' or '}'" } else { "expected ',' or ']'" });
                return;
            }
            i += 1;
            d -= 1;
            if d >= 64 { high.pop(); }
            if d == 0 { r.pos = i; return; }
            obj = if d - 1 < 64 { (low >> (d - 1)) & 1 != 0 } else { high[high.len - 1] };
        }
    }
}

// Moves past the literal or number at the reader, whose first byte is c.
fn skip_scalar(r: Reader&, c: u8) {
    if c == 't' { take_word(r, "true"); return; }
    if c == 'f' { take_word(r, "false"); return; }
    if c == 'n' { take_word(r, "null"); return; }
    if c == 0 && r.pos >= r.src.len { stop(r, r.pos, "unexpected end of input"); return; }
    let end = number_end(r.src, r.pos);
    if end < 0 {
        // Where it stops being a number, as parse reports it.
        let kind, bits, at = scan_number(r.src, r.pos);
        stop(r, at, if c == '-' || (c >= '0' && c <= '9') { "invalid number" } else { "unexpected character" });
        return;
    }
    r.pos = end;
}

// --- reading -------------------------------------------------------------------------

// The kind of the value at the reader, which stays where it is: K_MISSING
// at the end, after an error, or where no value starts. A number is
// scanned to tell K_INT, K_UINT and K_FLOAT apart.
fn ::kind(r: json::Reader&) -> i64 {
    let c = json::next_byte(r);
    if c == '{' { return json::K_OBJECT; }
    if c == '[' { return json::K_ARRAY; }
    if c == '"' { return json::K_STRING; }
    if c == 't' { return json::K_TRUE; }
    if c == 'f' { return json::K_FALSE; }
    if c == 'n' { return json::K_NULL; }
    if c == '-' || (c >= '0' && c <= '9') {
        let kind, bits, end = json::scan_number(r.src, r.pos);
        if kind != json::NUM_BAD { return json::K_INT + kind; }
    }
    return json::K_MISSING;
}

fn ::is_null(r: json::Reader&) -> bool { r.kind() == json::K_NULL }

// Each item of the array at the reader, in order: `r.each() { … }`. The
// block reads the item from r; an item it does not read is skipped. Not
// an array: nothing is read, and the block is not called.
fn ::each<F>(r: json::Reader&) {
    if json::next_byte(r) != '[' { return; }
    guard r.depth < json::max_depth else { json::stop(r, r.pos, "nesting too deep"); return; }
    let s = r.src;
    r.depth += 1;
    var i = json::ws(s, r.pos + 1);
    if i < s.len && s[i] == ']' { r.pos = i + 1; r.depth -= 1; return; }
    loop {
        r.pos = i;
        F();
        if r.pos == i { r.skip(); }
        i = json::ws(s, r.pos);
        guard i < s.len else { json::stop(r, i, "unexpected end of input"); return; }
        let c = s[i];
        if c == ',' { i = json::ws(s, i + 1); continue; }
        if c == ']' { r.pos = i + 1; r.depth -= 1; return; }
        json::stop(r, i, "expected ',' or ']'");
        return;
    }
}

// Each member of the object at the reader, in order: `r.members() { k => … }`.
// The block reads the member's value from r; a value it does not read is
// skipped. Keys are checked and unescaped as strings are. Not an object:
// nothing is read, and the block is not called.
fn ::members<F>(r: json::Reader&) {
    if json::next_byte(r) != '{' { return; }
    guard r.depth < json::max_depth else { json::stop(r, r.pos, "nesting too deep"); return; }
    let s = r.src;
    r.depth += 1;
    var i = json::ws(s, r.pos + 1);
    if i < s.len && s[i] == '}' { r.pos = i + 1; r.depth -= 1; return; }
    loop {
        guard i < s.len && s[i] == '"' else { json::stop(r, i, if i < s.len { "expected a string key" } else { "unexpected end of input" }); return; }
        r.pos = i;
        let k, ok = json::take_string(r);
        if !ok { return; }
        i = json::ws(s, r.pos);
        guard i < s.len && s[i] == ':' else { json::stop(r, i, "expected ':'"); return; }
        i = json::ws(s, i + 1);
        r.pos = i;
        F(k);
        if r.pos == i { r.skip(); }
        i = json::ws(s, r.pos);
        guard i < s.len else { json::stop(r, i, "unexpected end of input"); return; }
        let c = s[i];
        if c == ',' { i = json::ws(s, i + 1); continue; }
        if c == '}' { r.pos = i + 1; r.depth -= 1; return; }
        json::stop(r, i, "expected ',' or '}'");
        return;
    }
}

// The scalars, each with whether the value was one. A value of another
// kind is not read; a number of another kind converts as a document's
// does (an integer to a double, a whole double in range to an integer).
fn ::try_string(r: json::Reader&) -> const u8[:], bool {
    if json::next_byte(r) != '"' { return "", false; }
    return json::take_string(r);
}

fn ::try_boolean(r: json::Reader&) -> bool, bool {
    let c = json::next_byte(r);
    if c == 't' { let ok = json::take_word(r, "true"); return ok, ok; }
    if c == 'f' { json::take_word(r, "false"); return false, r.error.ok; }
    return false, false;
}

// The number at the reader, not yet consumed: its kind and bits, and where
// it ends. NUM_BAD if no number starts there; a malformed one stops the
// reader.
fn peek_number(r: Reader&) -> i64, u64, i64 {
    let c = next_byte(r);
    if c != '-' && (c < '0' || c > '9') { return NUM_BAD, 0, r.pos; }
    let kind, bits, end = scan_number(r.src, r.pos);
    if kind == NUM_BAD { stop(r, end, "invalid number"); }
    return kind, bits, end;
}

// A plain decimal at s[at] -- no exponent, at most 15 digits -- as a
// double, and where it ends; -1 for anything else, which scan_number
// reads. The digits are an exact integer below 2^53 and the power of ten
// is exact, so the one division is correctly rounded (Clinger), and the
// result is scan_number's.
inline fn plain_float(s: const u8[:], at: i64) -> f64, i64 {
    let n = s.len;
    var p = at;
    let neg = p < n && s[p] == '-';
    if neg { p += 1; }
    let first = p;
    var m: u64 = 0;
    if p < n && s[p] == '0' { p += 1; }
    else {
        while p < n && s[p] - '0' <= 9 { m = m * 10 + (s[p] - '0'); p += 1; }
        if p == first { return 0.0, -1; }
    }
    var frac = 0;
    if p < n && s[p] == '.' {
        p += 1;
        let fs = p;
        if p + 8 <= n {
            let x = load8(s, p);
            if eight_digits(x) { m = m * 100000000 + eight_value(x); p += 8; }
        }
        while p < n && s[p] - '0' <= 9 { m = m * 10 + (s[p] - '0'); p += 1; }
        frac = p - fs;
        if frac == 0 { return 0.0, -1; }
    }
    if (p < n && (s[p] | 0x20) == 'e') || p - first - (if frac > 0 { 1 } else { 0 }) > 15 { return 0.0, -1; }
    var x = m as f64;
    if frac > 0 { x = x / POW10_F64[frac]; }
    return if neg { -x } else { x }, p;
}

fn ::try_float(r: json::Reader&) -> f64, bool {
    let c = json::next_byte(r);
    if c != '-' && (c < '0' || c > '9') { return 0.0, false; }
    let x, end = json::plain_float(r.src, r.pos);
    if end >= 0 { r.pos = end; return x, true; }
    let kind, bits, e2 = json::peek_number(r);
    if kind == json::NUM_BAD { return 0.0, false; }
    r.pos = e2;
    if kind == json::NUM_FLOAT { return json::f64_of(bits), true; }
    if kind == json::NUM_INT { return bits as! i64, true; }
    return bits, true;
}

fn ::try_int(r: json::Reader&) -> i64, bool {
    let kind, bits, end = json::peek_number(r);
    if kind == json::NUM_INT { r.pos = end; return bits as! i64, true; }
    if kind == json::NUM_FLOAT {
        let x = json::f64_of(bits);
        if x >= -9223372036854775808.0 && x < 9223372036854775808.0 && x == floor(x) { r.pos = end; return x as! i64, true; }
    }
    return 0, false;
}

fn ::try_uint(r: json::Reader&) -> u64, bool {
    let kind, bits, end = json::peek_number(r);
    if kind == json::NUM_UINT || (kind == json::NUM_INT && bits >> 63 == 0) { r.pos = end; return bits, true; }
    return 0, false;
}

fn ::int(r: json::Reader&) -> i64 { let x, ok = r.try_int(); return x; }
fn ::uint(r: json::Reader&) -> u64 { let x, ok = r.try_uint(); return x; }
fn ::float(r: json::Reader&) -> f64 { let x, ok = r.try_float(); return x; }
fn ::string(r: json::Reader&) -> const u8[:] { let x, ok = r.try_string(); return x; }
fn ::boolean(r: json::Reader&) -> bool { let x, ok = r.try_boolean(); return x; }

// The value's exact text, checked and passed over.
fn ::raw(r: json::Reader&) -> const u8[:] {
    json::next_byte(r);
    let from = r.pos;
    r.skip();
    if !r.error.ok { return ""; }
    return r.src[from..r.pos];
}

// Whether the whole text was JSON: the root value is read if it was not
// (skipped, and so checked), and nothing but whitespace may follow it.
fn ::finish(r: json::Reader&) -> bool {
    if r.error.ok && r.depth == 0 && (r.root < 0 || r.pos == r.root) { r.skip(); }
    let s = r.src;
    r.pos = json::ws(s, r.pos);
    if r.error.ok && r.pos < s.len { json::stop(r, r.pos, "unexpected text after the value"); }
    return r.error.ok;
}
