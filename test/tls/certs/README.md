# Test-only certificates

**These are for the TLS tests in `test/tls/` and nothing else.** The
private keys are committed, so anyone can impersonate these certificates.
Never trust `ca.pem` anywhere but a test.

| File | What it is |
|---|---|
| `ca.pem` | "Goose Test CA", the CA the tests pass as the client's `ca_file` |
| `server.pem`, `server.key` | a server certificate the test CA signed, for `localhost` and `127.0.0.1` |
| `other.pem`, `other.key` | a certificate the test CA signed for `other.example` only: a hostname mismatch when the client asks for `localhost` |
| `rogue_ca.pem` | "Goose Rogue CA", which signed nothing here: a client trusting only it rejects `server.pem` |

All are ECDSA P-256 and valid for a century from when they were made, so
the tests do not start failing on a date. The two CAs' keys were thrown away
after signing.

`make_certs.sh` makes a new set (it needs `openssl`):

    cd test/tls/certs && sh make_certs.sh
