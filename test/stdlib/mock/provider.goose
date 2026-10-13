// A mock model provider for the inference and agent fixtures: an http
// server worker on an ephemeral port that answers each request with the
// next canned reply from a queue, and hands every request it gets back on
// another queue, so a test can print exactly what the client sent.
import std;
import http;

struct Canned { status: i64, headers: u8[], body: u8[] }       // headers: "Name: value\n" lines
struct Seen { path: u8[], headers: u8[], body: u8[] }

fn answer(req: http::Request&, res: http::Response&) {
    var hs: u8[>..] = [];
    for name in ["content-type", "x-api-key", "anthropic-version", "anthropic-beta", "authorization",
                 "x-echo-key"] {
        let v, ok = http::header(req, name);
        if ok { format(hs, name, ": ", v, "; "); }
    }
    qput(Seen { path: req.path, headers: hs[..], body: req.body });
    let c = qget<Canned>();
    res.status = c.status;
    res.content_type = "application/json";
    each_split(c.headers, '\n') {
        let colon = position(it, ':');
        if colon > 0 { http::set_header(res, it[..colon], trim(it[colon + 1..])); }
    };
    res.body.append(c.body);
}

thread_fn mock(listener: i64) {
    http::serve_on(listener, http::Limits { max_body: 1 << 20, .. }, answer);
}

fn reply(status: i64, body: const u8[:], headers: const u8[:] = "") {
    qput(Canned { status: status, headers: headers, body: body });
}

// Prints the request the mock got last.
fn seen() {
    let s = qget<Seen>();
    print("  POST ", s.path, "  ", s.headers);
    print("  ", s.body);
}

// The same, when only that it came matters.
fn seen_again() {
    let s = qget<Seen>();
    print("  POST ", s.path, " again, ", s.body.len, " bytes");
}

// Starts the mock; its base URL.
fn start_mock() -> u8[>..] {
    let l = http::listen(0, "127.0.0.1");
    thread_spawn(mock, l);
    return str("http://127.0.0.1:", http::listener_port(l));
}
