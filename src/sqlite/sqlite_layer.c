/* The sqlite layer (sqlite_api.h): handles, the statement cache, transaction
   tokens and thread ownership over SQLite. docs/design/sqlite.md has the
   design; this file is the whole layer. */

#include "sqlite_api.h"
#include "sqlite3.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef DWORD sql_thread;
static sql_thread sql_self(void) { return GetCurrentThreadId(); }
static int sql_same_thread(sql_thread a, sql_thread b) { return a == b; }
#else
#include <pthread.h>
typedef pthread_t sql_thread;
static sql_thread sql_self(void) { return pthread_self(); }
static int sql_same_thread(sql_thread a, sql_thread b) { return pthread_equal(a, b); }
#endif

#if defined(_MSC_VER)
#define SQL_TLS __declspec(thread)
#else
#define SQL_TLS _Thread_local
#endif

/* --- misuse, per thread ----------------------------------------------------- */

static SQL_TLS int64_t sql_misuses;
static SQL_TLS char sql_misuse_msg[512];

/* Refuses a call the program should not have made. The Goose side checks
   the count after each call and aborts with the text. Returns 0, so a check
   can `return sql_misuse(...)`. */
static int sql_misuse(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(sql_misuse_msg, sizeof sql_misuse_msg, fmt, args);
    va_end(args);
    sql_misuses++;
    return 0;
}

/* --- builders ---------------------------------------------------------------- */

/* Appends to a Goose u8[>..]: its elements top its data stack, so the bytes
   go at the stack top and the header's count grows (the runtime's
   gs_bld_append). */
static void sql_append(gs_sql_builder b, const void *p, int64_t n) {
    if (n <= 0 || !p) return;
    memcpy(b.stk->top, p, (size_t)n);
    b.stk->top += n;
    b.hdr->len += n;
}

static void sql_append_str(gs_sql_builder b, const char *s) {
    if (s) sql_append(b, s, (int64_t)strlen(s));
}

/* A NUL-terminated copy of a Goose slice, which SQLite's path and name
   arguments need. The caller frees it. */
static char *sql_cstr(gs_sql_bytes s) {
    int64_t n = s.len > 0 ? s.len : 0;
    char *out = (char *)malloc((size_t)n + 1);
    if (!out) return NULL;
    if (n) memcpy(out, s.data, (size_t)n);
    out[n] = 0;
    return out;
}

/* --- slot tables ----------------------------------------------------------------
   Slots are allocated one at a time and never freed, so a pointer to one
   stays valid while the table that lists them grows; a slot is reused with
   its generation bumped. The mutex guards the tables, not the slots: a slot
   belongs to the thread that owns its connection. */

#define SQL_MAX_DEPTH 32

typedef struct {
    sqlite3 *db;          /* null once closed, or when opening failed */
    uint32_t gen;
    int live;             /* the handle is valid: open, or a failed open kept for its error */
    sql_thread owner;
    int32_t err_code, err_ext, err_offset;
    char *err_msg;        /* the last failure's message, malloc'd */
    int32_t cache_cap;
    int64_t clock;        /* stamps statements for LRU */
    int64_t tokens[SQL_MAX_DEPTH];   /* the open transaction levels, outermost first */
    int depth;
    int64_t next_token;
} sql_conn;

typedef struct {
    sqlite3_stmt *st;     /* null when the slot is free */
    uint32_t gen;
    uint32_t conn;        /* the connection's slot */
    sql_conn *owner;      /* and the slot itself, which never moves */
    char *sql;
    int64_t sqllen;
    int64_t used;         /* the connection's clock when last handed out or stepped */
    int on_row;           /* the last step returned SQLITE_ROW */
    int row_failed;       /* a value of this row did not fit what it was read into */
} sql_stmt;

static sqlite3_mutex *sql_lock;
static sql_conn **sql_conns;
static uint32_t sql_nconns;
static sql_stmt **sql_stmts;
static uint32_t sql_nstmts;

static void sql_init(void) {
    /* sqlite3_initialize is thread-safe and idempotent; the static mutex it
       hands out is SQLite's own. */
    if (!sql_lock) {
        sqlite3_initialize();
        sql_lock = sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_APP1);
    }
}

static uint64_t sql_handle(uint32_t gen, uint32_t slot) {
    return ((uint64_t)gen << 32) | (uint64_t)slot;
}

/* The connection behind a live handle on its own thread, or a misuse naming
   the function. */
