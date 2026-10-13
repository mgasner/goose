# SQLite

The `sqlite` module (`stdlib/sqlite.goose`, `docs/design/sqlite.md`) and
checked SQL (`docs/design/sqlite_checked.md`) are built on the SQLite
amalgamation: `sqlite3.c` and `sqlite3.h`, placed in this directory. They
are not committed: the amalgamation is 9.5 MB of generated C, and SQLite is
not a git repository that a submodule could pin instead.

## Vendoring it

    python scripts/fetch_sqlite.py

This downloads the pinned release, SQLite 3.54.0
([sqlite-amalgamation-3540000.zip](https://sqlite.org/2026/sqlite-amalgamation-3540000.zip)),
checks it against the SHA3-256 that sqlite.org's download page publishes
(`7b670a62fdfbd672b75fef004cb703c8a3e87d3a5cc7d675b4a08337004a2d93`), and
writes the two files here. Then configure again (`cmake -B build`).

By hand, the same: download that archive, check `openssl dgst -sha3-256` (or
Python's `hashlib.sha3_256`) against the hash above, and copy `sqlite3.c`
and `sqlite3.h` from it into this directory. The archive's other files,
`shell.c` and `sqlite3ext.h`, are not needed.

## What it changes

`cmake/sqlite.cmake` builds the two files, with the options listed there,
into the `goose_sqlite` archive together with the layer in `src/sqlite/`.
The compiler links the same archive, which is also what checks SQL at
compile time, so the SQLite that accepts a statement when a program is
compiled is the one that runs it.

Without the files, or with `-DGOOSE_SQLITE=OFF`, the compiler builds as
before. Programs using `sqlite` still typecheck and generate C, but cannot
run in-process; checked SQL is rejected; and the test runner skips what
needs the module.

License: public domain (see the header of `sqlite3.c`).

## Updating

Take the newer archive's name and SHA3-256 from
https://sqlite.org/download.html, put them in `scripts/fetch_sqlite.py`
(and here), and run it with `--force`.
