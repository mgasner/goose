// The tables every part of graphql shares, and the lexer.
//
// The library's state is a set of flat global tables of fixed-size rows
// linked by index. A schema is loaded into them once, before any worker is
// spawned, and every worker starts with a copy of it (spec §11.2); a request
// appends its own rows above the schema's and truncates them again when it is
// done. Nothing here holds a reference, so all of it can be copied into a
// worker.

namespace graphql;

import std;
import json;

// --- names and text --------------------------------------------------------

// A run of `text`: every name and string the schema and the request hold.
struct Name { at: i64 = 0, len: i64 = 0 }

var text: u8[>..] = [];

fn str_of(n: Name) -> const u8[:] { text[n.at..n.at + n.len] }

fn add_text(s: const u8[:]) -> Name {
    let at = text.len;
    text.append(s);
    return Name { at: at, len: s.len };
}

fn same(a: Name, b: Name) -> bool { str_of(a) == str_of(b) }

// --- the schema --------------------------------------------------------------

let SCALAR = 0;
let OBJECT = 1;
let INTERFACE = 2;
let UNION = 3;
let ENUM = 4;
let INPUT = 5;

// A named type. `first`/`count` are its fields (object, interface), its
// input fields (rows of `inputs`), its values (enum) or its members (union,
// rows of `members`); `ifirst`/`icount` are the interfaces it implements.
struct TypeDef {
    name: Name, desc: Name, kind: i64,
    first: i64 = 0, count: i64 = 0, ifirst: i64 = 0, icount: i64 = 0,
}

// A field of an object or interface type. `owner` is the type it is
// declared on, for messages.
struct FieldDef {
    name: Name, desc: Name, tref: i64, owner: i64,
    afirst: i64 = 0, acount: i64 = 0,
    deprecated: bool = false, reason: Name,
}

// An argument, an input field or a directive argument. `default` is a row
// of `values`, or -1.
struct InputDef { name: Name, desc: Name, tref: i64, default: i64 = -1, deprecated: bool = false, reason: Name }

struct EnumDef { name: Name, desc: Name, deprecated: bool = false, reason: Name }

// A type reference: a named type, or a list or non-null wrapper of another
// reference. `of` is a row of `types` (NAMED, once resolved) or of `trefs`.
let NAMED = 0;
let LIST = 1;
let NON_NULL = 2;
struct TypeRef { kind: i64, of: i64 = -1, name: Name }

// A union member or an implemented interface, by name until resolved.
struct Member { name: Name, of: i64 = -1 }

struct DirDef { name: Name, desc: Name, afirst: i64 = 0, acount: i64 = 0, lfirst: i64 = 0, lcount: i64 = 0, repeatable: bool = false }

var types: TypeDef[>..] = [];
var fields: FieldDef[>..] = [];
var inputs: InputDef[>..] = [];
var enums: EnumDef[>..] = [];
var trefs: TypeRef[>..] = [];
var members: Member[>..] = [];
var directives: DirDef[>..] = [];
var locations: Name[>..] = [];

var query_type: i64 = -1;
var mutation_type: i64 = -1;
var loaded = false;

// Rows below these belong to the schema; a request's rows sit above them.
var schema_text: i64 = 0;
var schema_values: i64 = 0;
var schema_trefs: i64 = 0;

// --- values --------------------------------------------------------------------

// An input value: a literal of the request or the schema, or a variable's
// value read from the request's JSON. Lists and objects chain their items
// through `first` and `next`; an object's items carry their keys.
let V_NULL = 0;
let V_INT = 1;
let V_FLOAT = 2;
let V_STRING = 3;
let V_BOOL = 4;
let V_ENUM = 5;
let V_LIST = 6;
let V_OBJECT = 7;
let V_VAR = 8;
struct Value { kind: i64, i: i64 = 0, f: f64 = 0.0, s: Name, key: Name, first: i64 = -1, next: i64 = -1 }

var values: Value[>..] = [];

// --- options --------------------------------------------------------------------