static sql_conn *sql_conn_of(uint64_t h, const char *fn) {
    sql_init();
    uint32_t slot = (uint32_t)h, gen = (uint32_t)(h >> 32);
    sql_conn *c = NULL;
    sqlite3_mutex_enter(sql_lock);
    if (h && slot < sql_nconns) c = sql_conns[slot];
    sqlite3_mutex_leave(sql_lock);
    if (!c || !c->live || c->gen != gen) {
        sql_misuse("sqlite::%s: %s", fn,
                   h ? "a connection that was closed, or never opened" : "a null connection");
        return NULL;
    }
    if (!sql_same_thread(c->owner, sql_self())) {
        sql_misuse("sqlite::%s: a connection used from a thread other than the one that opened it",
                   fn);
        return NULL;
    }
    return c;
}

/* The same for a connection that must be open, not a failed open. */
static sql_conn *sql_open_conn_of(uint64_t h, const char *fn) {
    sql_conn *c = sql_conn_of(h, fn);
    if (c && !c->db) {
        sql_misuse("sqlite::%s: a connection whose open failed", fn);
        return NULL;
    }
    return c;
}

static sql_stmt *sql_stmt_of(uint64_t h, const char *fn) {
    sql_init();
    uint32_t slot = (uint32_t)h, gen = (uint32_t)(h >> 32);
    sql_stmt *s = NULL;
    sqlite3_mutex_enter(sql_lock);
    if (h && slot < sql_nstmts) s = sql_stmts[slot];
    sqlite3_mutex_leave(sql_lock);
    if (!s || !s->st || s->gen != gen) {
        sql_misuse("sqlite::%s: %s", fn,
                   h ? "a statement whose connection was closed, or that left the statement "
                       "cache (sqlite::forget, or the cache filling up while it was mid-step)"
                     : "a null statement");
        return NULL;
    }
    if (!sql_same_thread(s->owner->owner, sql_self())) {
        sql_misuse("sqlite::%s: a statement used from a thread other than the one that opened "
                   "its connection", fn);
        return NULL;
    }
    return s;
}

/* A free slot of a table, growing it; under the lock. */
static void *sql_new_slot(void ***table, uint32_t *n, size_t size, int (*is_free)(void *),
                          uint32_t *slot) {
    /* Slot 0 is never used, so a zero handle is never valid. */
    for (uint32_t i = 1; i < *n; i++)
        if (is_free((*table)[i])) { *slot = i; return (*table)[i]; }
    uint32_t i = *n ? *n : 1;
    void **grown = (void **)realloc(*table, sizeof(void *) * (i + 1));
    if (!grown) return NULL;
    *table = grown;
    if (*n == 0) grown[0] = NULL;
    void *fresh = calloc(1, size);
    if (!fresh) return NULL;
    grown[i] = fresh;
    *n = i + 1;
    *slot = i;
    return fresh;
}

static int sql_conn_free(void *p) { return !((sql_conn *)p)->live; }
static int sql_stmt_free(void *p) { return !((sql_stmt *)p)->st; }

/* --- errors, per connection ------------------------------------------------------ */

static void sql_set_error(sql_conn *c, int code, const char *msg, int offset) {
    free(c->err_msg);
    c->err_msg = msg ? strdup(msg) : NULL;
    c->err_code = code & 0xff;
    c->err_ext = code;
    c->err_offset = offset;
}

/* Keeps SQLite's account of the failure that just happened. */
static void sql_failed(sql_conn *c) {
    sql_set_error(c, sqlite3_extended_errcode(c->db), sqlite3_errmsg(c->db),
                  sqlite3_error_offset(c->db));
}

/* --- the statement cache --------------------------------------------------------- */

static void sql_finalize(sql_stmt *s) {
    sqlite3_finalize(s->st);
    free(s->sql);
    s->st = NULL;
    s->sql = NULL;
    s->gen++;
}

/* Finalizes every statement of a connection. */
static void sql_drop_cache(uint32_t conn) {
    sqlite3_mutex_enter(sql_lock);
    for (uint32_t i = 1; i < sql_nstmts; i++)
        if (sql_stmts[i]->st && sql_stmts[i]->conn == conn) sql_finalize(sql_stmts[i]);
    sqlite3_mutex_leave(sql_lock);
}

/* Over capacity: drop the least recently used statement, one that is not
   mid-step if there is one. A statement left mid-step is one an each() block
   left early, or one an outer each() is still stepping and has not stepped
   for a whole cache's worth of other statements; that one's next step is a
   misuse rather than a wrong row. `keep`, just prepared, stays. Under the
   lock. */
static void sql_evict(uint32_t conn, int32_t cap, sql_stmt *keep) {
    for (;;) {
        int32_t count = 0;
        sql_stmt *idle = NULL, *busy = NULL;
        for (uint32_t i = 1; i < sql_nstmts; i++) {
            sql_stmt *s = sql_stmts[i];
            if (!s->st || s->conn != conn) continue;
            count++;
            if (s == keep) continue;
            sql_stmt **pick = sqlite3_stmt_busy(s->st) ? &busy : &idle;
            if (!*pick || s->used < (*pick)->used) *pick = s;
        }
        if (count <= cap || (!idle && !busy)) return;
        sql_finalize(idle ? idle : busy);
    }
}

