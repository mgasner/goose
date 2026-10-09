// HTTP/1.1: a server, its request parser, and a small blocking client for
// tests and tools. See docs/http.md for how to use it and
// docs/design/http.md for the design.
//
// The runtime (src/runtime/runtime_net.h) moves bytes and nothing else: a
// worker's engine reads a connection's input straight onto the worker's
// buffer, and the parsing, the handler and the response are all Goose.
// Every worker runs its own engine on its own listener, so a server is one
// `serve` per worker and nothing is shared between them.

namespace http;

import std;

extern "gs_net_listen" fn net_listen(host: const u8[:], port: i64, backlog: i64) -> i64;
extern "gs_net_port" fn net_port(fd: i64) -> i64;
extern "gs_net_open" fn net_open(listener: i64, idle_ms: i64) -> i64;
extern "gs_net_wait" fn net_wait(engine: i64, buf: u8[>..]&) -> i64;
extern "gs_net_write" fn net_write(engine: i64, conn: i64, a: const u8[:], b: const u8[:]) -> bool;
extern "gs_net_done" fn net_done(engine: i64, conn: i64, rest: const u8[:], need: i64, close: bool);
extern "gs_net_live" fn net_live(engine: i64) -> i64;
extern "gs_net_close" fn net_close(engine: i64);
extern "gs_net_date" fn net_date(out: u8[:]) -> i64;

// Sockets for the client, blocking: connect gives a socket or -1, and a
// send or receive waiting longer than timeout_ms (0: forever) fails.
extern "gs_net_connect" fn connect(host: const u8[:], port: i64, timeout_ms: i64) -> i64;
extern "gs_net_send" fn send(fd: i64, data: const u8[:]) -> bool;            // all of it
extern "gs_net_recv" fn recv(fd: i64, out: u8[>..]&, max: i64) -> i64;      // appends one read; 0 at the end
extern "gs_net_close_fd" fn close(fd: i64);

// --- requests ----------------------------------------------------------------

let MAX_HEADERS = 64;

struct Header { name: const u8[:], value: const u8[:] }

// A parsed request. Every slice views the buffer the request was parsed
// from, so a request lives no longer than the handler call it is given to.
struct Request {
    method: const u8[:],
    target: const u8[:],          // as sent: the path and the query
    path: const u8[:],
    query: const u8[:],           // after the '?', without it
    minor: i64,                   // HTTP/1.minor
    headers: Header[..MAX_HEADERS],
    body: const u8[:],            // decoded, if it came chunked
    keep_alive: bool,
    expect_continue: bool,
}

struct Limits {
    max_head: i64 = 8192,         // request line and headers; 431 past it
    max_body: i64 = 1 << 20,      // 413 past it
    idle_ms: i64 = 5000,          // a silent connection is closed (0: never)
}

// tchar (RFC 9110 5.6.2): what a method and a header name are made of.
const TOKEN: u8[256] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

// What a header value may hold: tab, visible ASCII, space and obs-text.
const VALUE: u8[256] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
];

// What a request target may hold: VALUE without space and tab.
const TARGET: u8[256] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
];

// How many bytes at the start of r are in the class `table` marks, four at
// a time while four are left: a scan's cost is mostly its loop, and this
// one runs a quarter as many.
fn span(r: const u8[:], table: const u8[256]&) -> i64 {
    var k = 0;
    while k + 4 <= r.len {
        let c0 = r[k];
        let c1 = r[k + 1];
        let c2 = r[k + 2];
        let c3 = r[k + 3];
        if (table[c0] & table[c1] & table[c2] & table[c3]) == 0 { break; }
        k += 4;
    }
    while k < r.len {
        let c = r[k];
        if table[c] == 0 { break; }
        k++;
    }
    return k;
}

// a == lower, ignoring the case of a's letters; lower is lowercase letters
// and '-', and a is a token, so setting the 0x20 bit folds only letters.
fn same_ci(a: const u8[:], lower: const u8[:]) -> bool {
    if a.len != lower.len { return false; }
    for c, i in a {
        if (c | 0x20) != lower[i] { return false; }
    }
    return true;
}

// Whether a comma-separated header value lists the token `lower`.
fn lists_ci(v: const u8[:], lower: const u8[:]) -> bool {
    var found = false;
    each_split(v, ',') {
        if same_ci(trim(it), lower) { found = true; }
    };
    return found;
}

