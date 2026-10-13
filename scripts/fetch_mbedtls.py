"""Vendors Mbed TLS for HTTPS in the http package: downloads the pinned
release from the Mbed-TLS GitHub project, checks it against the SHA-256
recorded here, and writes its library/ and include/ trees (and its LICENSE)
into third_party/mbedtls/, where packages/http/CMakeLists.txt looks for
them. They are not committed (third_party/mbedtls/README.md says why).
Without them the package builds without TLS, and an https:// URL fails with
an error saying TLS was not built in.

    python scripts/fetch_mbedtls.py            # fetch, unless already there
    python scripts/fetch_mbedtls.py --force    # fetch again

To move to a newer Mbed TLS 3.6 (the LTS branch), take the tarball's name
and SHA-256 from its release on
https://github.com/Mbed-TLS/mbedtls/releases (the -sha256sum.txt asset) and
update VERSION, URL and SHA256 below.
"""

import hashlib
import io
import shutil
import sys
import tarfile
import urllib.request
from pathlib import Path

VERSION = "3.6.7"
URL = ("https://github.com/Mbed-TLS/mbedtls/releases/download/"
       f"mbedtls-{VERSION}/mbedtls-{VERSION}.tar.bz2")
SHA256 = "a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6"
# What the build uses: the library's sources, its public headers, and the
# license that has to travel with them.
KEEP = ("library/", "include/", "LICENSE")
DEST = Path(__file__).resolve().parent.parent / "third_party" / "mbedtls"
MARK = DEST / "library" / "ssl_tls.c"


def main():
    if MARK.exists() and "--force" not in sys.argv:
        print("third_party/mbedtls already has the library; --force fetches again")
        return
    print(f"fetching Mbed TLS {VERSION} from {URL}")
    with urllib.request.urlopen(URL, timeout=120) as r:
        data = r.read()
    got = hashlib.sha256(data).hexdigest()
    if got != SHA256:
        sys.exit(f"SHA-256 mismatch: expected {SHA256}, got {got}; nothing written")
    for sub in ("library", "include"):
        shutil.rmtree(DEST / sub, ignore_errors=True)
    n = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:bz2") as t:
        for m in t.getmembers():
            # The archive keeps everything in a directory named for the
            # version; only regular files under KEEP are written.
            parts = m.name.split("/", 1)
            if len(parts) != 2 or not m.isfile():
                continue
            rel = parts[1]
            if not any(rel == k or (k.endswith("/") and rel.startswith(k)) for k in KEEP):
                continue
            out = (DEST / rel).resolve()
            if DEST.resolve() not in out.parents:
                sys.exit(f"refusing {m.name}: outside {DEST}")
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(t.extractfile(m).read())
            n += 1
    (DEST / "VERSION").write_text(VERSION + "\n")
    print(f"wrote {n} files of Mbed TLS {VERSION} to {DEST}")


if __name__ == "__main__":
    main()