// Set these before spawning workers: each worker starts with a copy.
var max_depth: i64 = 32;           // selection nesting a request may have
var introspection = true;          // answer __schema and __type
var fork_min_fields: i64 = 4096;   // a list worth splitting across workers
var fork_min_items: i64 = 16;      // the fewest items one part may get

// --- errors -----------------------------------------------------------------------

// The request's errors as JSON objects, comma separated, and how many.
var errs: u8[>..] = [];
var nerrs: i64 = 0;

var source: u8[>..] = [];          // the text being parsed: SDL or a query
var source_is_query = false;       // whether errors may cite locations in it

fn json_quote<A>(out: A&, s: const u8[:]) { json::write_string(out, s); }

// The line and column of a byte of `source`, both from 1.
fn line_col(at: i64) -> i64, i64 {
    var line = 1;
    var col = 1;
    for i in 0..min(at, source.len) {
        if source[i] == '\n' { line++; col = 1; } else { col++; }
    }
    return line, col;
}

// Opens an error object: its message and, for a position in a query, its
// location. The caller adds a path if it has one and closes it.
// The first error's message and position, for messages outside JSON.
var first_message: u8[>..] = [];
var err_at: i64 = 0;

fn open_error(msg: const u8[:], at: i64) {
    if nerrs == 0 { first_message.clear(); first_message.append(msg); err_at = at; }
    if nerrs > 0 { errs.push(','); }
    nerrs++;
    errs.append("{\"message\":");
    json_quote(errs, msg);
    if at >= 0 && source_is_query {
        let line, col = line_col(at);
        format(errs, ",\"locations\":[{\"line\":", line, ",\"column\":", col, "}]");
    }
}

fn add_error(msg: const u8[:], at: i64) {
    open_error(msg, at);
    errs.push('}');
}

// --- lexer ---------------------------------------------------------------------------

let T_EOF = 0;
let T_PUNCT = 1;      // tpunct holds the byte; '.' stands for "..."
let T_NAME = 2;
let T_INT = 3;
let T_FLOAT = 4;
let T_STRING = 5;
let T_BLOCK = 6;

var pos: i64 = 0;
var tok: i64 = 0;
var tpunct: u8 = 0;
var tstart: i64 = 0;
var tend: i64 = 0;

// What `parse_source` parses.
let P_SDL = 0;
let P_QUERY = 1;