fn hex_digit(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// Where a chunked body that starts at s[at] ends, and its decoded length:
// (end, length) when it is all there; (0, 0) when more is needed; (-status,
// 0) when it is malformed or too long. Reads only, so a body that is not
// all there yet can be looked at again when more arrives.
fn chunked_extent(s: const u8[:], at: i64, max_body: i64) -> i64, i64 {
    let n = s.len;
    var i = at;
    var total = 0;
    loop {
        // chunk-size [; extensions] CRLF
        var size = 0;
        let digits = i;
        while i < n {
            let d = hex_digit(s[i]);
            if d < 0 { break; }
            if size > (max_body >> 4) { return -413, 0; }
            size = size * 16 + d;
            i++;
        }
        if i == n { return 0, 0; }
        if i == digits { return -400, 0; }
        while i < n && s[i] != '\r' {
            if VALUE[s[i]] == 0 { return -400, 0; }
            i++;
        }
        if i + 1 >= n { return 0, 0; }
        if s[i + 1] != '\n' { return -400, 0; }
        i += 2;
        total += size;
        if total > max_body { return -413, 0; }
        if size == 0 { break; }
        // chunk-data CRLF
        if i + size + 2 > n { return 0, 0; }
        i += size;
        if s[i] != '\r' || s[i + 1] != '\n' { return -400, 0; }
        i += 2;
    }
    // Trailer fields, ignored, then the final CRLF.
    loop {
        if i + 1 >= n { return 0, 0; }
        if s[i] == '\r' {
            if s[i + 1] != '\n' { return -400, 0; }
            return i + 2, total;
        }
        while i < n && s[i] != '\r' {
            if VALUE[s[i]] == 0 { return -400, 0; }
            i++;
        }
        if i + 1 >= n { return 0, 0; }
        if s[i + 1] != '\n' { return -400, 0; }
        i += 2;
    }
}

// Decodes the chunked body chunked_extent found at s[at..] in place: the
// data of each chunk moves down to follow the last, starting at s[at].
fn dechunk(s: u8[:], at: i64) {
    var i = at;
    var w = at;
    loop {
        var size = 0;
        loop {
            let d = hex_digit(s[i]);
            if d < 0 { break; }
            size = size * 16 + d;
            i++;
        }
        while s[i] != '\r' { i++; }
        i += 2;
        if size == 0 { return; }
        for k in size { s[w + k] = s[i + k]; }
        w += size;
        i += size + 2;
    }
}

// The request line and headers at the start of s, into req: (end of the
// head, Content-Length or -1, chunked); (0, ..) while the head is not all
// there; (-status, ..) when it is malformed. No limit applies here: parse
// applies them, and the engine never hands over more than it has read.
//
// Each scan runs a fresh counter over what is left, `r`, and then cuts `r`
// past what it read: counters that only count up by one let the compiler
// see every index is in bounds (§10.5), so the scans run unchecked.
fn parse_head(s: const u8[:], req: Request&) -> i64, i64, bool {
    var r = s;

    // method SP
    var k = 0;
    while k < r.len {
        let c = r[k];
        if TOKEN[c] == 0 { break; }
        k++;
    }
    if k >= r.len { return 0, -1, false; }
    if r[k] != ' ' || k == 0 { return -400, -1, false; }
    req.method = r[..k];
    r = r[k + 1..];

    // request-target SP
    k = 0;
    var q = -1;
    while k < r.len {
        let c = r[k];
        if TARGET[c] == 0 { break; }
        if c == '?' && q < 0 { q = k; }
        k++;
    }
    if k >= r.len { return 0, -1, false; }
    if r[k] != ' ' || k == 0 { return -400, -1, false; }
    let target = r[..k];
    req.target = target;
    if q < 0 {
        req.path = target;
        req.query = target[k..];
    } else {
        req.path = target[..q];
        req.query = target[q + 1..];
    }
    r = r[k + 1..];

    // HTTP-version CRLF
    if r.len < 10 { return 0, -1, false; }
    if r[0] != 'H' || r[1] != 'T' || r[2] != 'T' || r[3] != 'P' || r[4] != '/' {
        return -400, -1, false;
    }
    let major = r[5];
    if major != '1' || r[6] != '.' {
        return if major >= '0' && major <= '9' { -505 } else { -400 }, -1, false;
    }
    let minor = r[7];
    if minor < '0' || minor > '9' { return -400, -1, false; }
    req.minor = minor - '0';
    if r[8] != '\r' || r[9] != '\n' { return -400, -1, false; }
    r = r[10..];

    var f = Framing { .. };
    let n = parse_fields(r, req.headers, f);
    if n <= 0 { return n, -1, false; }
    req.expect_continue = f.expect_continue;
    req.keep_alive = if req.minor >= 1 { !f.close } else { f.keep && !f.close };
    return s.len - r.len + n, f.clen, f.chunked;
}

// What the header fields say about how a message is framed.
struct Framing {
    clen: i64 = -1,               // Content-Length, or -1
    chunked: bool = false,
    close: bool = false,          // Connection: close
    keep: bool = false,           // Connection: keep-alive
    expect_continue: bool = false,
}

// The header fields at the start of s, through the blank line that ends
// them, pushed onto hs: the bytes they take; 0 while they are not all
// there; -status when they are malformed (400), too many (431), or name a
// transfer coding other than chunked (501).
fn parse_fields(s: const u8[:], hs: Header[..MAX_HEADERS]&, f: Framing&) -> i64 {
    var r = s;
    loop {
        if r.len < 2 { return 0; }
        if r[0] == '\r' {
            if r[1] != '\n' { return -400; }
            r = r[2..];
            break;
        }
        let j = span(r, TOKEN);
        if j >= r.len { return 0; }
        if r[j] != ':' || j == 0 { return -400; }
        let name = r[..j];
        r = r[j + 1..];
        var w = 0;
        while w < r.len {
            let c = r[w];
            if c != ' ' && c != '\t' { break; }
            w++;
        }
        r = r[w..];
        let e = span(r, VALUE);
        if e + 1 >= r.len { return 0; }
        if r[e] != '\r' || r[e + 1] != '\n' { return -400; }
        var value = r[..e];
        while value.len > 0 {
            let c = value[value.len - 1];
            if c != ' ' && c != '\t' { break; }
            value = value[..value.len - 1];
        }
        r = r[e + 2..];
        if hs.len == MAX_HEADERS { return -431; }
        hs.push(Header { name: name, value: value });

        // The headers framing depends on, recognized by length first.
        if name.len == 14 && same_ci(name, "content-length") {
            var v = 0;
            if value.len == 0 || value.len > 18 { return -400; }
            for c in value {
                if c < '0' || c > '9' { return -400; }
                v = v * 10 + (c - '0');
            }
            if f.clen >= 0 && f.clen != v { return -400; }
            f.clen = v;
        } else if name.len == 17 && same_ci(name, "transfer-encoding") {
            if !same_ci(value, "chunked") { return -501; }
            f.chunked = true;
        } else if name.len == 10 && same_ci(name, "connection") {
            if lists_ci(value, "close") { f.close = true; }
            if lists_ci(value, "keep-alive") { f.keep = true; }
        } else if name.len == 6 && same_ci(name, "expect") {
            if same_ci(value, "100-continue") { f.expect_continue = true; }
        }
    }
    return s.len - r.len;
}

// Parses one request at the start of s into req. Returns:
//   (n, 0)       a whole request, n bytes of s;
//   (0, need)    not all there yet; need is how many bytes it takes in
//                all, where the head says (0 where it does not yet);
//   (-status, 0) a request to refuse with that status: 400 malformed,
//                413 body too large, 431 head too large, 501 a transfer
//                coding other than chunked, 505 not HTTP/1.x.
// A chunked body is decoded in place in s, once it is all there. req may
// be one an earlier parse filled: everything in it is set again. (Building a
// fresh Request writes all its header slots, which costs more than parsing a
// small request; the serve loop builds one per batch of input.)
fn parse(s: u8[:], req: Request&, limits: Limits) -> i64, i64 {
    req.headers.clear();
    req.expect_continue = false;
    req.body = s[..0];
    let i, clen, chunked = parse_head(s, req);
    if i == 0 {
        return if s.len > limits.max_head { -431 } else { 0 }, 0;
    }
    if i < 0 { return i, 0; }
    if i > limits.max_head { return -431, 0; }

    // The body. Both framings at once is how requests get smuggled.
    if chunked {
        if clen >= 0 { return -400, 0; }
        let end, len = chunked_extent(s, i, limits.max_body);
        if end <= 0 { return end, 0; }
        dechunk(s, i);
        req.body = s[i..i + len];
        return end, 0;
    }
    if clen > limits.max_body { return -413, 0; }
    let blen = max(clen, 0);
    if s.len - i < blen { return 0, i + blen; }
    req.body = s[i..i + blen];
    return i + blen, 0;
}

// A header's value, the first of that name, matched ignoring case.
fn header(req: Request&, name: const u8[:]) -> const u8[:], bool {
    let v, ok = find_header(req.headers, name);
    return v, ok;
}

fn find_header(hs: Header[..MAX_HEADERS]&, name: const u8[:]) -> const u8[:], bool {
    for h in hs {
        if h.name.len == name.len {
            var same = true;
            for c, i in h.name {
                if (c | 0x20) != (name[i] | 0x20) { same = false; break; }
            }
            if same { return h.value, true; }
        }
    }
    return "", false;
}

// A query parameter's value as sent (still percent-encoded), the first of
// that name.
fn query_param(req: Request&, name: const u8[:]) -> const u8[:], bool {
    var at = 0;
    let q = req.query;
    while at <= q.len {
        var end = at;
        while end < q.len && q[end] != '&' { end++; }
        let part = q[at..end];
        let eq = position(part, '=');
        if eq < 0 {
            if part == name { return part[part.len..], true; }
        } else if part[..eq] == name {
            return part[eq + 1..], true;
        }
        at = end + 1;
    }
    return "", false;
}

// Appends s with its percent-escapes decoded, and '+' as a space when
// plus is set (form data); false, with what came before it appended, at a
// malformed escape.
fn decode(out: u8[>..]&, s: const u8[:], plus: bool = false) -> bool {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '%' {
            if i + 2 >= s.len { return false; }
            let hi = hex_digit(s[i + 1]);
            let lo = hex_digit(s[i + 2]);
            if hi < 0 || lo < 0 { return false; }
            out.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            out.push(if plus && c == '+' { ' ' } else { c });
            i++;
        }
    }
    return true;
}

