# SQLite

`sqlite3.c` and `sqlite3.h` from the SQLite 3.54.0 amalgamation, copied
unmodified from
[sqlite-amalgamation-3540000.zip](https://sqlite.org/2026/sqlite-amalgamation-3540000.zip)
(SHA3-256 `7b670a62fdfbd672b75fef004cb703c8a3e87d3a5cc7d675b4a08337004a2d93`,
as published on sqlite.org's download page).

The `sqlite` module (`stdlib/sqlite.goose`, `docs/design/sqlite.md`) is built
on it: `cmake/sqlite.cmake` compiles it, with the options listed there, into
the `goose_sqlite` archive together with the layer in `src/sqlite/`. The
compiler links the same archive, which is also what checks SQL at compile
time (`docs/design/sqlite_checked.md`), so the SQLite that accepts a statement
when a program is compiled is the one that runs it.

The amalgamation is not a git repository, so it is copied rather than added
as a submodule. `shell.c` and `sqlite3ext.h` from the same archive are not
needed and are left out.

License: public domain (see the header of `sqlite3.c`).

To update, download a newer amalgamation from https://sqlite.org/download.html,
check its SHA3-256 against the page, copy the two files, and record the
version and hash here.
