// The http package over TLS: serve_tls workers on ephemeral ports with the
// test-only certificates in test/tls/certs/ (README there), driven by the
// https:// client. GET and POST, keep-alive and the retry once an idle
// connection was closed, large bodies both ways, a chunked response, a
// certificate from an untrusted CA, one for another host name, a server
// that cannot load its key, and clients on several threads at once. Runs
// only where the http package is built with TLS (packages/http/CMakeLists.txt);
// everything is local.
import std;
import os;
import http;

fn ca() -> const u8[:] { "test/tls/certs/ca.pem" }
fn rogue_ca() -> const u8[:] { "test/tls/certs/rogue_ca.pem" }
fn cert() -> const u8[:] { "test/tls/certs/server.pem" }
fn key() -> const u8[:] { "test/tls/certs/server.key" }
fn other_cert() -> const u8[:] { "test/tls/certs/other.pem" }
fn other_key() -> const u8[:] { "test/tls/certs/other.key" }

fn handle(req: http::Request&, res: http::Response&) {
    if req.path == "/hello" {
        res.body.append("Hello over TLS");
    } else if req.path == "/echo" {
        res.content_type = "application/octet-stream";
        res.body.append(req.body);
    } else if req.path == "/big" {
        for i in 1000000 { res.body.push(('a' + i % 26) as u8); }
    } else {
        res.status = 404;
    }
}

thread_fn server(listener: i64) {
    if !http::serve_tls_on(listener, cert(), key(), http::Limits { max_body: 1 << 24, .. }, handle) {
        var why: u8[>..] = [];
        http::tls_error(why);
        print("serve_tls_on failed: ", why);
    }
}

thread_fn quick_server(listener: i64) {
    http::serve_tls_on(listener, cert(), key(), http::Limits { idle_ms: 300, .. }, handle);
}

thread_fn other_server(listener: i64) {
    http::serve_tls_on(listener, other_cert(), other_key(), http::Limits { .. }, handle);
}