// --- responses ---------------------------------------------------------------

// What a handler fills in. The body is sent with Content-Length; a HEAD
// request gets the headers alone.
struct Response {
    status: i64 = 200,
    close: bool = false,                    // close the connection after this
    content_type: u8[..128] = "text/plain",
    headers: u8[..2048] = [],               // more header lines, as set_header writes them
    body: u8[>..] = [],
}

// Adds a header line; false, adding nothing, when it would not fit or
// holds a CR or LF.
fn set_header(res: Response&, name: const u8[:], value: const u8[:]) -> bool {
    if res.headers.len + name.len + value.len + 4 > res.headers.cap { return false; }
    if position(name, '\r') >= 0 || position(name, '\n') >= 0 { return false; }
    if position(value, '\r') >= 0 || position(value, '\n') >= 0 { return false; }
    res.headers.append(name);
    res.headers.append(": ");
    res.headers.append(value);
    res.headers.append("\r\n");
    return true;
}

fn status_line(status: i64) -> const u8[:] {
    match status {
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        204 => "HTTP/1.1 204 No Content\r\n",
        301 => "HTTP/1.1 301 Moved Permanently\r\n",
        302 => "HTTP/1.1 302 Found\r\n",
        303 => "HTTP/1.1 303 See Other\r\n",
        304 => "HTTP/1.1 304 Not Modified\r\n",
        307 => "HTTP/1.1 307 Temporary Redirect\r\n",
        308 => "HTTP/1.1 308 Permanent Redirect\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        401 => "HTTP/1.1 401 Unauthorized\r\n",
        403 => "HTTP/1.1 403 Forbidden\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        408 => "HTTP/1.1 408 Request Timeout\r\n",
        409 => "HTTP/1.1 409 Conflict\r\n",
        411 => "HTTP/1.1 411 Length Required\r\n",
        413 => "HTTP/1.1 413 Content Too Large\r\n",
        414 => "HTTP/1.1 414 URI Too Long\r\n",
        415 => "HTTP/1.1 415 Unsupported Media Type\r\n",
        422 => "HTTP/1.1 422 Unprocessable Content\r\n",
        429 => "HTTP/1.1 429 Too Many Requests\r\n",
        431 => "HTTP/1.1 431 Request Header Fields Too Large\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        501 => "HTTP/1.1 501 Not Implemented\r\n",
        502 => "HTTP/1.1 502 Bad Gateway\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        505 => "HTTP/1.1 505 HTTP Version Not Supported\r\n",
        _ => "",
    }
}