/* --- transactions ------------------------------------------------------------------ */

static int sql_exec(sql_conn *c, const char *sql) {
    return sqlite3_exec(c->db, sql, NULL, NULL, NULL);
}

/* Rolls back the levels above `keep` (0: all of them). */
static void sql_unwind(sql_conn *c, int keep) {
    while (c->depth > keep) {
        c->depth--;
        if (c->depth == 0) {
            sql_exec(c, "ROLLBACK");
        } else {
            char buf[64];
            snprintf(buf, sizeof buf, "ROLLBACK TO gs_sp%d; RELEASE gs_sp%d", c->depth, c->depth);
            sql_exec(c, buf);
        }
    }
}

/* Every call on a connection starts here with the token of the handle it was
   made through. A token of an outer level, or zero, while inner levels are
   open: the blocks that opened them were left early, so they are rolled
   back. A token no open level holds: a misuse. */
static int sql_enter(sql_conn *c, int64_t token, const char *fn) {
    if (token == 0) {
        sql_unwind(c, 0);
        return 1;
    }
    for (int i = 0; i < c->depth; i++)
        if (c->tokens[i] == token) {
            sql_unwind(c, i + 1);
            return 1;
        }
    return sql_misuse("sqlite::%s: the connection handle of a transaction() block that has "
                      "ended. If this is inside the block, the transaction was rolled back "
                      "because the outer handle was used inside it: use the block's own",
                      fn);
}

static sql_conn *sql_use(uint64_t db, int64_t token, const char *fn) {
    sql_conn *c = sql_open_conn_of(db, fn);
    if (!c || !sql_enter(c, token, fn)) return NULL;
    return c;
}

/* --- the library ------------------------------------------------------------------- */

uint8_t gs_sql_available(void) { return 1; }

int64_t gs_sql_version_number(void) { return sqlite3_libversion_number(); }

void gs_sql_version(gs_sql_builder out) { sql_append_str(out, sqlite3_libversion()); }

int64_t gs_sql_misuse_count(void) { return sql_misuses; }

void gs_sql_misuse_text(gs_sql_builder out) { sql_append_str(out, sql_misuse_msg); }

int64_t gs_sql_memory_used(void) { return sqlite3_memory_used(); }

int64_t gs_sql_set_soft_heap_limit(int64_t bytes) { return sqlite3_soft_heap_limit64(bytes); }

/* --- connections -------------------------------------------------------------------- */

uint64_t gs_sql_open(gs_sql_bytes path, uint8_t read_only, uint8_t create, uint8_t wal,
                     int32_t busy_timeout_ms, uint8_t foreign_keys, int32_t statement_cache) {
    sql_init();
    uint32_t slot;
    sqlite3_mutex_enter(sql_lock);
    sql_conn *c = (sql_conn *)sql_new_slot((void ***)&sql_conns, &sql_nconns, sizeof(sql_conn),
                                           sql_conn_free, &slot);
    if (c) {
        c->live = 1;
        c->gen++;
    }
    sqlite3_mutex_leave(sql_lock);
    if (!c) {
        sql_misuse("sqlite::open: out of memory for a connection");
        return 0;
    }
    c->owner = sql_self();
    c->db = NULL;
    c->depth = 0;
    c->next_token = 1;
    c->clock = 0;
    c->cache_cap = statement_cache > 0 ? statement_cache : 1;
    sql_set_error(c, SQLITE_OK, NULL, -1);
    char *p = sql_cstr(path);
    int flags = SQLITE_OPEN_URI | (read_only ? SQLITE_OPEN_READONLY
                                             : SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0));
    sqlite3 *db = NULL;
    int rc = p ? sqlite3_open_v2(p, &db, flags, NULL) : SQLITE_NOMEM;
    free(p);
    if (rc != SQLITE_OK) {
        /* The handle stays live for its error and for close. */
        sql_set_error(c, rc, db ? sqlite3_errmsg(db) : sqlite3_errstr(rc), -1);
        sqlite3_close_v2(db);
        return sql_handle(c->gen, slot);
    }
    c->db = db;
    sqlite3_busy_timeout(db, busy_timeout_ms);
    sqlite3_extended_result_codes(db, 0);
    sql_exec(c, foreign_keys ? "PRAGMA foreign_keys = ON" : "PRAGMA foreign_keys = OFF");
    /* WAL needs a file, and a connection that may write it. */
    const char *file = sqlite3_db_filename(db, "main");
    if (wal && !read_only && file && *file && sql_exec(c, "PRAGMA journal_mode = WAL") != SQLITE_OK) {
        sql_failed(c);
        sqlite3_close_v2(db);
        c->db = NULL;
    }
    return sql_handle(c->gen, slot);
}

