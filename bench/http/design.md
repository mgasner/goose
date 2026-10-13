# HTTP server benchmarks

This suite measures the Goose HTTP server (`stdlib/http.goose`, on
`src/runtime/runtime_net.h`) against standard C servers. It also measures the
Goose request parser by itself against a standard C parser. The server's
design is `docs/design/http.md`.

Two suites run separately, because they answer different questions:

- **P, parsing.** This suite asks how fast the Goose parser is per request
  and per byte. It runs in one thread with no sockets, so it isolates the
  language and the parser.
- **S, serving.** This suite asks how many requests per second the whole
  server sustains, and at what latency. It runs over loopback, with the
  client and server on the same machine.

## Tools and baselines

| Role | Tool | Why this one |
|---|---|---|
| Load generator | `wrk` 4.2 (Homebrew) | The standard HTTP/1.1 load generator. It is multithreaded and keep-alive, reports latency percentiles, and pipelines through a Lua script. |
| C server | nginx 1.31 (Homebrew) | The standard C server. It runs `worker_processes N`, `return 200 "..."`, access logging off and keep-alive on. On macOS it shares one listening socket rather than using `reuseport`, which there would give every connection to one worker. |
| C core | libuv 1.53 + picohttpparser | A minimal server on the standard C event core (libuv) and the standard fast C parser (picohttpparser, from h2o). It runs one loop per thread, with the same handlers and response bytes as Goose. This is the ceiling: everything a Goose server does, written in C. |
| C parser | picohttpparser `phr_parse_request` | The parse suite's baseline. It is vendored under `bench/http/third_party/` with its MIT license. |

Each server answers two routes with byte-identical responses: the same
headers in the same order, `Server: goose`, and a `Date` header.

- `GET /plaintext` returns `Hello, World!` as `text/plain`.
- `GET /json` returns `{"message":"Hello, World!"}` as `application/json`.
  The body is serialized for every request, not cached.

The S suite also uses the routes below, as its axes need them:

- `GET /bytes/<n>` returns n bytes.
- `POST /echo` returns the size of the request body it received.

nginx takes `/bytes/<n>` from static files. It has no echo route, and that
cell is left empty.

## Suite P: parsing

The parse harness for each parser runs the same loop: load a corpus, parse
every request in it R times, check the parse, and print `ns/request` and
`MB/s`. Calibration (warm-up, doubling R until a batch takes at least 200 ms,
then 7 batches with the median reported) comes from `bench/spawn`. A sink
keeps results observable, and a checksum over the parsed method, path, header
count and body length must match between the Goose and C runs. This makes
sure both parsers did the same work.

| Corpus | Contents | What it stresses |
|---|---|---|
| P1 `tiny` | `GET / HTTP/1.1` with `Host` only, 30 B | Fixed per-request overhead |
| P2 `wrk` | What wrk sends: `Host` plus nothing much, about 40 B | The S-suite request |
| P3 `techempower` | The request TechEmpower's plaintext test sends: 6 headers, about 400 B | A typical API client |
| P4 `browser` | A Chrome navigation: 15 headers, cookies and UA, about 750 B | Header scanning throughput |
| P5 `headers-N` | N = 1, 4, 16, 32 headers of about 30 B | Per-header cost (slope) |
| P6 `value-N` | One header with an N = 16 B to 4 KB value | Byte-scan speed (slope, GB/s) |
| P7 `post-cl` | POST with `Content-Length` and a 1 KB body | Body framing |
| P8 `post-chunked` | POST with a 1 KB body in 4 chunks | Chunked decoding, in place |
| P9 `pipelined` | 16 copies of P3 back to back in one buffer | The serve loop's real path |
| P10 `partial` | P3 cut at every prefix length | Incomplete-input detection (must return "need more") |

picohttpparser does not decode chunked bodies inside `phr_parse_request`. For
P8, the C side adds `phr_decode_chunked`, so both sides do the full work. The
C side also finds the headers framing depends on, as the Goose parser does.

Each harness parses with one request record reused for the whole run, as
the server reuses one per batch of input. P8 is the exception: it must copy
the corpus each pass, and so it builds a fresh Goose `Request` each pass
too.