// The head of a response, through the blank line, appended to out.
fn write_head(out: u8[>..]&, status: i64, date: const u8[:], content_type: const u8[:],
              length: i64, close: bool, extra: const u8[:]) {
    let line = status_line(status);
    if line.len > 0 {
        out.append(line);
    } else {
        format(out, "HTTP/1.1 ", status, " Status\r\n");
    }
    out.append("Server: goose\r\nDate: ");
    out.append(date);
    out.append("\r\nContent-Type: ");
    out.append(content_type);
    out.append("\r\nContent-Length: ");
    format(out, length);
    out.append(if close { "\r\nConnection: close\r\n" } else { "\r\n" });
    out.append(extra);
    out.append("\r\n");
}

// --- serving -----------------------------------------------------------------

// Bodies this large are written from where the handler built them, beside
// the head, rather than copied into the batch of responses.
let LARGE_BODY = 16384;

// Serves HTTP/1.1 on port until the engine fails, calling F(req, res) for
// each request; false if it cannot listen. Call it from each worker: every
// call has a listener and an engine of its own.
//
//     thread_fn worker(port: i64) {
//         http::serve(port) { req, res => res.body.append("Hello, World!"); };
//     }
fn serve<F>(port: i64, host: const u8[:] = "0.0.0.0", limits: Limits = Limits { .. }) -> bool {
    let l = net_listen(host, port, 4096);
    guard l >= 0 else { return false; }
    return serve_on(l, limits, F);
}