fn is_name_start(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

fn token_text() -> const u8[:] { source[tstart..tend] }

fn describe_token() -> u8[>..] {
    if tok == T_EOF { return str("<EOF>"); }
    if tok == T_STRING || tok == T_BLOCK { return str("String"); }
    var s: u8[>..] = [];
    if tok == T_NAME { s.append("Name \""); s.append(token_text()); s.push('"'); return s; }
    if tok == T_INT || tok == T_FLOAT { s.append("\""); s.append(token_text()); s.push('"'); return s; }
    s.push('"');
    if tpunct == '.' { s.append("..."); } else { s.push(tpunct); }
    s.push('"');
    return s;
}

// Every syntax error ends here: one error, and parse_source returns false.
fn syntax_error(msg: const u8[:], at: i64) {
    var m: u8[>..] = [];
    m.append("Syntax Error: ");
    m.append(msg);
    add_error(m, at);
    return false from parse_source;
}

// An error in what parsed, such as a type defined twice: the same, without
// the "Syntax Error" prefix.
fn parse_error(msg: const u8[:], at: i64) {
    add_error(msg, at);
    return false from parse_source;
}

fn unexpected() {
    syntax_error(str("Unexpected ", describe_token(), "."), tstart);
}

// Reads the next token into tok, tstart, tend and tpunct.
fn advance() {
    loop {
        guard pos < source.len else { break; }
        let c = source[pos];
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',' { pos++; continue; }
        if c == 0xEF && pos + 2 < source.len && source[pos + 1] == 0xBB && source[pos + 2] == 0xBF { pos += 3; continue; }
        if c == '#' {
            while pos < source.len && source[pos] != '\n' && source[pos] != '\r' { pos++; }
            continue;
        }
        break;
    }
    tstart = pos;
    guard pos < source.len else { tok = T_EOF; tend = pos; return; }
    let c = source[pos];
    if is_name_start(c) {
        while pos < source.len && (is_name_start(source[pos]) || is_digit(source[pos])) { pos++; }
        tok = T_NAME;
        tend = pos;
        return;
    }
    if c == '-' || is_digit(c) { lex_number(); return; }
    if c == '"' {
        if pos + 2 < source.len && source[pos + 1] == '"' && source[pos + 2] == '"' { lex_block_string(); return; }
        lex_string();
        return;
    }
    if c == '.' {
        guard pos + 2 < source.len && source[pos + 1] == '.' && source[pos + 2] == '.' else {
            syntax_error("Unexpected character: \".\".", pos);
        }
        pos += 3;
        tok = T_PUNCT;
        tpunct = '.';
        tend = pos;
        return;
    }
    if c == '!' || c == '$' || c == '&' || c == '(' || c == ')' || c == ':' || c == '=' || c == '@' ||
       c == '[' || c == ']' || c == '{' || c == '|' || c == '}' {
        pos++;
        tok = T_PUNCT;
        tpunct = c;
        tend = pos;
        return;
    }
    var m: u8[>..] = [];
    m.append("Unexpected character: \"");
    m.push(c);
    m.append("\".");
    syntax_error(m, pos);
}

fn lex_number() {
    let start = pos;
    var float = false;
    if source[pos] == '-' { pos++; }
    guard pos < source.len && is_digit(source[pos]) else { syntax_error("Invalid number, expected digit.", pos); }
    if source[pos] == '0' {
        pos++;
        guard !(pos < source.len && is_digit(source[pos])) else { syntax_error("Invalid number, unexpected digit after 0.", pos); }
    } else {
        while pos < source.len && is_digit(source[pos]) { pos++; }
    }
    if pos < source.len && source[pos] == '.' {
        float = true;
        pos++;
        guard pos < source.len && is_digit(source[pos]) else { syntax_error("Invalid number, expected digit.", pos); }
        while pos < source.len && is_digit(source[pos]) { pos++; }
    }
    if pos < source.len && (source[pos] == 'e' || source[pos] == 'E') {
        float = true;
        pos++;
        if pos < source.len && (source[pos] == '+' || source[pos] == '-') { pos++; }
        guard pos < source.len && is_digit(source[pos]) else { syntax_error("Invalid number, expected digit.", pos); }
        while pos < source.len && is_digit(source[pos]) { pos++; }
    }
    guard !(pos < source.len && (is_name_start(source[pos]) || source[pos] == '.')) else {
        syntax_error("Invalid number, expected digit.", pos);
    }
    tok = if float { T_FLOAT } else { T_INT };
    tstart = start;
    tend = pos;
}

// A quoted string; the token spans the quotes. Its value is decoded when
// the parser takes it (take_string).
fn lex_string() {
    pos++;
    loop {
        guard pos < source.len else { syntax_error("Unterminated string.", pos); }
        let c = source[pos];
        if c == '"' { pos++; break; }
        if c == '\n' || c == '\r' { syntax_error("Unterminated string.", pos); }
        if c == '\\' { pos += 2; continue; }
        pos++;
    }
    tok = T_STRING;
    tend = pos;
}

fn lex_block_string() {
    pos += 3;
    loop {
        guard pos + 2 < source.len else { syntax_error("Unterminated string.", pos); }
        if source[pos] == '"' && source[pos + 1] == '"' && source[pos + 2] == '"' { pos += 3; break; }
        if source[pos] == '\\' && pos + 3 < source.len && source[pos + 1] == '"' && source[pos + 2] == '"' && source[pos + 3] == '"' { pos += 4; continue; }
        pos++;
    }
    tok = T_BLOCK;
    tend = pos;
}

fn hex_value(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

fn hex4(at: i64) -> i64 {
    guard at + 4 <= source.len else { syntax_error("Invalid Unicode escape sequence.", at); return 0; }
    var v = 0;
    for i in 4 {
        let h = hex_value(source[at + i]);
        guard h >= 0 else { syntax_error("Invalid Unicode escape sequence.", at); return 0; }
        v = v * 16 + h;
    }
    return v;
}

// The current string token's value, decoded into `text`.
fn take_string() -> Name {
    let at = text.len;
    if tok == T_BLOCK {
        block_value(source[tstart + 3..tend - 3]);
    } else {
        var i = tstart + 1;
        let end = tend - 1;
        while i < end {
            let c = source[i];
            if c != '\\' { text.push(c); i++; continue; }
            let e = source[i + 1];
            i += 2;
            if e == 'n' { text.push('\n'); }
            else if e == 't' { text.push('\t'); }
            else if e == 'r' { text.push('\r'); }
            else if e == 'b' { text.push(8); }
            else if e == 'f' { text.push(12); }
            else if e == '"' || e == '\\' || e == '/' { text.push(e); }
            else if e == 'u' {
                var cp = hex4(i);
                i += 4;
                if cp >= 0xD800 && cp < 0xDC00 && i + 6 <= end && source[i] == '\\' && source[i + 1] == 'u' {
                    let lo = hex4(i + 2);
                    if lo >= 0xDC00 && lo < 0xE000 { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i += 6; }
                }
                push_utf8(text, cp);
            } else {
                var m: u8[>..] = [];
                m.append("Invalid character escape sequence: \"\\");
                m.push(e);
                m.append("\".");
                syntax_error(m, i - 2);
            }
        }
    }
    advance();
    return Name { at: at, len: text.len - at };
}

// A block string's value (the spec's BlockStringValue): \""" unescaped, the
// common indentation of all lines but the first removed, leading and
// trailing blank lines dropped.
fn block_value(raw: const u8[:]) {
    var lines: u8[>..] = [];
    var i = 0;
    while i < raw.len {
        if raw[i] == '\\' && i + 3 < raw.len + 0 && raw[i + 1] == '"' && raw[i + 2] == '"' && raw[i + 3] == '"' {
            lines.append("\"\"\"");
            i += 4;
            continue;
        }
        lines.push(raw[i]);
        i++;
    }
    let parts = split(lines, '\n');
    var common = -1;
    for p, k in parts {
        if k == 0 { continue; }
        var ind = 0;
        while ind < p.len && (p[ind] == ' ' || p[ind] == '\t') { ind++; }
        if ind < p.len && (common < 0 || ind < common) { common = ind; }
    }
    var first = 0;
    var last = parts.len - 1;
    while first <= last && blank(parts[first], if first == 0 { 0 } else { common }) { first++; }
    while last >= first && blank(parts[last], if last == 0 { 0 } else { common }) { last--; }
    for k in first..last + 1 {
        if k > first { text.push('\n'); }
        var p = parts[k];
        if k > 0 && common > 0 { p = p[min(common, p.len)..]; }
        if p.len > 0 && p[p.len - 1] == '\r' { p = p[..p.len - 1]; }
        text.append(p);
    }
}

fn blank(p: const u8[:], skip: i64) -> bool {
    for c in p { if c != ' ' && c != '\t' && c != '\r' { return false; } }
    return true;
}

fn at_punct(c: u8) -> bool { tok == T_PUNCT && tpunct == c }
fn at_name(w: const u8[:]) -> bool { tok == T_NAME && token_text() == w }

fn expect_punct(c: u8) {
    guard at_punct(c) else {
        var m: u8[>..] = [];
        m.append("Expected \"");
        if c == '.' { m.append("..."); } else { m.push(c); }
        m.append("\", found ");
        m.append(describe_token());
        m.push('.');
        syntax_error(m, tstart);
    }
    advance();
}

fn take_name() -> Name {
    guard tok == T_NAME else { syntax_error(str("Expected Name, found ", describe_token(), "."), tstart); return Name { .. }; }
    let n = add_text(token_text());
    advance();
    return n;
}

fn expect_keyword(w: const u8[:]) {
    guard at_name(w) else { syntax_error(str("Expected \"", w, "\", found ", describe_token(), "."), tstart); }
    advance();
}
