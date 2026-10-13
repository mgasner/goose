"""Vendors SQLite for the sqlite module: downloads the pinned amalgamation
from sqlite.org, checks it against the SHA3-256 recorded here, and writes
sqlite3.c and sqlite3.h into third_party/sqlite/, where cmake/sqlite.cmake
looks for them. They are not committed (third_party/sqlite/README.md says
why). Without them the compiler builds as before, minus the sqlite module and
checked SQL.

    python scripts/fetch_sqlite.py            # fetch, unless already there
    python scripts/fetch_sqlite.py --force    # fetch again

To move to a newer SQLite, take the archive's name and SHA3-256 from
https://sqlite.org/download.html and update VERSION, URL and SHA3 below.
"""

import hashlib
import io
import sys
import urllib.request
import zipfile
from pathlib import Path

VERSION = "3.54.0"
URL = "https://sqlite.org/2026/sqlite-amalgamation-3540000.zip"
SHA3 = "7b670a62fdfbd672b75fef004cb703c8a3e87d3a5cc7d675b4a08337004a2d93"
FILES = ("sqlite3.c", "sqlite3.h")
DEST = Path(__file__).resolve().parent.parent / "third_party" / "sqlite"


def main():
    if all((DEST / f).exists() for f in FILES) and "--force" not in sys.argv:
        print(f"third_party/sqlite already has {', '.join(FILES)}; --force fetches again")
        return
    print(f"fetching SQLite {VERSION} from {URL}")
    with urllib.request.urlopen(URL, timeout=120) as r:
        data = r.read()
    got = hashlib.sha3_256(data).hexdigest()
    if got != SHA3:
        sys.exit(f"SHA3-256 mismatch: expected {SHA3}, got {got}; nothing written")
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for f in FILES:
            # The archive keeps them in a directory named for the version.
            member = next(n for n in z.namelist() if n.endswith("/" + f))
            (DEST / f).write_bytes(z.read(member))
    print(f"wrote {', '.join(FILES)} to {DEST}")


if __name__ == "__main__":
    main()