// serve on a listener net_listen opened.
fn serve_on<F>(listener: i64, limits: Limits = Limits { .. }) -> bool {
    let engine = net_open(listener, limits.idle_ms);
    guard engine >= 0 else { return false; }
    var buf: u8[>..] = [];
    var out: u8[>..] = [];
    var res = Response { .. };
    var date: u8[29] = [' '; 29];
    loop {
        buf.clear();
        out.clear();
        let conn = net_wait(engine, buf);
        guard conn >= 0 else { break; }
        net_date(date);
        // Every whole request the input holds, answered in one write.
        var at = 0;
        var need = 0;
        var closing = false;
        var req = Request { .. };
        while at < buf.len {
            let n, want = parse(buf[at..], req, limits);
            if n == 0 {
                need = want;
                // The body has not been sent: the client waits to be told to.
                if req.expect_continue && want > 0 && buf.len - at < want {
                    out.append("HTTP/1.1 100 Continue\r\n\r\n");
                }
                break;
            }
            if n < 0 {
                write_head(out, -n, date, "text/plain", 0, true, "");
                closing = true;
                break;
            }
            res = Response { .. };
            F(req, res);
            let head_only = req.method == "HEAD";
            let last = !req.keep_alive || res.close;
            write_head(out, res.status, date, res.content_type, res.body.len, last, res.headers);
            if !head_only {
                if res.body.len >= LARGE_BODY {
                    if !net_write(engine, conn, out, res.body) { closing = true; }
                    out.clear();
                } else {
                    out.append(res.body);
                }
            }
            at += n;
            if last || closing {
                closing = true;
                break;
            }
        }
        if out.len > 0 { net_write(engine, conn, out, ""); }
        net_done(engine, conn, buf[at..], need, closing);
    }
    net_close(engine);
    return false;
}

// The port a listener is bound to: the one the system chose for port 0.
fn listener_port(listener: i64) -> i64 { net_port(listener) }
fn listen(port: i64, host: const u8[:] = "0.0.0.0") -> i64 { net_listen(host, port, 4096) }

// --- the client ----------------------------------------------------------------

// A response the client read. Every slice views the buffer it was read
// into, which the caller owns.
struct Reply {
    status: i64,
    minor: i64,
    reason: const u8[:],
    headers: Header[..MAX_HEADERS],
    body: const u8[:],            // decoded, if it came chunked
    keep_alive: bool,
}

fn header(rep: Reply&, name: const u8[:]) -> const u8[:], bool {
    let v, ok = find_header(rep.headers, name);
    return v, ok;
}

// A connection to one server, kept open between requests while the server
// allows it, and opened again (once) if it closed one that was idle.
struct Client {
    fd: i64 = -1,
    host: u8[..256] = [],
    port: i64 = 0,
    timeout_ms: i64 = 30000,
    max_body: i64 = 1 << 26,
    error: u8[..200] = [],        // why the last fetch failed
}

fn close(c: Client&) {
    if c.fd >= 0 {
        close(c.fd);
        c.fd = -1;
    }
}

