# HTTP/1.1: server and client

Status: implemented. The library is `stdlib/http.goose`, built on
`src/runtime/runtime_net.h`. The guide is [`../http.md`](../http.md), and the
measurements are in `bench/http/` (`design.md` there is the plan,
`results.md` the numbers).

## Goal

The goal was an HTTP/1.1 server whose request loop matches a hand-written C
server, written as ordinary Goose with the HTTP parsing done in Goose. The
yardsticks are the TechEmpower *plaintext* test (pipelined, 16 deep) and its
*json* test (not pipelined), plus keep-alive request latency. A client
followed, sharing the parser's pieces.

TLS, HTTP/2 and WebSockets are out of scope. TLS belongs in a reverse
proxy.

## What Goose gives us, and what it rules out

Four facts from the spec and from the spawn benchmarks
(`bench/spawn/results.md`) shape the design.

1. **No shared memory.** Workers talk only through typed queues, and each
   worker copies every global it reaches. So each worker runs a server of
   its own: its own listener, event loop and connections. Nothing is locked
   or queued on the request path.
2. **Spawning is expensive.** It costs 12 µs plus about 10 µs per resizable
   region, and concurrent spawns contend on one lock. A worker per
   connection or per request is therefore out. A program spawns its workers
   once, and each one runs `serve` forever: the nginx shape.
3. **Per-connection buffers cannot be Goose resizables.** Each resizable is
   its own region (an `mmap` of a 256 MB reserve plus a guard). 10k
   connections would mean 10k regions. So the runtime keeps per-connection
   state: the socket, input not yet parsed, and output the socket did not
   take yet. A worker has just two Goose buffers, one for input and one for
   output, and reuses them for every connection.
4. **Handlers are static function values (§7.6).** `serve<F>` instantiates
   per handler, and `F(req, res)` is a direct call that can be inlined.
   Calling a handler costs nothing extra.

## Layers

```
 Goose  stdlib/http.goose   parse, serve<F>, Request/Response, the client
 ------ extern fn boundary  scalars, u8 slices, u8[>..]& builders
 C      runtime_net.h       gs_net_*: listen, the engine, client sockets
 OS     kqueue (macOS, BSD) | epoll (Linux) | Windows: not yet (calls fail)
```

The boundary carries only scalars, `u8` slices and builders. C never names a
Goose type, so the same runtime object serves every program, and the
standalone build declares nothing twice.

## The engine: `runtime_net.h`

The engine is one worker's event loop. Each engine is a kqueue or epoll
instance, a listener, and a table of connections. A connection handle is
its slot plus that slot's generation, so a stale handle names nothing.
Engines are numbered in a process-wide table, so a stray number is refused
rather than dereferenced. The engine moves bytes; it knows nothing of HTTP.

```c
int64_t gs_net_wait(int64_t engine, gs_rref buf);   /* blocks; appends a connection's input */
uint8_t gs_net_write(int64_t engine, int64_t conn, sl_u8 a, sl_u8 b);   /* writev a then b */
void    gs_net_done(int64_t engine, int64_t conn, sl_u8 rest, int64_t need, uint8_t close);
```

