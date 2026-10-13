#!/bin/sh
# Writes the test-only certificates in this directory (README.md says what
# each is for). The keys of the two CAs are thrown away once they have
# signed, so nothing here can sign anything new. Run from this directory:
#
#     sh make_certs.sh
set -e
days=36500   # a century: the tests must not start failing on a date
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1"; }

# The CA the tests trust.
ec "$tmp/ca.key"
openssl req -x509 -new -key "$tmp/ca.key" -sha256 -days $days -subj "/CN=Goose Test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out ca.pem

# A CA the tests do not trust, which signs nothing.
ec "$tmp/rogue.key"
openssl req -x509 -new -key "$tmp/rogue.key" -sha256 -days $days -subj "/CN=Goose Rogue CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out rogue_ca.pem

# leaf NAME KEYFILE CERTFILE SAN: a server certificate the test CA signs.
leaf() {
    ec "$2"
    openssl req -new -key "$2" -subj "/CN=$1" -out "$tmp/leaf.csr"
    printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\nsubjectAltName=%s\n' "$4" > "$tmp/leaf.ext"
    openssl x509 -req -in "$tmp/leaf.csr" -CA ca.pem -CAkey "$tmp/ca.key" -CAcreateserial \
        -CAserial "$tmp/ca.srl" -sha256 -days $days -extfile "$tmp/leaf.ext" -out "$3"
}
leaf localhost server.key server.pem "DNS:localhost,IP:127.0.0.1"
leaf other.example other.key other.pem "DNS:other.example"
