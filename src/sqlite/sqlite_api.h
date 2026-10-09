/* The sqlite layer's C API: every function stdlib/sqlite.goose reaches
   through an `extern "gs_sql_..." fn`, listed once in GS_SQL_API. That list
   expands into the prototypes below and into the symbol table a JIT run
   registers (src/jit.h), and the test suite checks stdlib/sqlite.goose
   against it (test/api_check.py). docs/design/sqlite.md is the design.

   The layer sits over SQLite (third_party/sqlite) and changes what cannot
   cross an `extern fn` (spec 7.10):

   * Connections and statements are handles, `generation << 32 | slot` in a
     u64, into slot tables the layer owns. Every call checks its handles, so
     a closed connection or a finalized statement is a misuse, not a crash.
     A connection belongs to the thread that opened it, and so do its
     statements; another thread using one is a misuse.
   * Statements come from a cache per connection, keyed by their SQL, and are
     never finalized by the program: gs_sql_prepare hands out a cached one
     reset and unbound, or prepares it. Closing the connection finalizes
     them all.
   * Text and blobs read out of a row are appended to a Goose builder
     (`u8[>..]&`, gs_sql_builder), as the runtime's own os functions append,
     so nothing the program holds points into SQLite's memory. Text and
     blobs bound as parameters are copied by SQLite (SQLITE_TRANSIENT).
   * Nothing calls back into Goose: rows are pulled with gs_sql_step.

   Transactions carry tokens. gs_sql_begin hands out a token for each level
   (the outer transaction, then one savepoint per nested level), and every
   call on a connection passes the token of the handle it was made through,
   zero outside any transaction. A call carrying the token of an outer level,
   or zero, while inner levels are open means the blocks that began them were
   left early, so those levels are rolled back first. A token no level holds
   any more is a misuse.

   Errors: what can go wrong for reasons outside the program (a constraint,
   a busy database, a full disk, SQL built at run time that does not parse)
   returns a failure, with the code and SQLite's message kept per connection
   until the next failure (gs_sql_code, gs_sql_error). A call the program
   should not have made is refused and counted per thread
   (gs_sql_misuse_count, gs_sql_misuse_text), and the Goose side aborts with
   it straight away. */

#ifndef GS_SQL_API_H
#define GS_SQL_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma pack(push, 1)

typedef struct { uint8_t *data; int64_t len; } gs_sql_bytes;   /* u8[:], the generated sl_u8 */

/* A reference to a Goose `u8[>..]`, the generated gs_rref: the array's
   header and the data stack its elements top, which an append extends. */
struct gs_sql_rhdr { uint8_t *base; int64_t len; };
struct gs_sql_stack { uint8_t *top; };
typedef struct { struct gs_sql_rhdr *hdr; struct gs_sql_stack *stk; } gs_sql_builder;

#pragma pack(pop)