The parse suite reports the following:

- ns/request per corpus, for Goose and C, with their ratio;
- fitted slopes: ns per header on P5, and ns per byte on P6, converted to
  GB/s;
- a separate run of the Goose parser built with `--no-bce`. The difference
  is the cost of bounds checks that bounds-check elimination failed to
  remove.

## Suite S: serving

Each point runs as follows:

1. Start the server with W workers.
2. Wait until it accepts connections.
3. Run `wrk` for 1 s to warm up, then measure for D seconds (default 5).
4. Record requests/s, transfer/s, latency p50/p90/p99/p99.9, socket
   errors, and non-2xx responses.
5. Repeat 3 times and report the median.
6. Kill the server.

The run fails if wrk reports any non-2xx response or socket error. The
server's CPU time is read from `ps -o time` before and after, giving CPU
µs per request. That tells us whether a server is slower or just using less
CPU.

There is a core budget. The M5 has 4 performance and 6 efficiency cores, and
the client and server share them. By default the server gets W = 4 and
wrk gets 4 threads, and every result records the split. The worker sweep
holds wrk at 4 threads.

| Sweep | What varies | Held fixed |
|---|---|---|
| S1 plaintext, pipelined | pipeline depth 1, 4, 16 | 256 conns, W=4 |
| S2 json | conns 16, 64, 256, 1024 | depth 1, W=4 |
| S3 workers | W = 1, 2, 4, 6, 8 | plaintext, depth 16, 256 conns |
| S4 connections | 1, 16, 256, 4096 | plaintext, depth 1, W=4 |
| S5 response size | 13 B, 1 KB, 16 KB, 256 KB | `/bytes/<n>`, 64 conns |
| S6 request headers | 0, 8, 24 extra headers of about 40 B | plaintext, depth 16 |
| S7 request body | POST 0, 1 KB, 64 KB | `/echo`, 64 conns |
| S8 latency | 1 conn, depth 1 | p50/p99 is the result, not throughput |

S6 and S7 change only the request. They show whether the Goose parse cost
from suite P is visible end to end.

S4 at 4096 connections needs `ulimit -n` of at least 8192. The driver raises
the soft limit, or skips the point and says so.

Loopback over TCP measures syscall, parse and response cost, not the
network. That is what is wanted here: those are the costs a server
implementation controls.

## Output

`bench/http/http_bench.py` builds everything and runs it. It writes:

- `bench/http/results.md`, with tables per sweep and the fitted slopes;
- `bench/http/results.json`, with every batch and every wrk run.

Generated programs, builds and logs go to `bench/gen/http/`, which git
ignores.

Options, as in `bench/spawn`:

- `--only P|S|<id>` runs one suite or point;
- `--quick` uses 1 s runs and fewer points;
- `--duration`;
- `--servers goose,uv,nginx`;
- `--report-only`.

## Predictions

These are written before running, so the results can refute them.

1. **Parsing.** The Goose parser is a scalar byte loop with bounds checks
   mostly removed. picohttpparser on arm64 is also scalar (its SIMD paths
   are SSE4.2 and AVX2), so the two should be within 1.5x of each other.
   The expected numbers are P3 at about 60–120 ns and P6 at 1–2 GB/s.
2. **Pipelined plaintext (S1, depth 16).** This test is dominated by the
   parser and response writing. One request costs well under 1 µs, so wrk
   probably saturates first. Goose should be within 20% of libuv+pico, and
   both should beat nginx.
3. **Non-pipelined (S2, S4).** This is dominated by one `read` and one
   `write` per request, about 2–5 µs of kernel time. All three servers
   should be within 15% of each other. A larger gap would point to the
   engine, not to Goose.
4. **Workers (S3).** Throughput scales roughly linearly up to the 4
   performance cores, then flattens or drops as the server and wrk compete.
5. **Large responses (S5).** Goose writes the head and the body with one
   `writev`, without copying, so it should match libuv for large responses.

## Not measured

The following are out of scope for now:

- TLS and HTTP/2;
- networks other than loopback;
- Linux, where `SO_REUSEPORT` and `epoll` differ. The same suite runs
  there unchanged, but these results are macOS only.
