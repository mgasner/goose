# SQLite

The `sqlite` package (`packages/sqlite`, `docs/design/sqlite.md`) and
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
writes the two files here. Then configure again (`cmake -B build
-DGOOSE_BUILTIN_LIBS=all`, or naming `sqlite` among the packages).

By hand, the same: download that archive, check `openssl dgst -sha3-256` (or
Python's `hashlib.sha3_256`) against the hash above, and copy `sqlite3.c`
and `sqlite3.h` from it into this directory. The archive's other files,
`shell.c` and `sqlite3ext.h`, are not needed.

## What it changes

`packages/sqlite/CMakeLists.txt` builds the two files, with the options
listed there, into the `goose_sqlite3` archive, and the layer in
`packages/sqlite/src/` into `goose_sqlite` over it. The compiler links
`goose_sqlite3` to check SQL at compile time -- the one the package compiled
into it links, when it is -- so the SQLite that accepts a statement when a
program is compiled is the one that runs it.

Without the files the compiler builds as before, and so does it with
`-DGOOSE_SQL_CHECK=OFF`: checked SQL is rejected, the sqlite package is not
compiled in (a program importing it has it built into GOOSE_HOME, which
needs the files beside the package or in this tree), and the test runner
skips what needs it.

License: public domain (see the header of `sqlite3.c`).

## Updating

Take the newer archive's name and SHA3-256 from
https://sqlite.org/download.html, put them in `scripts/fetch_sqlite.py`
(and here), and run it with `--force`.