uint8_t gs_sql_is_open(uint64_t db) {
    sql_conn *c = sql_conn_of(db, "open");
    return c && c->db;
}

void gs_sql_close(uint64_t db) {
    sql_conn *c = sql_conn_of(db, "close");
    if (!c) return;
    uint32_t slot = (uint32_t)db;
    if (c->db) {
        sql_drop_cache(slot);
        c->depth = 0;
        sqlite3_close_v2(c->db);   /* rolls back an open transaction */
        c->db = NULL;
    }
    sql_set_error(c, SQLITE_OK, NULL, -1);
    sqlite3_mutex_enter(sql_lock);
    c->live = 0;
    c->gen++;
    sqlite3_mutex_leave(sql_lock);
}

int32_t gs_sql_code(uint64_t db) {
    sql_conn *c = sql_conn_of(db, "code");
    return c ? c->err_code : SQLITE_MISUSE;
}

int32_t gs_sql_extended_code(uint64_t db) {
    sql_conn *c = sql_conn_of(db, "extended_code");
    return c ? c->err_ext : SQLITE_MISUSE;
}

void gs_sql_error(uint64_t db, gs_sql_builder out) {
    sql_conn *c = sql_conn_of(db, "error");
    if (c) sql_append_str(out, c->err_msg ? c->err_msg : "not an error");
}

int32_t gs_sql_error_offset(uint64_t db) {
    sql_conn *c = sql_conn_of(db, "error_offset");
    return c ? c->err_offset : -1;
}

int64_t gs_sql_changes(uint64_t db, int64_t token) {
    sql_conn *c = sql_use(db, token, "changes");
    return c ? sqlite3_changes64(c->db) : 0;
}

int64_t gs_sql_total_changes(uint64_t db, int64_t token) {
    sql_conn *c = sql_use(db, token, "total_changes");
    return c ? sqlite3_total_changes64(c->db) : 0;
}

int64_t gs_sql_last_rowid(uint64_t db, int64_t token) {
    sql_conn *c = sql_use(db, token, "last_rowid");
    return c ? sqlite3_last_insert_rowid(c->db) : 0;
}

uint8_t gs_sql_in_transaction(uint64_t db, int64_t token) {
    sql_conn *c = sql_use(db, token, "in_transaction");
    return c ? !sqlite3_get_autocommit(c->db) : 0;
}

void gs_sql_interrupt(uint64_t db) {
    sql_conn *c = sql_open_conn_of(db, "interrupt");
    if (c) sqlite3_interrupt(c->db);
}

uint8_t gs_sql_exec_script(uint64_t db, int64_t token, gs_sql_bytes sql) {
    sql_conn *c = sql_use(db, token, "exec_script");
    if (!c) return 0;
    char *text = sql_cstr(sql);
    if (!text) return 0;
    int rc = sqlite3_exec(c->db, text, NULL, NULL, NULL);
    free(text);
    if (rc != SQLITE_OK) sql_failed(c);
    return rc == SQLITE_OK;
}

/* Resets every statement left mid-step: for a program that knows no each()
   is running, after one was left early. */
void gs_sql_settle(uint64_t db, int64_t token) {
    sql_conn *c = sql_use(db, token, "settle");
    if (!c) return;
    uint32_t conn = (uint32_t)db;
    sqlite3_mutex_enter(sql_lock);
    for (uint32_t i = 1; i < sql_nstmts; i++) {
        sql_stmt *s = sql_stmts[i];
        if (s->st && s->conn == conn && sqlite3_stmt_busy(s->st)) {
            sqlite3_reset(s->st);
            s->on_row = 0;
        }
    }
    sqlite3_mutex_leave(sql_lock);
}

uint8_t gs_sql_backup(uint64_t db, int64_t token, gs_sql_bytes path) {
    sql_conn *c = sql_use(db, token, "backup");
    if (!c) return 0;
    char *p = sql_cstr(path);
    sqlite3 *dst = NULL;
    int rc = p ? sqlite3_open_v2(p, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
                                 NULL)
               : SQLITE_NOMEM;
    free(p);
    if (rc == SQLITE_OK) {
        sqlite3_backup *b = sqlite3_backup_init(dst, "main", c->db, "main");
        if (b) {
            sqlite3_backup_step(b, -1);
            sqlite3_backup_finish(b);
        }
        rc = sqlite3_errcode(dst);
    }
    if (rc != SQLITE_OK)
        sql_set_error(c, rc, dst ? sqlite3_errmsg(dst) : sqlite3_errstr(rc), -1);
    sqlite3_close_v2(dst);
    return rc == SQLITE_OK;
}