- **`wait`.**
  - It reads a ready connection's input straight onto the top of the
    worker's input builder: first what was kept from last time, then what
    the socket has. Writing to a data stack's top is what `gs_bld_append`
    does, and the region is reserved and committed on touch.
  - The common case of a whole request arriving in one segment therefore
    costs no copy in C.
  - If the program said it needs `need` bytes (a body's length), the engine
    keeps reading, and holds the input itself until that much is there. The
    program does not parse the same head again for every piece of a large
    body.
- **The program.** It parses every whole request in what it was given and
  appends every response to its output builder. Then it calls `write` once.
  This is the pipelining batch: 16 pipelined requests take one read and one
  write.
- **`done`.** This hands back the unparsed tail, which the engine copies
  into the connection's own buffer. That happens only when a request
  straddles two reads.
- **`write`.** This sends a head and a large body with one `writev`, without
  copying the body. Output the socket does not take is copied and sent when
  the socket allows. A connection marked to close is closed once its output
  is gone.
- **Housekeeping.** Accepted sockets get `TCP_NODELAY`, and `SO_NOSIGPIPE`
  or `MSG_NOSIGNAL`. Once a second, the engine closes connections idle
  longer than `idle_ms`. If the process runs out of descriptors, it stops
  accepting until the next second.

### Listening without sharing a socket

`serve(port)` opens a listener in each worker.

- **Linux.** That is a socket of its own with `SO_REUSEPORT`, and the
  kernel spreads connections across them.
- **macOS and the BSDs.** `SO_REUSEPORT` gives every connection to the
  socket bound last. The engine shows it: with four sockets bound,
  `[0, 0, 0, 2000]` connections arrived per socket. nginx's `reuseport`
  shows it too: under load one worker runs at 80% CPU and three sit idle.

So `gs_net_listen` keeps a small registry on macOS and the BSDs. The first
call for an address opens the socket, and later calls for the same address
get that socket back. Every engine waits on it, and the accept one of them
wins is that worker's connection. The program is written the same on every
platform.

## Parsing in Goose

`parse(s, req, limits)` parses one request at the start of `s`. It returns
one of:

- `(n, 0)` for a whole request of `n` bytes;
- `(0, need)` while it is not all there;
- `(-status, 0)` for a request to refuse.

It is a pure function of bytes, so it can be tested and benchmarked without
a socket (`bench/http/parse/`).

- **Strictness.** Lines must end in CRLF. Header names must be tokens, and
  values may not hold control bytes. A request that gives both
  `Content-Length` and chunked encoding, or two different lengths, is
  refused: those are how requests are smuggled past a proxy.
- **Chunked bodies.** A first pass finds a chunked body's end, without
  writing. Once the whole body is there, a second pass decodes it in place.
  Input that is still arriving is never changed.
- **Headers.** They are slices into the input, up to 64 per request.
  `Content-Length`, `Transfer-Encoding`, `Connection` and `Expect` are
  recognized by length first, and then compared ignoring case.

Two things about Goose shaped the code.

- **Bounds checks.** The analysis that removes them (§10.5) proves a scan
  like `while k < r.len { r[k] ... k++ }`. It loses track of a counter that
  also steps by 2 somewhere else in the function, and then keeps the checks
  in every loop on that counter. It also misses a table lookup nested in
  another index (`T[s[i]]`).
  - So each scan runs a fresh counter that counts up by one over the
    remaining input, `r`, and then cuts `r` past what it read. Table lookups
    go through a `let`.
  - The scans run without checks. The few checks left are once per header
    line, and a `--no-bce` build measures the same.
- **Building a Request.** `Request { .. }` writes all 64 header slots, about
  2 KB, though a limited array's free slots never need writing (§4.2). That
  costs about 15 ns, as much as parsing a small request. So `parse` resets a
  `Request` it is given, and `serve` builds one per batch of input rather
  than one per request. Both gaps are worth fixing in the compiler.

The scans that dominate, over header names and values, test 4 bytes per
step against a 256-entry class table. picohttpparser's arm64 path is scalar
too. The parse suite puts the Goose parser at 1.0–1.4x picohttpparser's time
per request. Chunked bodies are the exception, at about 2.3x.

## Responses

A handler fills in a `Response`:

- `status`;
- `content_type`, a `u8[..128]`;
- extra header lines, a `u8[..2048]` that `set_header` appends to and
  that refuses CR and LF;
- `body`, the struct's one resizable, at its tail.

`serve` writes the status line from a table, then `Server`, the `Date` the
runtime formats once a second, `Content-Type`, `Content-Length`,
`Connection: close` when closing, the extra lines and the body. A body of
16 KB or more goes out with its head through `writev`, without being
copied. Smaller ones are copied into the batch.

## The client

`fetch(c, method, url, buf, rep)` sends one request and reads its response,
on a connection the `Client` keeps open while the server allows it.

- **Parsing.** Status lines are parsed by `parse_reply_head`, and the
  header fields by the same `parse_fields` the server uses. Interim 1xx
  responses are skipped. `HEAD`, 204 and 304 have no body. Bodies are
  framed by chunked encoding, by `Content-Length`, or by the server closing
  the connection.
- **A closed kept connection.** If the server closed it before answering,
  the request goes once more on a new connection.
- **The buffer.** `fetch` appends the request and the response to `buf` and
  never shrinks it. A function that shrank `buf` and stored slices of it in
  `rep` could not be called while `rep` is in use, which is the whole point
  of `rep`. The caller clears `buf` between requests.
- **Large bodies.** Each read asks for as much as the response has so far,
  so a large body is parsed a logarithmic number of times.
- **Timeouts.** `SO_RCVTIMEO` and `SO_SNDTIMEO` bound every wait.

## A compiler bug found on the way

A `thread_spawn(...)` whose id was not used never ran. Codegen returned the
call as an expression for its caller to place, and an expression statement
drops its value. The spawn is now emitted where it is built
(`EmitThreadSpawn`). `test/threads/thread_spawn_discarded.goose` covers it.

## Not yet

- **Windows.** It needs IOCP, or `WSAPoll` with Winsock start-up and
  `ws2_32`. Until then the calls fail.
- **Linux.** It is written (epoll, per-worker `SO_REUSEPORT`) but has not
  been run.
- **A head deadline.** There is no separate deadline for a slow head. The
  idle timeout bounds it, because any byte counts as activity.
- **Static files.** `sendfile` would serve them.
- **Fuzzing.** A fuzz target over `parse` is still to come.
