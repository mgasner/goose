# Mbed TLS

TLS for the `http` package (`packages/http`; `https://` in the client, `serve_tls` in the
server; [`docs/design/http.md`](../../docs/design/http.md)) is built on
[Mbed TLS](https://github.com/Mbed-TLS/mbedtls): its `library/` and
`include/` trees and its `LICENSE`, placed in this directory. They are not
committed: the library is 8 MB of third-party C, and the release tarball,
unlike the git repository, has the generated files a build needs.

## Vendoring it

    python scripts/fetch_mbedtls.py

This downloads the pinned release, Mbed TLS 3.6.7, the current release of
the 3.6 long-term-support branch
([mbedtls-3.6.7.tar.bz2](https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2)),
checks it against the SHA-256 the release publishes in
`mbedtls-3.6.7-sha256sum.txt`
(`a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6`), and
writes `library/`, `include/` and `LICENSE` here. Then build the http
package again: reconfigure (`cmake -B build`) for a compiler with it built
in, or let `goose build` rebuild it in GOOSE_HOME.

By hand, the same: download that tarball, check `shasum -a 256` against the
hash above, and copy `library/`, `include/` and `LICENSE` out of its
top-level directory into this one.

## What it changes

The http package's `CMakeLists.txt` looks for it in the package's own
`third_party/mbedtls`, then here (or where `GOOSE_MBEDTLS_DIR` says), and
builds all of `library/*.c`, with the changes to the default configuration
in `packages/http/src/mbedtls_user_config.h` (threading on; DTLS,
renegotiation and debugging off), into the `goose_http_mbedtls` archive,
which the package's `goose_http` links along with its TLS layer
(`src/tls_layer.c`). A program using the package gets it as it gets the
rest of the package: built into the compiler, built by `goose build` or
`goose run`, or named by `goose --http-link cc` for C built with `-o`.

Without the files, with the package's `-DGOOSE_HTTP_TLS=OFF`, or on Windows
(where the http package's sockets do not run yet), the package builds
without TLS. Programs using `http` still build and run; `https://` and `serve_tls` fail with an
error saying TLS is not built in, and the test runner skips `test/tls/`.

License: Apache-2.0 or GPL-2.0-or-later, at your option (`LICENSE`); Goose
uses it under Apache-2.0.

## Updating

Stay on the 3.6 LTS branch until the layer is ported to 4.x, whose API
differs. Take the newer tarball's name and SHA-256 from its release page
(the `-sha256sum.txt` asset) at https://github.com/Mbed-TLS/mbedtls/releases,
put them in `scripts/fetch_mbedtls.py` (and here), and run it with
`--force`.