// A server on the engine itself, which answers every request with a chunked
// body: the http server frames its own bodies by length, and the client
// must also read chunked ones over TLS.
thread_fn chunked_server(listener: i64) {
    let engine = http::net_open_tls(listener, 5000, cert(), key());
    if engine < 0 { return; }
    var buf: u8[>..] = [];
    loop {
            let conn = http::net_wait(engine, buf);
        if conn < 0 { break; }
        var at = 0;
        var req = http::Request { .. };
        var out: u8[>..] = [];
        while at < buf.len {
            let n, want = http::parse(buf[at..], req, http::Limits { .. });
            if n <= 0 { break; }
            out.append("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
            out.append("5\r\nhello\r\n");
            out.append("7;ext=1\r\n, TLS, \r\n");
            var long: u8[>..] = [];
            push_n(long, 'z', 40000);
            format(out, "9c40\r\n", long, "\r\n");
            out.append("0\r\nTrailer: yes\r\n\r\n");
            at += n;
        }
        http::net_write(engine, conn, out, "");
        http::net_done(engine, conn, buf[at..], 0, false);
    }
}

struct Done { ok: i64, same: bool }

// One client per thread, each with its own TLS configuration and session.
thread_fn client(port: i64) {
    var c = http::Client { ca_file: ca(), .. };
    var ok = 0;
    var fd0 = -1;
    var same = true;
    for i in 20 {
        var buf: u8[>..] = [];
        var rep = http::Reply { .. };
        if http::fetch(c, "POST", str("https://localhost:", port, "/echo"), buf, rep,
                       str("request ", i)) &&
           rep.body == str("request ", i) {
            ok++;
        }
        if i == 0 { fd0 = c.fd; } else if c.fd != fd0 { same = false; }
    }
    http::close(c);
    qput(Done { ok: ok, same: same });
}

fn main() {
    print("tls available: ", http::tls_available());

    print("-- get and post");
    let l = http::listen(0, "127.0.0.1");
    let port = http::listener_port(l);
    thread_spawn(server, l);
    thread_spawn(server, l);   // a second worker, with its own engine and keys
    let base = str("https://localhost:", port);
    var c = http::Client { ca_file: ca(), .. };
    var buf: u8[>..] = [];
    var rep = http::Reply { .. };
    print(http::fetch(c, "GET", str(base, "/hello"), buf, rep), " ", rep.status, " ", rep.body,
          " keep=", rep.keep_alive, " ", c.error);
    let fd0 = c.fd;
    print(http::fetch(c, "POST", str(base, "/echo"), buf, rep, "posted over TLS"), " ",
          rep.status, " ", rep.body);
    print("keep-alive: same connection=", c.fd == fd0, " tls=", c.tls >= 0);
    print(http::fetch(c, "GET", str(base, "/big"), buf, rep), " ", rep.body.len, " ",
          rep.body[999974..]);
    var big: u8[>..] = [];
    for i in 6000000 { big.push(('0' + i % 10) as u8); }
    print(http::fetch(c, "POST", str(base, "/echo"), buf, rep, big), " ", rep.body.len, " ",
          rep.body == big, " same connection=", c.fd == fd0);
    print(http::fetch(c, "GET", str(base, "/nope"), buf, rep), " ", rep.status);
    // The Host header carries no port for 443, and the scheme decides
    // whether a kept connection fits: http:// to the same port opens anew.
    print(http::fetch(c, "GET", str("http://localhost:", port, "/hello"), buf, rep));
    http::close(c);
    // By address: the certificate names 127.0.0.1 too.
    var byip = http::Client { ca_file: ca(), .. };
    print(http::fetch(byip, "GET", str("https://127.0.0.1:", port, "/hello"), buf, rep), " ",
          rep.body);
    http::close(byip);

    print("-- chunked");
    let cl = http::listen(0, "127.0.0.1");
    thread_spawn(chunked_server, cl);
    let cport = http::listener_port(cl);
    var cc = http::Client { ca_file: ca(), .. };
    for i in 2 {
        let ok = http::fetch(cc, "GET", str("https://localhost:", cport, "/"), buf, rep);
        print(ok, " ", rep.body.len, " ", rep.body[..14], " keep=", rep.keep_alive, " ",
              cc.error);
    }
    http::close(cc);

    print("-- idle close, then retry");
    let ql = http::listen(0, "127.0.0.1");
    thread_spawn(quick_server, ql);
    let qport = http::listener_port(ql);
    var q = http::Client { ca_file: ca(), .. };
    print(http::fetch(q, "GET", str("https://localhost:", qport, "/hello"), buf, rep), " ",
          rep.body);
    let qfd = q.fd;
    sleep_ms(1500);   // past the once-a-second sweep for connections idle 300 ms
    print(http::fetch(q, "GET", str("https://localhost:", qport, "/hello"), buf, rep), " ",
          rep.body, " ", q.error, " reopened=", q.fd >= 0);
    http::close(q);

    print("-- verification");
    var rogue = http::Client { ca_file: rogue_ca(), .. };
    print(http::fetch(rogue, "GET", str(base, "/hello"), buf, rep), " ", rogue.error,
          " open=", rogue.fd >= 0);
    // The system's CAs do not include the test CA either.
    var sys = http::Client { .. };
    print(http::fetch(sys, "GET", str(base, "/hello"), buf, rep));
    let ol = http::listen(0, "127.0.0.1");
    thread_spawn(other_server, ol);
    let oport = http::listener_port(ol);
    var other = http::Client { ca_file: ca(), .. };
    print(http::fetch(other, "GET", str("https://localhost:", oport, "/hello"), buf, rep), " ",
          other.error);
    var missing = http::Client { ca_file: "test/tls/certs/none.pem", .. };
    print(http::fetch(missing, "GET", str(base, "/hello"), buf, rep), " ",
          starts_with(missing.error, "TLS: cannot read the CA bundle"));
    // Named for what it is: no verification at all, so it takes the
    // certificate for another name.
    var insecure = http::Client { insecure_skip_verify: true, .. };
    print(http::fetch(insecure, "GET", str("https://localhost:", oport, "/hello"), buf, rep),
          " ", rep.body);
    http::close(insecure);
    // TLS to a server that does not speak it.
    let plain = http::listen(0, "127.0.0.1");
    let pport = http::listener_port(plain);
    var notls = http::Client { timeout_ms: 2000, ca_file: ca(), .. };
    print(http::fetch(notls, "GET", str("https://localhost:", pport, "/"), buf, rep), " ",
          starts_with(notls.error, "TLS: "));
    http::close(plain);

    print("-- server keys");
    let bl = http::listen(0, "127.0.0.1");
    print(http::serve_tls_on(bl, "test/tls/certs/none.pem", key(), http::Limits { .. }, handle));
    var why: u8[>..] = [];
    http::tls_error(why);
    print(why);
    why.clear();
    print(http::serve_tls_on(bl, cert(), other_key(), http::Limits { .. }, handle));
    http::tls_error(why);
    print(starts_with(why, "TLS: the key does not go with the certificate"));

    print("-- threads");
    var ids: i64[>..] = [];
    for i in 3 { ids.push(thread_spawn(client, port)); }
    for id in ids { thread_wait(id); }
    for i in 3 {
        let d = qget<Done>();
        print(d.ok, " ", d.same);
    }
}