uint8_t gs_sql_serialize(uint64_t db, int64_t token, gs_sql_builder out) {
    sql_conn *c = sql_use(db, token, "serialize");
    if (!c) return 0;
    sqlite3_int64 size = 0;
    unsigned char *image = sqlite3_serialize(c->db, "main", &size, 0);
    if (!image) {
        /* An empty database serializes to nothing, which is not a failure. */
        if (size == 0) return 1;
        sql_set_error(c, SQLITE_NOMEM, "out of memory serializing the database", -1);
        return 0;
    }
    sql_append(out, image, size);
    sqlite3_free(image);
    return 1;
}

uint8_t gs_sql_deserialize(uint64_t db, int64_t token, gs_sql_bytes image) {
    sql_conn *c = sql_use(db, token, "deserialize");
    if (!c) return 0;
    if (c->depth) {
        sql_misuse("sqlite::deserialize: inside a transaction() block");
        return 0;
    }
    /* The schema is replaced, so the statements prepared against the old one
       go. */
    sql_drop_cache((uint32_t)db);
    int64_t n = image.len > 0 ? image.len : 0;
    unsigned char *copy = (unsigned char *)sqlite3_malloc64((sqlite3_uint64)(n ? n : 1));
    if (!copy) {
        sql_set_error(c, SQLITE_NOMEM, "out of memory deserializing a database", -1);
        return 0;
    }
    if (n) memcpy(copy, image.data, (size_t)n);
    int rc = sqlite3_deserialize(c->db, "main", copy, n, n,
                                 SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE);
    if (rc != SQLITE_OK) {
        sql_failed(c);
        return 0;
    }
    /* A database that is not one shows when it is first read. */
    rc = sql_exec(c, "SELECT count(*) FROM sqlite_schema");
    if (rc != SQLITE_OK) sql_failed(c);
    return rc == SQLITE_OK;
}

void gs_sql_forget(uint64_t db, gs_sql_bytes sql) {
    sql_conn *c = sql_open_conn_of(db, "forget");
    if (!c) return;
    uint32_t conn = (uint32_t)db;
    sqlite3_mutex_enter(sql_lock);
    for (uint32_t i = 1; i < sql_nstmts; i++) {
        sql_stmt *s = sql_stmts[i];
        if (s->st && s->conn == conn && s->sqllen == sql.len &&
            (sql.len == 0 || !memcmp(s->sql, sql.data, (size_t)sql.len)))
            sql_finalize(s);
    }
    sqlite3_mutex_leave(sql_lock);
}

int64_t gs_sql_cached_count(uint64_t db) {
    sql_conn *c = sql_open_conn_of(db, "cached_count");
    if (!c) return 0;
    uint32_t conn = (uint32_t)db;
    int64_t n = 0;
    sqlite3_mutex_enter(sql_lock);
    for (uint32_t i = 1; i < sql_nstmts; i++)
        if (sql_stmts[i]->st && sql_stmts[i]->conn == conn) n++;
    sqlite3_mutex_leave(sql_lock);
    return n;
}

/* --- transactions ------------------------------------------------------------------- */

