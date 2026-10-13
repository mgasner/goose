# HTTP/1.1: server and client

Status: implemented. The library is the blessed package `http`
(`packages/http`): `http.goose`, built on its native part,
`src/http_layer.c`. It began as a stdlib module over a socket layer in the
runtime (`runtime_net.h`); with upstream's package model it moved, C and
all, into a package, as sqlite did. The C used nothing of the runtime, so
none of it stayed behind. The guide is [`../http.md`](../http.md), and the
measurements are in `bench/http/` (`design.md` there is the plan,
`results.md` the numbers).

## Goal

The goal was an HTTP/1.1 server whose request loop matches a hand-written C
server, written as ordinary Goose with the HTTP parsing done in Goose. The
yardsticks are the TechEmpower *plaintext* test (pipelined, 16 deep) and its
*json* test (not pipelined), plus keep-alive request latency. A client
followed, sharing the parser's pieces.

HTTP/2 and WebSockets are out of scope. TLS came later, for clients of
hosted APIs that only speak HTTPS (the `inference` library). It is built on
Mbed TLS, and is an optional part of the package ([TLS](#tls) below).

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
   connections would mean 10k regions. So the C layer keeps per-connection
   state: the socket, input not yet parsed, and output the socket did not
   take yet. A worker has just two Goose buffers, one for input and one for
   output, and reuses them for every connection.
4. **Handlers are static function values (§7.6).** `serve<F>` instantiates
   per handler, and `F(req, res)` is a direct call that can be inlined.
   Calling a handler costs nothing extra.

## Layers

```
 Goose  http.goose          parse, serve<F>, Request/Response, the client
 ------ extern fn boundary  scalars, u8 slices, u8[>..]& builders
 C      src/http_layer.c    gs_http_*: listen, the engine, client sockets
        src/tls_layer.c     the TLS layer over Mbed TLS (optional)
 OS     kqueue (macOS, BSD) | epoll (Linux) | Windows: not yet (calls fail)
```

The boundary carries only scalars, `u8` slices and builders, as
`src/http_api.h` lists them (`test/api_check.py` checks `http.goose`
against it). C never names a Goose type beyond the slice and builder
layouts the header spells out, and uses nothing of the runtime.

## The engine: `src/http_layer.c`

The engine is one worker's event loop. Each engine is a kqueue or epoll
instance, a listener, and a table of connections. A connection handle is
its slot plus that slot's generation, so a stale handle names nothing.
Engines are numbered in a process-wide table, so a stray number is refused
rather than dereferenced. The engine moves bytes; it knows nothing of HTTP.

```c
int64_t gs_http_wait(int64_t engine, gs_http_builder buf);   /* blocks; appends a connection's input */
uint8_t gs_http_write(int64_t engine, int64_t conn, gs_http_bytes a, gs_http_bytes b);   /* writev a then b */
void    gs_http_done(int64_t engine, int64_t conn, gs_http_bytes rest, int64_t need, uint8_t close);
```

- **`wait`.**
  - It reads a ready connection's input straight onto the top of the
    worker's input builder: first what was kept from last time, then what
    the socket has. Writing to a data stack's top is what the runtime's
    `gs_bld_append` does (the layer has its own copy, `gs_http_append`), and the region is reserved and committed on touch.
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

So `gs_http_listen` keeps a small registry on macOS and the BSDs. The first
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
C layer formats once a second, `Content-Type`, `Content-Length`,
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

## TLS

### Where it lives

TLS is two pieces, both in the http package:

- **The layer** (`src/tls_layer.c`, over Mbed TLS 3.6). It is plain C
  that knows nothing of Goose. It opens client sessions over a connected
  socket and server sessions over an accepted one, and steps, reads and
  writes them. `src/tls_api.h` lists its functions.
- **The engine and client sockets** (`src/http_layer.c`). They call the
  layer through a table of its functions, `gs_net_tls_ops`, set when the
  package is built with the layer (`GS_HTTP_TLS`) and empty otherwise, so
  they are written once for TCP and TLS and never name Mbed TLS. Without the
  layer, `https://` and `serve_tls` fail with an error that says how to
  build with TLS; `gs_http_tls_available` reports which it is.

TLS is part of the http package rather than a package of its own because
the engine calls it from C, and one package's C part may not call
another's (docs/design/packages.md §5.5).

Mbed TLS is vendored the way SQLite is: upstream's package model fetches
packages from git, but has no fetcher for a third-party release tarball, so
`scripts/fetch_mbedtls.py` fetches a pinned release into
`third_party/mbedtls` and checks its SHA-256. The package's
`CMakeLists.txt` looks for it in its own `third_party/mbedtls`, then the
Goose tree's (or `GOOSE_MBEDTLS_DIR`), and builds it into
`goose_http_mbedtls` with `src/mbedtls_user_config.h`, which turns
threading on and DTLS, renegotiation and debugging off. Without it, or with
`-DGOOSE_HTTP_TLS=OFF`, the package builds without TLS and nothing else
changes. Mbed TLS was chosen over OpenSSL because it builds from source with
no configure step, and over BearSSL because it does TLS 1.3. The 3.6 branch
is supported until at least March 2027; 4.x changes the API.

### The client

`fetch` connects as before. For `https://` it then opens a session over the
socket (`gs_http_tls_client`) and sends and receives through it.

- **Verification.** Verification is required. The CAs are the PEM bundle in
  `Client.ca_file`, or the system's: `SSL_CERT_FILE`, then the usual paths
  (`/etc/ssl/cert.pem` first). `mbedtls_ssl_set_hostname` sets both SNI and
  the name checked against the certificate's DNS and IP subject
  alternative names.
- **Versions.** TLS 1.2 to 1.3.
- **Turning it off.** `insecure_skip_verify` is the only way, and its name
  says what it does.
- **Blocking.** The socket stays blocking, with `SO_RCVTIMEO` and
  `SO_SNDTIMEO`. A timeout inside the session is an error, not a retry.
- **Receiving.** `gs_http_tls_recv` blocks for one record, then takes what
  the session already holds and what the socket has without waiting, up to
  what the caller asked for. So a large body is still parsed a logarithmic
  number of times, not once per 16 KB record.
- **A closed kept connection.** The server's `close_notify`, or its EOF,
  reads as the end of the stream. So the retry on a kept connection the
  server closed works as it does for TCP: the request goes again on a new
  connection, with a new handshake.

Sessions are named like engines: a slot in a process-wide table plus a
generation, so a stale handle is refused.

### The server

`serve_tls` opens an engine with a TLS configuration, which is that
engine's own certificate chain, key and random generator. The engine stays
the same loop.

- **Accepting.** Each accepted connection gets a session in non-blocking
  mode. Its handshake is stepped on each event, with write interest armed
  while the handshake waits to write.
- **Reading.** Input is read through the session straight onto the
  worker's builder, as before. Unlike a socket, a session can hold
  decrypted input the poller will not report. So a TLS connection is read
  until the session says it would block. A turn cut short at 4 MB marks the
  connection, and the engine serves marked connections before it polls
  again.
- **Writing.** Output always goes through the connection's buffer, since
  encrypting copies it anyway. That buffer also keeps the bytes for the
  retry Mbed TLS requires after `WANT_WRITE`. A large body therefore loses
  its `writev`.
- **Closing.** A `close_notify` is sent if the socket takes it at once.

The server was cheap to fit because the engine already had what it needs:
per-connection buffers, write interest, and one owner per connection.

### Threads

Spec §11.2 says workers share nothing. TLS keeps to that.

- **Nothing is shared.** Every session and configuration belongs to one
  thread. A client's configurations (one per CA bundle, holding the parsed
  bundle and a CTR-DRBG) are kept per thread, and freed by a
  `pthread_key` destructor when the thread exits. A server's belong to its
  engine.
- **What Mbed TLS keeps for the process.** That is the PSA crypto core,
  which TLS 1.3 runs on. With `MBEDTLS_THREADING_C` it locks its own state,
  and Mbed TLS requires that option once more than one thread does TLS. The
  layer also makes the process-wide state Mbed TLS would otherwise fill in
  lazily once, under `pthread_once`. That is `psa_crypto_init`, and the list
  of supported cipher suites, which `mbedtls_ssl_config_defaults` fills in
  on first use with no lock. ThreadSanitizer found that race in the test
  of three client threads and two server workers starting at once.

**Could one parsed CA chain be shared read-only?** Mbed TLS allows it in
principle: its threaded server example shares one configuration and its
certificates. It is not read-only, though:

- RSA public-key operations take the key's mutex.
- An EC multiplication by the base point stores the table it computes in the
  key's group (`grp->T` in `ecp_mul_comb`). That write is unsynchronized,
  unless the curve came with a static table.

So sharing a chain is safe only by reasoning about Mbed TLS's internals,
release by release. A copy per thread is safe by construction, and cheap.
macOS's bundle of 128 CAs parses in about 2 ms and is kept for the thread's
life. A server worker parses only its own certificate and key. So each
thread parses its own.

### Tests

`test/tls/tls_https.goose` runs offline. It uses test-only certificates
from a throwaway CA, committed in `test/tls/certs/` with the script that
made them. It covers:

- GET and POST, by name and by IP address;
- keep-alive reuse;
- a 1 MB response, and a 6 MB request echoed back, which crosses the 4 MB
  turn;
- the retry after an idle close;
- a chunked response from a raw engine loop;
- an untrusted CA, a hostname mismatch, a missing CA file, and
  `insecure_skip_verify`;
- TLS to a server that does not speak it;
- a server whose certificate or key cannot be loaded;
- three client threads against two server workers.

The runner builds it as any program using the http package, and skips it
unless the package is built in with TLS (where `third_party/mbedtls` is
there). `stdlib_http` checks that `https://` to a closed port fails with
the error that fits the build: no connection with TLS, or the one saying
TLS is not built in without it.

## A compiler bug found on the way

A `thread_spawn(...)` whose id was not used never ran. Codegen returned the
call as an expression for its caller to place, and an expression statement
drops its value. The spawn is now emitted where it is built
(`EmitThreadSpawn`). `test/threads/thread_spawn_discarded.goose` covers it.

## Not yet

- **TLS extras.** These are left out: client certificates, session
  resumption (each connection does a full handshake), ALPN (so no HTTP/2),
  OCSP and CRLs, and encrypted private keys.
- **TLS on Linux.** The epoll engine with TLS has not been run outside CI.
- **Windows.** It needs IOCP, or `WSAPoll` with Winsock start-up and
  `ws2_32`. Until then the calls fail.
- **Linux.** It is written (epoll, per-worker `SO_REUSEPORT`) but has not
  been run.
- **A head deadline.** There is no separate deadline for a slow head. The
  idle timeout bounds it, because any byte counts as activity.
- **Static files.** `sendfile` would serve them.
- **Fuzzing.** A fuzz target over `parse` is still to come.