// The parts of an http:// URL; the slices view it.
struct Url {
    host: const u8[:],
    port: i64,
    target: const u8[:],          // the path and query; "" for "/"
    bracket: bool,                // an IPv6 address, written [host]
}

// http://host[:port][/path][?query][#fragment]; false for anything else,
// https:// and user:password@ included.
fn parse_url(url: const u8[:], u: Url&) -> bool {
    guard url.len > 7 && same_ci(url[..7], "http://") else { return false; }
    let rest = url[7..];
    var end = 0;
    while end < rest.len {
        let c = rest[end];
        if c == '/' || c == '?' || c == '#' { break; }
        end++;
    }
    let authority = rest[..end];
    var target = rest[end..];
    let hash = position(target, '#');
    if hash >= 0 { target = target[..hash]; }
    if position(authority, '@') >= 0 { return false; }
    var host = authority;
    var after = authority[authority.len..];   // the ":port", if any
    u.bracket = false;
    if host.len > 0 && host[0] == '[' {
        let close = position(host, ']');
        if close < 0 { return false; }
        after = host[close + 1..];
        host = host[1..close];
        u.bracket = true;
    } else {
        let colon = position(host, ':');
        if colon >= 0 {
            after = host[colon..];
            host = host[..colon];
        }
    }
    u.port = 80;
    if after.len > 0 {
        if after[0] != ':' { return false; }
        let p, ok = parse_int(after[1..]);
        if !ok || p <= 0 || p > 65535 { return false; }
        u.port = p;
    }
    if host.len == 0 || host.len > 255 { return false; }
    for c in host {
        if c <= ' ' || c >= 0x7f { return false; }
    }
    for c in target {
        if TARGET[c] == 0 { return false; }
    }
    u.host = host;
    u.target = target;
    return true;
}

// The status line and headers of a response at the start of s, into rep:
// the end of the head, 0 while it is not all there, -1 when malformed.
fn parse_reply_head(s: const u8[:], rep: Reply&, f: Framing&) -> i64 {
    // HTTP/1.x SP 3DIGIT SP reason CRLF; a server may leave out the SP
    // before an empty reason.
    if s.len < 12 { return 0; }
    if s[0] != 'H' || s[1] != 'T' || s[2] != 'T' || s[3] != 'P' || s[4] != '/' || s[5] != '1' ||
       s[6] != '.' || s[8] != ' ' {
        return -1;
    }
    let minor = s[7];
    let d0 = s[9];
    let d1 = s[10];
    let d2 = s[11];
    if minor < '0' || minor > '9' || d0 < '1' || d0 > '5' || d1 < '0' || d1 > '9' ||
       d2 < '0' || d2 > '9' {
        return -1;
    }
    rep.minor = minor - '0';
    // Each digit widens before it is scaled: 4 * 100 overflows a u8.
    let hundreds: i64 = d0 - '0';
    let tens: i64 = d1 - '0';
    rep.status = hundreds * 100 + tens * 10 + (d2 - '0');
    var r = s[12..];
    let e = span(r, VALUE);
    if e + 1 >= r.len { return 0; }
    if r[e] != '\r' || r[e + 1] != '\n' { return -1; }
    rep.reason = trim(r[..e]);
    r = r[e + 2..];
    let n = parse_fields(r, rep.headers, f);
    if n <= 0 { return if n == 0 { 0 } else { -1 }; }
    return s.len - r.len + n;
}

// A whole response at the start of s, into rep: its length; 0 while it is
// not all there; -1 when it is malformed or its body is larger than
// max_body. eof says no more will come, which ends a body that has no
// length. Interim (1xx) responses are skipped.
fn parse_reply(s: u8[:], rep: Reply&, head_only: bool, eof: bool, max_body: i64) -> i64 {
    var at = 0;
    loop {
        rep.headers.clear();
        var f = Framing { .. };
        let n = parse_reply_head(s[at..], rep, f);
        if n <= 0 { return n; }
        if rep.status >= 100 && rep.status < 200 && rep.status != 101 {
            at += n;
            continue;
        }
        let i = at + n;
        rep.keep_alive = if rep.minor >= 1 { !f.close } else { f.keep && !f.close };
        if head_only || rep.status == 204 || rep.status == 304 || rep.status == 101 {
            rep.body = s[i..i];
            return i;
        }
        if f.chunked {
            let end, len = chunked_extent(s, i, max_body);
            if end < 0 { return -1; }
            if end == 0 { return 0; }
            dechunk(s, i);
            rep.body = s[i..i + len];
            return end;
        }
        if f.clen >= 0 {
            if f.clen > max_body { return -1; }
            if s.len - i < f.clen { return 0; }
            rep.body = s[i..i + f.clen];
            return i + f.clen;
        }
        // No length: the body is everything until the server closes.
        if !eof { return 0; }
        if s.len - i > max_body { return -1; }
        rep.keep_alive = false;
        rep.body = s[i..];
        return s.len;
    }
}

