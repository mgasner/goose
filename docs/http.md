# HTTP in Goose

`import http;` gives a Goose program an HTTP/1.1 server and client. Both are
written in Goose (`stdlib/http.goose`), on a small socket layer in the
runtime (`src/runtime/runtime_net.h`). The design and its reasons are in
[`design/http.md`](design/http.md). How fast it is, measured against nginx
and a libuv server in C, is in
[`../bench/http/results.md`](../bench/http/results.md).

The server and client run on macOS, Linux and the BSDs. On Windows every
call fails, as it does when a port cannot be opened. There is no TLS, so
put a TLS-terminating proxy in front of a server that faces the internet,
and don't use the client for `https://`.

Threads need a C compiler: build with `goose -o prog.c --standalone
prog.goose` and compile the result. The JIT cannot run threads.

---

## 1. A server

```goose
import std;
import os;
import http;

fn handle(req: http::Request&, res: http::Response&) {
    if req.path == "/hello" {
        res.body.append("Hello, World!");
    } else if req.path == "/json" {
        res.content_type = "application/json";
        format(res.body, "{\"n\":", req.headers.len, "}");
    } else {
        res.status = 404;
    }
}

thread_fn worker(port: i64) {
    if !http::serve(port, "0.0.0.0", http::Limits { .. }, handle) {
        print("cannot listen on ", port);
    }
}

fn main() {
    var ids: i64[>..] = [];
    for i in hardware_threads() { ids.push(thread_spawn(worker, 8080)); }
    for id in ids { thread_wait(id); }
}
```

Each worker calls `serve`, which listens on the port, then runs an event loop
for the connections that worker accepts and calls the handler for each
request. Workers share nothing (spec §11.2). Each one's globals are its own
copies, so a counter a handler increments counts that worker's requests
only. Gather such numbers through `qput` if you need a total.

The handler can also be a block:

```goose
thread_fn worker(port: i64) {
    http::serve(port) { req, res => res.body.append("hi"); };
}
```

### Requests

```goose
struct Request {
    method: const u8[:],          // "GET"
    target: const u8[:],          // "/search?q=goose", as sent
    path: const u8[:],            // "/search"
    query: const u8[:],           // "q=goose"
    minor: i64,                   // 1 for HTTP/1.1
    headers: Header[..64],        // { name, value }, in order
    body: const u8[:],            // decoded, if it was sent chunked
    keep_alive: bool,
    expect_continue: bool,
}
fn header(req: Request&, name: const u8[:]) -> const u8[:], bool     // ignores case
fn query_param(req: Request&, name: const u8[:]) -> const u8[:], bool  // still %-encoded
fn decode(out: u8[>..]&, s: const u8[:], plus: bool = false) -> bool  // %XX, and + as space
```

The slices view the buffer the request was read into. A request lives only
for the handler call it is given to.

### Responses

```goose
struct Response {
    status: i64 = 200,
    close: bool = false,                    // close the connection after this
    content_type: u8[..128] = "text/plain",
    headers: u8[..2048] = [],               // set_header adds lines here
    body: u8[>..] = [],
}
fn set_header(res: Response&, name: const u8[:], value: const u8[:]) -> bool
```

The server writes the status line, `Server`, `Date`, `Content-Type`,
`Content-Length`, your headers, then the body. A `HEAD` request gets the
headers alone. Bodies under 16 KB are copied into one write with the other
responses in the same batch. Larger ones are written from where the handler
built them, beside their head, in one `writev`.

### What the server does for you

- **Keep-alive and pipelining.** Every request already read on a
  connection is answered, and the answers go out in one write.
- **Bodies.** It frames them by `Content-Length` or chunked encoding, and
  decodes chunked bodies in place. It answers `Expect: 100-continue`.
- **Refusals.** It refuses malformed requests with 400 and closes the
  connection: bare LF, bad header names, control bytes, and requests that
  give both `Content-Length` and chunked encoding or two different
  lengths. It answers 413 past `max_body`, 431 past `max_head` or 64
  headers, 501 for a transfer coding other than chunked, and 505 for
  anything but HTTP/1.x.
- **Idle connections.** It closes a connection that has been silent for
  `idle_ms`.

```goose
struct Limits {
    max_head: i64 = 8192,
    max_body: i64 = 1 << 20,
    idle_ms: i64 = 5000,
}
```

### Listening

`serve(port, host)` opens its own listener. On Linux, each worker's
listener is a socket of its own with `SO_REUSEPORT`, and the kernel spreads
connections across them. On macOS and the BSDs, `SO_REUSEPORT` sends every
connection to the socket bound last. There, the workers that listen on one
address share the socket the first of them opened, and whichever accepts a
connection first serves it. Either way the program is written the same.

`http::listen(port, host)` opens a listener without serving it, and
`listener_port` returns its port. For a test, listen on port 0 and hand the
socket to a worker:

```goose
thread_fn server(listener: i64) { http::serve_on(listener, http::Limits { .. }, handle); }

let l = http::listen(0, "127.0.0.1");
thread_spawn(server, l);
let port = http::listener_port(l);
```

---

## 2. A client

```goose
var buf: u8[>..] = [];
var rep = http::Reply { .. };
if http::get("http://127.0.0.1:8080/hello", buf, rep) {
    print(rep.status, " ", rep.body);
}
http::post("http://127.0.0.1:8080/echo", "{}", "application/json", buf, rep);
```

```goose
struct Reply {
    status: i64,
    minor: i64,
    reason: const u8[:],
    headers: Header[..64],
    body: const u8[:],            // decoded, if it came chunked
    keep_alive: bool,
}
fn header(rep: Reply&, name: const u8[:]) -> const u8[:], bool
```

`get` and `post` open a connection for one request. A `Client` keeps its
connection open between requests to the same host, for as long as the
server allows:

```goose
var c = http::Client { timeout_ms: 5000, .. };
for i in 100 {
    buf.clear();
    if !http::fetch(c, "GET", "http://127.0.0.1:8080/hello", buf, rep) {
        print("failed: ", c.error);
        break;
    }
}
http::close(c);
```

```goose
fn fetch(c: Client&, method: const u8[:], url: const u8[:], buf: u8[>..]&, rep: Reply&,
         body: const u8[:] = "", headers: const u8[:] = "") -> bool
```

`headers` holds extra request lines, each `Name: value\r\n`. `fetch`
appends the request and the response to `buf` and never shrinks it, so
`rep`'s slices stay valid. Clear `buf` between requests once nothing views
it.

- **Response bodies.** The client reads bodies framed by
  `Content-Length`, chunked encoding, or the server closing the
  connection. It skips interim 1xx responses and reads no body after
  `HEAD`, 204 or 304.
- **Closed connections.** If the server closed a kept connection before
  answering, the client sends the request again once, on a new connection.
- **Limits.** A send or receive that waits longer than `timeout_ms`
  fails, and so does a body larger than `max_body` (64 MB by default).
  `c.error` says why.

URLs are `http://host[:port][/path][?query]`. A fragment is dropped. IPv6
addresses go in brackets. `https://` URLs and `user@` URLs are refused.

---

## 3. Parsing alone

The parser is a function of bytes, and can be used without a socket:

```goose
fn parse(s: u8[:], req: Request&, limits: Limits) -> i64, i64
fn parse_reply(s: u8[:], rep: Reply&, head_only: bool, eof: bool, max_body: i64) -> i64
```

`parse` returns one of:

- `(n, 0)` for a whole request of `n` bytes;
- `(0, need)` while the request is not all there, where `need` is the total
  byte count once the head gives it;
- `(-status, 0)` for a request to refuse.
