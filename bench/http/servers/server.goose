// The benchmark server (bench/http/design.md): the routes every server in
// the suite answers, byte for byte the same.
//
//   server <port> <workers>

import std;
import os;
import http;

// What /bytes/<n> serves a prefix of; each worker gets its own copy.
var blob: u8[>..] = [];

fn handle(req: http::Request&, res: http::Response&) {
    if req.path == "/plaintext" {
        res.body.append("Hello, World!");
    } else if req.path == "/json" {
        res.content_type = "application/json";
        format(res.body, "{\"message\":\"", "Hello, World!", "\"}");
    } else if starts_with(req.path, "/bytes/") {
        let n, ok = parse_int(req.path[7..]);
        if ok && n >= 0 && n <= blob.len {
            res.content_type = "application/octet-stream";
            res.body.append(blob[..n]);
        } else {
            res.status = 400;
        }
    } else if req.path == "/echo" {
        format(res.body, req.body.len);
    } else {
        res.status = 404;
    }
}

thread_fn worker(port: i64) {
    if !http::serve(port, "127.0.0.1", http::Limits { max_body: 1 << 24, .. }, handle) {
        print("cannot listen on port ", port);
    }
}

fn main() {
    let a = args();
    guard a.len == 3 else { abort("usage: server <port> <workers>"); }
    let port, pok = parse_int(a[1]);
    let workers, wok = parse_int(a[2]);
    guard pok && wok && workers > 0 else { abort("usage: server <port> <workers>"); }
    push_n(blob, 'x', 1 << 20);
    var ids: i64[>..] = [];
    for i in workers { ids.push(thread_spawn(worker, port)); }
    for id in ids { thread_wait(id); }
}