#define GS_SQL_API(X) \
    /* The library. */ \
    X(uint8_t, gs_sql_available, (void)) \
    X(int64_t, gs_sql_version_number, (void)) \
    X(void, gs_sql_version, (gs_sql_builder out)) \
    X(int64_t, gs_sql_misuse_count, (void)) \
    X(void, gs_sql_misuse_text, (gs_sql_builder out)) \
    X(int64_t, gs_sql_memory_used, (void)) \
    X(int64_t, gs_sql_set_soft_heap_limit, (int64_t bytes)) \
    /* Connections. */ \
    X(uint64_t, gs_sql_open, (gs_sql_bytes path, uint8_t read_only, uint8_t create, uint8_t wal, int32_t busy_timeout_ms, uint8_t foreign_keys, int32_t statement_cache)) \
    X(uint8_t, gs_sql_is_open, (uint64_t db)) \
    X(void, gs_sql_close, (uint64_t db)) \
    X(int32_t, gs_sql_code, (uint64_t db)) \
    X(int32_t, gs_sql_extended_code, (uint64_t db)) \
    X(void, gs_sql_error, (uint64_t db, gs_sql_builder out)) \
    X(int32_t, gs_sql_error_offset, (uint64_t db)) \
    X(int64_t, gs_sql_changes, (uint64_t db, int64_t token)) \
    X(int64_t, gs_sql_total_changes, (uint64_t db, int64_t token)) \
    X(int64_t, gs_sql_last_rowid, (uint64_t db, int64_t token)) \
    X(uint8_t, gs_sql_in_transaction, (uint64_t db, int64_t token)) \
    X(void, gs_sql_interrupt, (uint64_t db)) \
    X(uint8_t, gs_sql_exec_script, (uint64_t db, int64_t token, gs_sql_bytes sql)) \
    X(void, gs_sql_settle, (uint64_t db, int64_t token)) \
    X(uint8_t, gs_sql_backup, (uint64_t db, int64_t token, gs_sql_bytes path)) \
    X(uint8_t, gs_sql_serialize, (uint64_t db, int64_t token, gs_sql_builder out)) \
    X(uint8_t, gs_sql_deserialize, (uint64_t db, int64_t token, gs_sql_bytes image)) \
    X(void, gs_sql_forget, (uint64_t db, gs_sql_bytes sql)) \
    X(void, gs_sql_fail, (uint64_t db, int32_t code, gs_sql_bytes msg)) \
    X(int64_t, gs_sql_cached_count, (uint64_t db)) \
    /* Transactions. */ \
    X(int64_t, gs_sql_begin, (uint64_t db, int64_t token, uint8_t immediate)) \
    X(uint8_t, gs_sql_end, (uint64_t db, int64_t token, uint8_t commit)) \
    /* Statements. */ \
    X(uint64_t, gs_sql_prepare, (uint64_t db, int64_t token, gs_sql_bytes sql)) \
    X(int32_t, gs_sql_param_count, (uint64_t st)) \
    X(int32_t, gs_sql_param_index, (uint64_t st, gs_sql_bytes name)) \
    X(void, gs_sql_param_name, (uint64_t st, int32_t i, gs_sql_builder out)) \
    X(uint8_t, gs_sql_bind_i64, (uint64_t st, int32_t i, int64_t v)) \
    X(uint8_t, gs_sql_bind_f64, (uint64_t st, int32_t i, double v)) \
    X(uint8_t, gs_sql_bind_text, (uint64_t st, int32_t i, gs_sql_bytes v)) \
    X(uint8_t, gs_sql_bind_blob, (uint64_t st, int32_t i, gs_sql_bytes v)) \
    X(uint8_t, gs_sql_bind_null, (uint64_t st, int32_t i)) \
    X(int32_t, gs_sql_step, (uint64_t st)) \
    X(void, gs_sql_reset, (uint64_t st)) \
    X(uint8_t, gs_sql_readonly, (uint64_t st)) \
    X(void, gs_sql_sql, (uint64_t st, gs_sql_builder out)) \
    X(int32_t, gs_sql_column_count, (uint64_t st)) \
    X(int32_t, gs_sql_column_type, (uint64_t st, int32_t i)) \
    X(int64_t, gs_sql_column_i64, (uint64_t st, int32_t i)) \
    X(double, gs_sql_column_f64, (uint64_t st, int32_t i)) \
    X(int64_t, gs_sql_column_bytes, (uint64_t st, int32_t i)) \
    X(void, gs_sql_column_text, (uint64_t st, int32_t i, gs_sql_builder out)) \
    X(void, gs_sql_column_blob, (uint64_t st, int32_t i, gs_sql_builder out)) \
    X(void, gs_sql_column_name, (uint64_t st, int32_t i, gs_sql_builder out)) \
    X(void, gs_sql_column_decltype, (uint64_t st, int32_t i, gs_sql_builder out)) \
    /* Rows decoded by checked statements (docs/design/sqlite_checked.md). */ \
    X(void, gs_sql_fail_row, (uint64_t st, int32_t i, gs_sql_bytes msg)) \
    X(uint8_t, gs_sql_row_failed, (uint64_t st))

#define GS_SQL_PROTO(ret, name, params) ret name params;
GS_SQL_API(GS_SQL_PROTO)
#undef GS_SQL_PROTO

/* The constants stdlib/sqlite.goose declares, with their Goose types; here
   they are GS_SQL_<name>. Each is SQLite's own value. */
#define GS_SQL_CONSTANTS(X) \
    /* Result codes (primary), SQLITE_*. */ \
    X(i32, OK, 0) \
    X(i32, ERROR, 1) \
    X(i32, INTERNAL, 2) \
    X(i32, PERM, 3) \
    X(i32, ABORT, 4) \
    X(i32, BUSY, 5) \
    X(i32, LOCKED, 6) \
    X(i32, NOMEM, 7) \
    X(i32, READONLY, 8) \
    X(i32, INTERRUPT, 9) \
    X(i32, IOERR, 10) \
    X(i32, CORRUPT, 11) \
    X(i32, FULL, 13) \
    X(i32, CANTOPEN, 14) \
    X(i32, PROTOCOL, 15) \
    X(i32, SCHEMA, 17) \
    X(i32, TOOBIG, 18) \
    X(i32, CONSTRAINT, 19) \
    X(i32, MISMATCH, 20) \
    X(i32, MISUSE, 21) \
    X(i32, AUTH, 23) \
    X(i32, RANGE, 25) \
    X(i32, NOTADB, 26) \
    X(i32, ROW, 100) \
    X(i32, DONE, 101) \
    /* Column types, SQLITE_INTEGER and on. */ \
    X(i32, INTEGER, 1) \
    X(i32, FLOAT, 2) \
    X(i32, TEXT, 3) \
    X(i32, BLOB, 4) \
    X(i32, NULL, 5)

#define GS_SQL_ENUM(type, name, value) GS_SQL_##name = value,
enum { GS_SQL_CONSTANTS(GS_SQL_ENUM) };
#undef GS_SQL_ENUM

#ifdef __cplusplus
}
#endif

#endif