fn fail(c: Client&, why: const u8[:]) -> bool {
    close(c);
    c.error = why[..min(why.len, 200)];
    return false;
}

// Sends a request and reads the response, appending both to buf: rep's
// slices view buf. It never shrinks buf, so slices from earlier fetches stay
// good; clear buf between requests once nothing views it. `headers` is more
// header lines, each "Name: value\r\n". false, with c.error saying why,
// when no whole response came.
fn fetch(c: Client&, method: const u8[:], url: const u8[:], buf: u8[>..]&, rep: Reply&,
         body: const u8[:] = "", headers: const u8[:] = "") -> bool {
    var u = Url { host: "", port: 0, target: "", bracket: false };
    guard parse_url(url, u) else { return fail(c, "not an http:// URL"); }
    guard position(headers, 0) < 0 else { return fail(c, "a NUL in the headers"); }
    if c.fd >= 0 && (c.host != u.host || c.port != u.port) { close(c); }

    let start = buf.len;
    buf.append(method);
    buf.push(' ');
    if u.target.len == 0 || u.target[0] != '/' { buf.push('/'); }
    buf.append(u.target);
    buf.append(" HTTP/1.1\r\nHost: ");
    if u.bracket { buf.push('['); }
    buf.append(u.host);
    if u.bracket { buf.push(']'); }
    if u.port != 80 { format(buf, ":", u.port); }
    buf.append("\r\nUser-Agent: goose\r\n");
    if body.len > 0 || method == "POST" || method == "PUT" || method == "PATCH" {
        format(buf, "Content-Length: ", body.len, "\r\n");
    }
    buf.append(headers);
    buf.append("\r\n");
    buf.append(body);
    let sent = buf.len;
    let head_only = method == "HEAD";

    for attempt in 2 {
        let reused = c.fd >= 0;
        if !reused {
            c.fd = connect(u.host, u.port, c.timeout_ms);
            if c.fd < 0 { return fail(c, "cannot connect"); }
            c.host = u.host;
            c.port = u.port;
        }
        if !send(c.fd, buf[start..sent]) {
            close(c);
            if reused { continue; }
            return fail(c, "cannot send the request");
        }
        // Read until the response is whole. Each read may take as much as
        // has come so far, so a large body is parsed a logarithmic number
        // of times rather than once per 64 KB.
        var eof = false;
        loop {
            let want = max(65536, buf.len - start);
            let n = recv(c.fd, buf, want);
            if n < 0 { return fail(c, "the connection failed, or timed out"); }
            if n == 0 { eof = true; }
            if eof && buf.len == sent { break; }
            let got = parse_reply(buf[sent..], rep, head_only, eof, c.max_body);
            if got < 0 { return fail(c, "a malformed response"); }
            if got > 0 {
                if !rep.keep_alive || buf.len - sent > got { close(c); }
                return true;
            }
            if eof { return fail(c, "the server closed the connection mid-response"); }
        }
        // A kept connection the server had closed before answering (buf
        // holds just the request): once more, on a new one.
        close(c);
        if !reused { return fail(c, "the server closed the connection"); }
    }
    return fail(c, "the server closed the connection");
}

// One request on a connection of its own.
fn get(url: const u8[:], buf: u8[>..]&, rep: Reply&) -> bool {
    var c = Client { .. };
    let ok = fetch(c, "GET", url, buf, rep);
    close(c);
    return ok;
}

fn post(url: const u8[:], body: const u8[:], content_type: const u8[:], buf: u8[>..]&,
        rep: Reply&) -> bool {
    var c = Client { .. };
    var h: u8[..256] = [];
    h.append("Content-Type: ");
    h.append(content_type[..min(content_type.len, 200)]);
    h.append("\r\n");
    let ok = fetch(c, "POST", url, buf, rep, body, h);
    close(c);
    return ok;
}
