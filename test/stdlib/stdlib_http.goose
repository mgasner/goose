// runtime-debug: stdlib/http.goose: the request parser on whole, partial
// and malformed input; the response parser and URLs; then a server worker
// on an ephemeral port, driven by the client and by raw sockets. Date
// headers are left out of what is printed.
import std;
import os;
import http;

fn show_parse(text: const u8[:]) {
    var buf: u8[>..] = [];
    buf.append(text);
    var req = http::Request { .. };
    let n, need = http::parse(buf, req, http::Limits { max_head: 256, max_body: 64, .. });
    if n <= 0 {
        print(n, " need ", need);
        return;
    }
    print(n, " ", req.method, " ", req.path, " [", req.query, "] 1.", req.minor, " h=",
          req.headers.len, " body=", req.body, " keep=", req.keep_alive);
}

fn parse_tests() {
    print("-- requests");
    show_parse("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    show_parse("GET /p?x=1&y HTTP/1.0\r\nHost: a\r\nConnection: Keep-Alive\r\n\r\n");
    show_parse("GET / HTTP/1.1\r\nConnection: upgrade, close\r\n\r\n");
    show_parse("POST /e HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloEXTRA");
    show_parse("POST /e HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\nT: v\r\n\r\n");
    show_parse("GET / HTTP/1.1\r\nX:   padded value \t\r\n\r\n");
    print("-- incomplete");
    show_parse("GE");
    show_parse("GET / HTTP/1.1\r\nHost: a\r\n");
    show_parse("POST /e HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel");
    show_parse("POST /e HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab");
    print("-- refused");
    show_parse("GET  / HTTP/1.1\r\n\r\n");                                  // 400: empty target
    show_parse("GET / HTTP/1.1\nHost: a\n\n");                               // 400: bare LF
    show_parse("GET / HTTP/2.0\r\n\r\n");                                    // 505
    show_parse("GET / HTTP/1.1\r\nBad Name: x\r\n\r\n");                     // 400
    show_parse("GET / HTTP/1.1\r\nX: a\x01b\r\n\r\n");                       // 400: a control byte
    show_parse("POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n");
    show_parse("POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n");
    show_parse("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n");        // 501
    show_parse("POST / HTTP/1.1\r\nContent-Length: 65\r\n\r\n");             // 413
    show_parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n");             // 400
    show_parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n");
    var big: u8[>..] = [];
    big.append("GET / HTTP/1.1\r\nX: ");
    push_n(big, 'v', 300);
    show_parse(big);                                                         // 431, incomplete
    big.append("\r\n\r\n");
    show_parse(big);                                                         // 431, whole
    var many: u8[>..] = [];
    many.append("GET / HTTP/1.1\r\n");
    for i in 65 { many.append("A: b\r\n"); }
    many.append("\r\n");
    var req = http::Request { .. };
    let n, need = http::parse(many, req, http::Limits { .. });
    print("65 headers: ", n);

    print("-- query and decoding");
    var qb: u8[>..] = [];
    qb.append("GET /s?q=a%20b+c&empty&n=1 HTTP/1.1\r\nHost: h\r\n\r\n");
    var q = http::Request { .. };
    http::parse(qb, q, http::Limits { .. });
    let v, found = http::query_param(q, "q");
    var dec: u8[>..] = [];
    print(found, " ", v, " ", http::decode(dec, v, true), " ", dec);
    let e, efound = http::query_param(q, "empty");
    print(efound, " [", e, "]");
    let m, mfound = http::query_param(q, "missing");
    print(mfound);
    let h, hfound = http::header(q, "HOST");
    print(hfound, " ", h);
    dec.clear();
    print(http::decode(dec, "%zz", false));
}

fn show_reply(text: const u8[:], head_only: bool, eof: bool) {
    var buf: u8[>..] = [];
    buf.append(text);
    var rep = http::Reply { .. };
    let n = http::parse_reply(buf, rep, head_only, eof, 1024);
    if n <= 0 {
        print(n);
        return;
    }
    print(n, " ", rep.status, " [", rep.reason, "] h=", rep.headers.len, " body=", rep.body,
          " keep=", rep.keep_alive);
}

fn reply_tests() {
    print("-- responses");
    show_reply("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi", false, false);
    show_reply("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n1\r\n!\r\n0\r\n\r\n", false, false);
    show_reply("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n", false, false);
    show_reply("HTTP/1.0 200 OK\r\n\r\nuntil close", false, false);
    show_reply("HTTP/1.0 200 OK\r\n\r\nuntil close", false, true);
    show_reply("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n", true, false);
    show_reply("HTTP/1.1 404\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", false, false);
    show_reply("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nhi", false, false);
    show_reply("HTTX/1.1 200 OK\r\n\r\n", false, false);

    print("-- urls");
    for url in ["http://example.com", "http://example.com:8080/a/b?c=d#frag", "http://[::1]:9/x",
                "https://example.com/", "http://user@host/", "http://host:0/", "http:///x",
                "http://host/a b"] {
        var u = http::Url { host: "", port: 0, target: "", bracket: false };
        if http::parse_url(url, u) {
            print(url, " -> ", u.host, " ", u.port, " [", u.target, "]");
        } else {
            print(url, " -> refused");
        }
    }
}

// --- a live server ---------------------------------------------------------

fn handle(req: http::Request&, res: http::Response&) {
    if req.path == "/hello" {
        res.body.append("Hello, World!");
    } else if req.path == "/echo" {
        res.content_type = "application/octet-stream";
        res.body.append(req.body);
    } else if req.path == "/big" {
        push_n(res.body, 'z', 100000);
    } else if req.path == "/header" {
        let v, ok = http::header(req, "x-thing");
        http::set_header(res, "X-Got", if ok { v } else { "none" });
        res.status = 201;
    } else if req.path == "/close" {
        res.close = true;
        res.body.append("bye");
    } else {
        res.status = 404;
    }
}

thread_fn server(listener: i64) {
    http::serve_on(listener, http::Limits { max_body: 1 << 20, .. }, handle);
}

thread_fn quick_server(listener: i64) {
    http::serve_on(listener, http::Limits { idle_ms: 300, .. }, handle);
}

// A connection silent past idle_ms is closed; one whose body arrives a byte
// at a time, each sooner than idle_ms but all of it later, is not.
fn idle_tests() {
    print("-- idle");
    let l = http::listen(0, "127.0.0.1");
    let port = http::listener_port(l);
    thread_spawn(quick_server, l);
    let fd = http::connect("127.0.0.1", port, 5000);
    // 1.5 s in all, past the engine's once-a-second sweep for idle connections.
    let body = "slowly uploaded";
    http::send(fd, str("POST /echo HTTP/1.1\r\nContent-Length: ", body.len,
                       "\r\nConnection: close\r\n\r\n"));
    for c in body {
        sleep_ms(100);
        var one: u8[..1] = [];
        one.push(c);
        http::send(fd, one);
    }
    var got: u8[>..] = [];
    while http::recv(fd, got, 65536) > 0 {}
    http::close(fd);
    show_raw(got);
    let quiet = http::connect("127.0.0.1", port, 5000);
    let t0 = clock_ns();
    var none: u8[>..] = [];
    let n = http::recv(quiet, none, 64);
    let waited = (clock_ns() - t0) / 1000000;
    print("silent connection: recv ", n, ", closed after 300 ms or more: ", waited >= 250);
    http::close(quiet);
}

// What the server sent, its Date lines left out.
fn show_raw(bytes: const u8[:]) {
    var out: u8[>..] = [];
    each_split(bytes, "\r\n") {
        if !starts_with(it, "Date: ") {
            out.append(it);
            out.append("|");
        }
    };
    print(out);
}

// Sends raw bytes on a fresh connection and reads until the server closes.
fn raw(port: i64, text: const u8[:]) {
    let fd = http::connect("127.0.0.1", port, 5000);
    if !http::send(fd, text) { print("send failed"); }
    var got: u8[>..] = [];
    while http::recv(fd, got, 65536) > 0 {}
    http::close(fd);
    show_raw(got);
}

fn live_tests() {
    print("-- live");
    let l = http::listen(0, "127.0.0.1");
    let port = http::listener_port(l);
    print(l >= 0, " ", port > 0);
    thread_spawn(server, l);
    let base = str("http://127.0.0.1:", port);

    var c = http::Client { .. };
    var buf: u8[>..] = [];
    var rep = http::Reply { .. };
    print(http::fetch(c, "GET", str(base, "/hello"), buf, rep), " ", rep.status, " ", rep.body,
          " keep=", rep.keep_alive);
    let fd0 = c.fd;
    print(http::fetch(c, "POST", str(base, "/echo"), buf, rep, "posted body"), " ", rep.status,
          " ", rep.body, " same connection=", c.fd == fd0);
    let ct, has = http::header(rep, "content-type");
    print(ct);
    print(http::fetch(c, "GET", str(base, "/big"), buf, rep), " ", rep.body.len);
    print(http::fetch(c, "HEAD", str(base, "/big"), buf, rep), " ", rep.body.len, " ",
          http::header(rep, "content-length"));
    print(http::fetch(c, "GET", str(base, "/header"), buf, rep, "", "X-Thing: yes\r\n"), " ",
          rep.status, " ", http::header(rep, "x-got"));
    print(http::fetch(c, "GET", str(base, "/nope"), buf, rep), " ", rep.status, " ", rep.reason);
    print(http::fetch(c, "GET", str(base, "/close"), buf, rep), " ", rep.body, " keep=",
          rep.keep_alive, " open=", c.fd >= 0);
    print(http::fetch(c, "GET", str(base, "/hello"), buf, rep), " ", rep.body);
    http::close(c);
    print(http::get(str(base, "/hello"), buf, rep), " ", rep.body);
    print(http::post(str(base, "/echo"), "{}", "application/json", buf, rep), " ", rep.body);
    var big: u8[>..] = [];
    push_n(big, 'q', 300000);
    print(http::post(str(base, "/echo"), big, "text/plain", buf, rep), " ", rep.body.len,
          " ", rep.body == big);
    print(http::get("http://127.0.0.1:1/", buf, rep));
    var bad = http::Client { .. };
    print(http::fetch(bad, "GET", "https://example.com/", buf, rep), " ", bad.error);

    print("-- raw");
    raw(port, "GET /hello HTTP/1.1\r\nHost: x\r\n\r\nGET /nope HTTP/1.1\r\nHost: x\r\n\r\nGET /close HTTP/1.1\r\n\r\n");
    raw(port, "POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    // Expect: 100-continue: the server says go on before the body is sent.
    let fd = http::connect("127.0.0.1", port, 5000);
    http::send(fd, "POST /echo HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\nConnection: close\r\n\r\n");
    var cont: u8[>..] = [];
    http::recv(fd, cont, 65536);
    show_raw(cont);
    http::send(fd, "body");
    var rest: u8[>..] = [];
    while http::recv(fd, rest, 65536) > 0 {}
    http::close(fd);
    show_raw(rest);
    raw(port, "GET /hello HTTP/1.0\r\n\r\n");
    raw(port, "GET /hello HTTP/1.1\r\nBad Header\r\n\r\n");
    raw(port, "HEAD /hello HTTP/1.1\r\nConnection: close\r\n\r\n");
}

fn main() {
    parse_tests();
    reply_tests();
    live_tests();
    idle_tests();
}