int64_t gs_sql_begin(uint64_t db, int64_t token, uint8_t immediate) {
    sql_conn *c = sql_use(db, token, "transaction");
    if (!c) return 0;
    if (c->depth == SQL_MAX_DEPTH) {
        sql_misuse("sqlite::transaction: nested more than %d deep", SQL_MAX_DEPTH);
        return 0;
    }
    int rc;
    if (c->depth == 0) {
        /* A transaction begun outside the layer (exec("begin")) would make
           this one a savepoint of it, which the tokens could not account
           for. */
        if (!sqlite3_get_autocommit(c->db)) {
            sql_misuse("sqlite::transaction: a transaction begun with SQL is open; use "
                       "sqlite::transaction for both, or SQL for both");
            return 0;
        }
        rc = sql_exec(c, immediate ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED");
    } else {
        char buf[32];
        snprintf(buf, sizeof buf, "SAVEPOINT gs_sp%d", c->depth);
        rc = sql_exec(c, buf);
    }
    if (rc != SQLITE_OK) {
        sql_failed(c);
        return 0;
    }
    int64_t t = c->next_token++;
    c->tokens[c->depth++] = t;
    return t;
}

uint8_t gs_sql_end(uint64_t db, int64_t token, uint8_t commit) {
    sql_conn *c = sql_open_conn_of(db, "transaction");
    if (!c) return 0;
    int level = -1;
    for (int i = 0; i < c->depth; i++)
        if (c->tokens[i] == token) level = i;
    if (level < 0) {
        sql_misuse("sqlite::transaction: its transaction was rolled back while its block ran, "
                   "because the connection was used through an outer handle inside it; use "
                   "the block's own handle");
        return 0;
    }
    /* Levels inside this one whose blocks were left early. */
    sql_unwind(c, level + 1);
    int rc;
    if (level == 0) {
        rc = commit ? sql_exec(c, "COMMIT") : sql_exec(c, "ROLLBACK");
        if (rc != SQLITE_OK) {
            sql_failed(c);
            /* A commit that failed (busy, a deferred constraint) leaves the
               transaction open: roll it back, so the connection is in
               autocommit whatever happened, as it is after the block. */
            if (!sqlite3_get_autocommit(c->db)) sql_exec(c, "ROLLBACK");
        }
    } else {
        char buf[64];
        if (commit)
            snprintf(buf, sizeof buf, "RELEASE gs_sp%d", level);
        else
            snprintf(buf, sizeof buf, "ROLLBACK TO gs_sp%d; RELEASE gs_sp%d", level, level);
        rc = sql_exec(c, buf);
        if (rc != SQLITE_OK) sql_failed(c);
    }
    c->depth = level;
    return rc == SQLITE_OK;
}

/* --- statements -------------------------------------------------------------------- */

uint64_t gs_sql_prepare(uint64_t db, int64_t token, gs_sql_bytes sql) {
    sql_conn *c = sql_use(db, token, "prepare");
    if (!c) return 0;
    uint32_t conn = (uint32_t)db;
    c->clock++;
    sqlite3_mutex_enter(sql_lock);
    for (uint32_t i = 1; i < sql_nstmts; i++) {
        sql_stmt *s = sql_stmts[i];
        if (s->st && s->conn == conn && s->sqllen == sql.len &&
            (sql.len == 0 || !memcmp(s->sql, sql.data, (size_t)sql.len)) &&
            !sqlite3_stmt_busy(s->st)) {
            sqlite3_reset(s->st);
            sqlite3_clear_bindings(s->st);
            s->used = c->clock;
            s->on_row = 0;
            s->row_failed = 0;
            uint64_t h = sql_handle(s->gen, i);
            sqlite3_mutex_leave(sql_lock);
            return h;
        }
    }
    sqlite3_mutex_leave(sql_lock);
    /* Not cached, or every copy is mid-step (a nested each() of the same
       SQL): prepare another. */
    sqlite3_stmt *st = NULL;
    const char *tail = NULL;
    int rc = sqlite3_prepare_v3(c->db, (const char *)sql.data, (int)sql.len,
                                SQLITE_PREPARE_PERSISTENT, &st, &tail);
    if (rc != SQLITE_OK) {
        sql_failed(c);
        return 0;
    }
    if (!st) {
        sql_set_error(c, SQLITE_MISUSE, "the SQL has no statement in it", -1);
        return 0;
    }
    /* More than one statement: the rest would be ignored. */
    if (tail && tail < (const char *)sql.data + sql.len) {
        const char *t = tail;
        while (t < (const char *)sql.data + sql.len && (*t == ' ' || *t == '\t' || *t == '\n' ||
                                                      *t == '\r' || *t == ';'))
            t++;
        if (t < (const char *)sql.data + sql.len) {
            sqlite3_finalize(st);
            sql_set_error(c, SQLITE_MISUSE,
                          "more than one statement; use sqlite::exec_script for several",
                          (int)(t - (const char *)sql.data));
            return 0;
        }
    }
    uint32_t slot;
    sqlite3_mutex_enter(sql_lock);
    sql_stmt *s = (sql_stmt *)sql_new_slot((void ***)&sql_stmts, &sql_nstmts, sizeof(sql_stmt),
                                           sql_stmt_free, &slot);
    char *copy = s ? (char *)malloc((size_t)(sql.len > 0 ? sql.len : 1)) : NULL;
    if (!s || !copy) {
        sqlite3_mutex_leave(sql_lock);
        free(copy);
        sqlite3_finalize(st);
        sql_set_error(c, SQLITE_NOMEM, "out of memory for a statement", -1);
        return 0;
    }
    if (sql.len > 0) memcpy(copy, sql.data, (size_t)sql.len);
    s->st = st;
    s->conn = conn;
    s->owner = c;
    s->sql = copy;
    s->sqllen = sql.len;
    s->used = c->clock;
    s->on_row = 0;
    s->row_failed = 0;
    s->gen++;
    uint64_t h = sql_handle(s->gen, slot);
    sql_evict(conn, c->cache_cap, s);
    sqlite3_mutex_leave(sql_lock);
    return h;
}

int32_t gs_sql_param_count(uint64_t st) {
    sql_stmt *s = sql_stmt_of(st, "param_count");
    return s ? sqlite3_bind_parameter_count(s->st) : 0;
}

int32_t gs_sql_param_index(uint64_t st, gs_sql_bytes name) {
    sql_stmt *s = sql_stmt_of(st, "param_index");
    if (!s) return 0;
    char *n = sql_cstr(name);
    int i = n ? sqlite3_bind_parameter_index(s->st, n) : 0;
    free(n);
    return i;
}

void gs_sql_param_name(uint64_t st, int32_t i, gs_sql_builder out) {
    sql_stmt *s = sql_stmt_of(st, "param_name");
    if (!s) return;
    if (i < 1 || i > sqlite3_bind_parameter_count(s->st)) {
        sql_misuse("sqlite::param_name: parameter %d of a statement with %d", i,
                   sqlite3_bind_parameter_count(s->st));
        return;
    }
    sql_append_str(out, sqlite3_bind_parameter_name(s->st, i));
}

/* A bind's outcome: an index out of range is a misuse; anything else that
   fails (a value too big) is an error of the connection. */
static uint8_t sql_bound(sql_stmt *s, int rc, int32_t i) {
    if (rc == SQLITE_OK) return 1;
    if (rc == SQLITE_RANGE) {
        sql_misuse("sqlite::bind: parameter %d of a statement with %d", i,
                   sqlite3_bind_parameter_count(s->st));
        return 0;
    }
    sql_failed(s->owner);
    return 0;
}

uint8_t gs_sql_bind_i64(uint64_t st, int32_t i, int64_t v) {
    sql_stmt *s = sql_stmt_of(st, "bind");
    return s ? sql_bound(s, sqlite3_bind_int64(s->st, i, v), i) : 0;
}

uint8_t gs_sql_bind_f64(uint64_t st, int32_t i, double v) {
    sql_stmt *s = sql_stmt_of(st, "bind");
    return s ? sql_bound(s, sqlite3_bind_double(s->st, i, v), i) : 0;
}

uint8_t gs_sql_bind_text(uint64_t st, int32_t i, gs_sql_bytes v) {
    sql_stmt *s = sql_stmt_of(st, "bind");
    /* An empty slice may have no data pointer; SQLite takes a null pointer
       as NULL, not as empty text. */
    return s ? sql_bound(s, sqlite3_bind_text64(s->st, i, v.data ? (const char *)v.data : "",
                                               (sqlite3_uint64)(v.len > 0 ? v.len : 0),
                                               SQLITE_TRANSIENT, SQLITE_UTF8), i)
             : 0;
}

uint8_t gs_sql_bind_blob(uint64_t st, int32_t i, gs_sql_bytes v) {
    sql_stmt *s = sql_stmt_of(st, "bind");
    if (!s) return 0;
    int rc = v.len > 0 ? sqlite3_bind_blob64(s->st, i, v.data, (sqlite3_uint64)v.len, SQLITE_TRANSIENT)
                       : sqlite3_bind_zeroblob(s->st, i, 0);
    return sql_bound(s, rc, i);
}

uint8_t gs_sql_bind_null(uint64_t st, int32_t i) {
    sql_stmt *s = sql_stmt_of(st, "bind");
    return s ? sql_bound(s, sqlite3_bind_null(s->st, i), i) : 0;
}

int32_t gs_sql_step(uint64_t st) {
    sql_stmt *s = sql_stmt_of(st, "step");
    if (!s) return SQLITE_MISUSE;
    sql_conn *c = s->owner;
    s->used = ++c->clock;
    int rc = sqlite3_step(s->st);
    s->on_row = rc == SQLITE_ROW;
    if (rc != SQLITE_ROW && rc != SQLITE_DONE) {
        sql_failed(c);
        /* The statement is done with; a later step would repeat it. */
        sqlite3_reset(s->st);
        rc &= 0xff;
    }
    return rc;
}

void gs_sql_reset(uint64_t st) {
    sql_stmt *s = sql_stmt_of(st, "reset");
    if (!s) return;
    sqlite3_reset(s->st);
    s->on_row = 0;
    s->row_failed = 0;
}

uint8_t gs_sql_readonly(uint64_t st) {
    sql_stmt *s = sql_stmt_of(st, "readonly");
    return s ? (uint8_t)sqlite3_stmt_readonly(s->st) : 0;
}

void gs_sql_sql(uint64_t st, gs_sql_builder out) {
    sql_stmt *s = sql_stmt_of(st, "sql");
    if (s) sql_append(out, s->sql, s->sqllen);
}

int32_t gs_sql_column_count(uint64_t st) {
    sql_stmt *s = sql_stmt_of(st, "column_count");
    return s ? sqlite3_column_count(s->st) : 0;
}

/* The statement of a row read: on a row, and the column in range. */
static sql_stmt *sql_row_of(uint64_t st, int32_t i, const char *fn) {
    sql_stmt *s = sql_stmt_of(st, fn);
    if (!s) return NULL;
    if (!s->on_row) {
        sql_misuse("sqlite::%s: a row read outside the block it was given to", fn);
        return NULL;
    }
    int n = sqlite3_column_count(s->st);
    if (i < 0 || i >= n) {
        sql_misuse("sqlite::%s: column %d of a row with %d", fn, i, n);
        return NULL;
    }
    return s;
}

int32_t gs_sql_column_type(uint64_t st, int32_t i) {
    sql_stmt *s = sql_row_of(st, i, "column_type");
    return s ? sqlite3_column_type(s->st, i) : SQLITE_NULL;
}

int64_t gs_sql_column_i64(uint64_t st, int32_t i) {
    sql_stmt *s = sql_row_of(st, i, "int");
    return s ? sqlite3_column_int64(s->st, i) : 0;
}

double gs_sql_column_f64(uint64_t st, int32_t i) {
    sql_stmt *s = sql_row_of(st, i, "real");
    return s ? sqlite3_column_double(s->st, i) : 0;
}

int64_t gs_sql_column_bytes(uint64_t st, int32_t i) {
    sql_stmt *s = sql_row_of(st, i, "column_bytes");
    return s ? sqlite3_column_bytes(s->st, i) : 0;
}

void gs_sql_column_text(uint64_t st, int32_t i, gs_sql_builder out) {
    sql_stmt *s = sql_row_of(st, i, "text");
    if (!s) return;
    const unsigned char *p = sqlite3_column_text(s->st, i);
    sql_append(out, p, sqlite3_column_bytes(s->st, i));
}

void gs_sql_column_blob(uint64_t st, int32_t i, gs_sql_builder out) {
    sql_stmt *s = sql_row_of(st, i, "blob");
    if (!s) return;
    const void *p = sqlite3_column_blob(s->st, i);
    sql_append(out, p, sqlite3_column_bytes(s->st, i));
}

void gs_sql_column_name(uint64_t st, int32_t i, gs_sql_builder out) {
    sql_stmt *s = sql_stmt_of(st, "column_name");
    if (!s) return;
    int n = sqlite3_column_count(s->st);
    if (i < 0 || i >= n) {
        sql_misuse("sqlite::column_name: column %d of a statement with %d", i, n);
        return;
    }
    sql_append_str(out, sqlite3_column_name(s->st, i));
}

void gs_sql_column_decltype(uint64_t st, int32_t i, gs_sql_builder out) {
    sql_stmt *s = sql_stmt_of(st, "column_decltype");
    if (!s) return;
    int n = sqlite3_column_count(s->st);
    if (i < 0 || i >= n) {
        sql_misuse("sqlite::column_decltype: column %d of a statement with %d", i, n);
        return;
    }
    sql_append_str(out, sqlite3_column_decltype(s->st, i));
}

/* --- rows of checked statements ----------------------------------------------- */

/* A value of the current row did not fit the field it was read into: an
   outcome of the data, not a misuse. The connection keeps it as its error
   (MISMATCH), and the loop reading the rows stops. */
void gs_sql_fail_row(uint64_t st, int32_t i, gs_sql_bytes msg) {
    sql_stmt *s = sql_stmt_of(st, "fail_row");
    if (!s) return;
    char buf[512];
    const char *name = s->on_row && i >= 0 && i < sqlite3_column_count(s->st)
                           ? sqlite3_column_name(s->st, i) : "?";
    snprintf(buf, sizeof buf, "column %d (%s): %.*s", i, name ? name : "?",
             (int)(msg.len > 400 ? 400 : msg.len), msg.data ? (const char *)msg.data : "");
    sql_set_error(s->owner, SQLITE_MISMATCH, buf, -1);
    s->row_failed = 1;
}

uint8_t gs_sql_row_failed(uint64_t st) {
    sql_stmt *s = sql_stmt_of(st, "row_failed");
    return s ? (uint8_t)s->row_failed : 0;
}

/* --- errors the Goose side finds ---------------------------------------------- */

/* A failure found by the module rather than by SQLite: a database that does
   not match the schema a program was compiled against. */
void gs_sql_fail(uint64_t db, int32_t code, gs_sql_bytes msg) {
    sql_conn *c = sql_conn_of(db, "fail");
    if (!c) return;
    char *text = sql_cstr(msg);
    sql_set_error(c, code, text ? text : "out of memory", -1);
    free(text);
}
