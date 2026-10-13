// Checked SQL (docs/design/sqlite_checked.md): the compiler's own SQLite.
//
// A program declares a schema as migrations, `let SCHEMA =
// sqlite::schema(...)`, and its statements against it, `let q =
// sqlite::statement(SCHEMA, "select ...")`. This file holds what the
// compiler learns from them: it applies a schema's migrations to an
// in-memory database of its own, prepares each statement there, and asks
// SQLite for its parameters and its columns -- their names, declared types,
// the table columns they come from, and whether they can be NULL. The
// SQLite is the one the program links (third_party/sqlite, built into the
// compiler for JIT runs), so SQL the compiler accepts is SQL the program
// can run.
//
// What uses it: the checker lowers calls through a checked statement into
// the unchecked library calls with the SQL in them (typecheck_sqlite.h);
// `type X = sqlite::row_type(q);` becomes a struct before type names are
// resolved (ExpandSqlRowTypes); `--sqlite-types` prints such a struct for
// every statement. All of them read the declarations as parsed -- a
// statement's schema may be checked before or after it -- so nothing here
// depends on the order the checker visits globals in.

#pragma once

#ifdef GOOSE_HAVE_SQLITE
#include "sqlite3.h"
#endif

namespace goose {

#ifdef GOOSE_HAVE_SQLITE
inline constexpr bool have_sql_check = true;
#else
inline constexpr bool have_sql_check = false;
#endif

// A column's type affinity (SQLite's own rules, from its declared type), or
// none for an expression, which has no declared type.
enum SqlAffinity { SA_NONE, SA_INTEGER, SA_REAL, SA_TEXT, SA_BLOB, SA_NUMERIC };

inline const char *SqlAffinityName(SqlAffinity a) {
    switch (a) {
        case SA_INTEGER: return "INTEGER";
        case SA_REAL:    return "REAL";
        case SA_TEXT:    return "TEXT";
        case SA_BLOB:    return "BLOB";
        case SA_NUMERIC: return "NUMERIC";
        default:         return "an expression's (none)";
    }
}

// The affinity of a declared type (sqlite.org/datatype3.html, 3.1). A
// column declared without a type is BLOB; an expression is none.
inline SqlAffinity SqlAffinityOf(const char *decl, bool expression) {
    if (expression) return SA_NONE;
    string d;
    for (auto p = decl ? decl : ""; *p; p++) d += (char)toupper((unsigned char)*p);
    if (d.find("INT") != string::npos) return SA_INTEGER;
    if (d.find("CHAR") != string::npos || d.find("CLOB") != string::npos ||
        d.find("TEXT") != string::npos)
        return SA_TEXT;
    if (d.empty() || d.find("BLOB") != string::npos) return SA_BLOB;
    if (d.find("REAL") != string::npos || d.find("FLOA") != string::npos ||
        d.find("DOUB") != string::npos)
        return SA_REAL;
    return SA_NUMERIC;
}

struct SqlColumn {
    string name;            // As the program matches it: the alias, its markers removed.
    string decl;            // The declared type, empty for an expression.
    string table, origin;   // The table column it comes from, empty for an expression.
    SqlAffinity aff = SA_NONE;
    bool nullable = true;   // Can be NULL, as far as the compiler can tell (design §4.3).
    char marker = 0;        // '!' or '?' from the alias, 0 for none.
    string typeword;        // `as "n: integer"`: the type an expression's column says it is.
};

struct SqlSchema {
    const VarDecl *global = nullptr;
    vector<string> migrations;
    Line line;
#ifdef GOOSE_HAVE_SQLITE
    sqlite3 *db = nullptr;
#endif
};

struct SqlStmt {
    const VarDecl *global = nullptr;
    int schema = -1;
    string sql;
    Line line;                      // Of the call declaring it.
    int nparams = 0;
    vector<string> pnames;          // Without their prefix, for named parameters; else empty.
    bool named = false;             // :name, @name or $name rather than ?.
    vector<SqlColumn> cols;
    bool readonly = true;
    bool outerjoin = false;
};

// Everything checked so far, for the whole program; owned by the Ast.
struct SqlCatalog {
    vector<SqlSchema> schemas;
    vector<SqlStmt> stmts;
    map<const VarDecl *, int> schemaof, stmtof;
    // A row type that could not be made, reported when checking starts: it
    // is a checking error, not a resolution one, however early it is found.
    vector<pair<Line, string>> deferred;
    ~SqlCatalog() {
#ifdef GOOSE_HAVE_SQLITE
        for (auto &s : schemas) sqlite3_close(s.db);
#endif
    }
};

inline SqlCatalog &Catalog(Ast &ast) {
    if (!ast.sqlcat) ast.sqlcat = make_shared<SqlCatalog>();
    return *ast.sqlcat;
}

// Reports an error at a line and does not return.
using SqlErr = function<void(Line, const string &)>;
// The string literal a compile-time string argument stands for, or null.
using SqlStr = function<StrLit *(Node *)>;

inline const char *no_sql_check_error =
    "this compiler was built without SQLite, which checked SQL needs; run "
    "scripts/fetch_sqlite.py and reconfigure";

// The directory part of a path, with its separator: where schema_file's
// relative paths start.
inline string SqlDirOf(const string &path) {
    auto pos = path.find_last_of("/\\");
    return pos == string::npos ? string() : path.substr(0, pos + 1);
}

// A call `sqlite::leaf(...)`, spelled qualified or written in namespace sqlite.
inline bool IsSqliteCall(const Node *n, string_view leaf) {
    auto c = dynamic_cast<const Call *>(n);
    if (!c) return false;
    auto id = dynamic_cast<const Ident *>(c->callee);
    if (!id) return false;
    auto ref = SplitName(id->name, id->ns);
    return ref.ns == "sqlite" && ref.leaf == leaf;
}

// The global a name refers to, as a declaration rather than a variable:
// before typechecking there are no variables.
inline VarDecl *SqlGlobal(Ast &ast, const Node *n) {
    auto id = dynamic_cast<const Ident *>(n);
    return id ? ast.LookupGlobal(id->name, id->ns) : nullptr;
}

// A compile-time string before typechecking: a literal, or a let/const
// global initialized with one, through any chain of such globals.
inline StrLit *SqlStaticStr(Ast &ast, Node *n) {
    set<const VarDecl *> seen;
    for (;;) {
        if (auto s = dynamic_cast<StrLit *>(n)) return s;
        auto g = SqlGlobal(ast, n);
        if (!g || g->isvar || g->inits.size() != 1 || !seen.insert(g).second) return nullptr;
        n = g->inits[0];
    }
}

// The source line of byte `offset` of a literal's text: a `"""` literal's
// line k is the source's line `line + k` (StrLit); a one-line literal is on
// its own line, and so is an unknown offset (-1).
inline Line SqlLineAt(const StrLit *lit, int offset) {
    auto at = lit->line;
    if (!lit->multiline || offset < 0) return at;
    auto upto = min((size_t)offset, lit->val.size());
    at.line += 1 + (int)count(lit->val.begin(), lit->val.begin() + (long)upto, '\n');
    return at;
}

// The ids handed to the program are the catalog's indices; a call already
// lowered (`sqlite::schema_of(3)`) names its id.
inline int SqlLoweredId(const Node *init, string_view leaf) {
    if (!IsSqliteCall(init, leaf)) return -1;
    auto c = (const Call *)init;
    if (c->args.size() != 1) return -1;
    auto i = dynamic_cast<const IntLit *>(c->args[0]);
    return i ? (int)i->val : -1;
}

#ifdef GOOSE_HAVE_SQLITE

// Runs every statement of `sql` on `db`: a migration. False with the
// failing statement's message and the byte offset of the error in `sql`.
inline bool SqlRunScript(sqlite3 *db, const string &sql, string &msg, int &offset) {
    auto base = sql.c_str();
    auto p = base;
    while (*p) {
        sqlite3_stmt *st = nullptr;
        const char *tail = nullptr;
        if (sqlite3_prepare_v2(db, p, -1, &st, &tail) != SQLITE_OK) {
            msg = sqlite3_errmsg(db);
            auto o = sqlite3_error_offset(db);
            offset = o >= 0 ? (int)(p - base) + o : (int)(p - base);
            return false;
        }
        if (st) {
            while (sqlite3_step(st) == SQLITE_ROW) {}
            if (sqlite3_finalize(st) != SQLITE_OK) {
                msg = sqlite3_errmsg(db);
                offset = (int)(p - base);
                return false;
            }
        }
        if (!tail || tail == p) break;
        p = tail;
    }
    return true;
}

#endif

// The schema a global declares: `let S = sqlite::schema(migration, ...)` or
// `sqlite::schema_file(path, ...)`, applied once to the compiler's database
// and remembered. `str` resolves its arguments; `file` is the declaring
// file's path, for schema_file's relative paths.
inline int SqlSchemaOf(Ast &ast, const VarDecl *g, Line use, const SqlErr &err, const SqlStr &str) {
    auto &cat_ = Catalog(ast);
    if (auto it = cat_.schemaof.find(g); it != cat_.schemaof.end()) return it->second;
    auto init = g && g->inits.size() == 1 ? g->inits[0] : nullptr;
    auto fromfile = IsSqliteCall(init, "schema_file");
    if (!IsSqliteCall(init, "schema") && !fromfile)
        err(use, "a checked statement's schema is a global declared as "
                 "`let SCHEMA = sqlite::schema(migration, ...)`");
    if (!have_sql_check) err(init->line, no_sql_check_error);
    auto c = (Call *)init;
    if (c->args.empty()) err(c->line, "sqlite::schema needs at least one migration");
    SqlSchema s;
    s.global = g;
    s.line = c->line;
    vector<StrLit *> lits;
    for (auto a : c->args) {
        auto lit = str(a);
        if (!lit)
            err(a->line, cat("sqlite::", fromfile ? "schema_file" : "schema",
                             " takes string literals, and let or const globals initialized "
                             "with one"));
        lits.push_back(lit);
        if (!fromfile) {
            s.migrations.push_back(lit->val);
            continue;
        }
        auto path = cat(SqlDirOf(ast.sources[c->line.fileidx].first), lit->val);
        string text;
        if (!LoadFile(path, text)) err(a->line, cat("sqlite::schema_file: cannot read ", path));
        s.migrations.push_back(text);
    }
#ifdef GOOSE_HAVE_SQLITE
    if (sqlite3_open(":memory:", &s.db) != SQLITE_OK) err(c->line, "sqlite: cannot open a database");
    sqlite3_exec(s.db, "PRAGMA foreign_keys = ON", nullptr, nullptr, nullptr);
    for (size_t i = 0; i < s.migrations.size(); i++) {
        string msg;
        int offset = -1;
        if (SqlRunScript(s.db, s.migrations[i], msg, offset)) continue;
        if (fromfile) {
            auto path = cat(SqlDirOf(ast.sources[c->line.fileidx].first), lits[i]->val);
            auto upto = min((size_t)max(offset, 0), s.migrations[i].size());
            auto line = 1 + (int)count(s.migrations[i].begin(),
                                       s.migrations[i].begin() + (long)upto, '\n');
            sqlite3_close(s.db);
            err(lits[i]->line, cat("sqlite: ", msg, " (", path, ":", line, ", migration ",
                                   (int64_t)i + 1, ")"));
        }
        sqlite3_close(s.db);
        err(SqlLineAt(lits[i], offset), cat("sqlite: ", msg, " (migration ", (int64_t)i + 1, ")"));
    }
#endif
    cat_.schemas.push_back(std::move(s));
    return cat_.schemaof[g] = (int)cat_.schemas.size() - 1;
}

#ifdef GOOSE_HAVE_SQLITE

// Whether the statement can fill a row with NULLs for a table that had no
// match: an outer join. SQLite's bytecode marks the cursor it NULL-fills,
// but that cursor may be an index it built for the join rather than the
// table, and EXPLAIN's output is not a stable interface, so only the yes or
// no is used (design §4.3).
inline bool SqlHasOuterJoin(sqlite3 *db, const string &sql) {
    sqlite3_stmt *st = nullptr;
    auto ex = cat("EXPLAIN ", sql);
    if (sqlite3_prepare_v2(db, ex.c_str(), -1, &st, nullptr) != SQLITE_OK) return true;
    auto found = false;
    while (!found && sqlite3_step(st) == SQLITE_ROW) {
        auto op = (const char *)sqlite3_column_text(st, 1);
        found = op && !strcmp(op, "NullRow");
    }
    sqlite3_finalize(st);
    return found;
}

// A column's alias with its markers: `"posts!"` is non-null, `"email?"`
// nullable, `"n: integer"` an expression of that type, and the two together
// `"n: integer!"` (or `"n!: integer"`).
inline void SqlParseAlias(SqlColumn &col) {
    auto trim = [](string &s) {
        while (!s.empty() && s[0] == ' ') s.erase(0, 1);
        while (!s.empty() && s.back() == ' ') s.pop_back();
    };
    auto marker = [&](string &s) {
        trim(s);
        if (!s.empty() && (s.back() == '!' || s.back() == '?')) {
            col.marker = s.back();
            s.pop_back();
            trim(s);
        }
    };
    auto &n = col.name;
    if (auto colon = n.find(':'); colon != string::npos) {
        col.typeword = n.substr(colon + 1);
        n = n.substr(0, colon);
        marker(col.typeword);
    }
    marker(n);
}

#endif

// The statement a global declares: `let q = sqlite::statement(SCHEMA,
// sql)`, prepared once against its schema and remembered.
inline int SqlStatementOf(Ast &ast, const VarDecl *g, Line use, const SqlErr &err,
                          const SqlStr &str) {
    auto &cat_ = Catalog(ast);
    if (auto it = cat_.stmtof.find(g); it != cat_.stmtof.end()) return it->second;
    auto init = g && g->inits.size() == 1 ? g->inits[0] : nullptr;
    if (!IsSqliteCall(init, "statement"))
        err(use, "a checked statement is a global declared as "
                 "`let q = sqlite::statement(SCHEMA, sql)`");
    auto c = (Call *)init;
    if (c->args.size() != 2) err(c->line, "sqlite::statement(SCHEMA, sql) takes a schema and the SQL");
    auto sg = SqlGlobal(ast, c->args[0]);
    if (!sg) err(c->args[0]->line, "sqlite::statement's schema is the global it was declared as");
    auto schema = SqlSchemaOf(ast, sg, c->args[0]->line, err, str);
    auto lit = str(c->args[1]);
    if (!lit)
        err(c->args[1]->line, "sqlite::statement takes its SQL as a string literal, or a let or "
                              "const global initialized with one");
    SqlStmt s;
    s.global = g;
    s.schema = schema;
    s.sql = lit->val;
    s.line = c->line;
#ifdef GOOSE_HAVE_SQLITE
    auto db = cat_.schemas[schema].db;
    sqlite3_stmt *st = nullptr;
    const char *tail = nullptr;
    if (sqlite3_prepare_v2(db, s.sql.c_str(), (int)s.sql.size(), &st, &tail) != SQLITE_OK)
        err(SqlLineAt(lit, sqlite3_error_offset(db)), cat("sqlite: ", sqlite3_errmsg(db)));
    if (!st) err(lit->line, "sqlite::statement: the SQL has no statement in it");
    auto rest = string_view(tail ? tail : "");
    if (rest.find_first_not_of(" \t\r\n;") != string_view::npos) {
        sqlite3_finalize(st);
        err(SqlLineAt(lit, (int)(tail - s.sql.c_str())),
            "sqlite::statement: more than one statement; a schema's migrations hold several");
    }
    s.nparams = sqlite3_bind_parameter_count(st);
    auto positional = 0;
    for (int i = 1; i <= s.nparams; i++) {
        auto nm = sqlite3_bind_parameter_name(st, i);
        if (!nm || nm[0] == '?') {
            positional++;
            continue;
        }
        s.named = true;
        s.pnames.push_back(nm + 1);
    }
    if (s.named && positional) {
        sqlite3_finalize(st);
        err(lit->line, "sqlite::statement: the SQL mixes ? and named parameters; use one kind");
    }
    s.readonly = sqlite3_stmt_readonly(st) != 0;
    s.outerjoin = SqlHasOuterJoin(db, s.sql);
    for (int i = 0; i < sqlite3_column_count(st); i++) {
        SqlColumn col;
        col.name = sqlite3_column_name(st, i);
        SqlParseAlias(col);
        auto decl = sqlite3_column_decltype(st, i);
        auto tab = sqlite3_column_table_name(st, i), orig = sqlite3_column_origin_name(st, i);
        col.decl = decl ? decl : "";
        col.aff = SqlAffinityOf(decl, !tab || !orig);
        if (tab && orig) {
            col.table = tab;
            col.origin = orig;
            int notnull = 0, pk = 0;
            const char *ctype = nullptr;
            sqlite3_table_column_metadata(db, nullptr, tab, orig, &ctype, nullptr, &notnull, &pk,
                                          nullptr);
            // An INTEGER PRIMARY KEY is the rowid, never NULL; another
            // primary key column can be, in SQLite, unless declared NOT NULL.
            auto rowid = pk && ctype && !sqlite3_stricmp(ctype, "INTEGER");
            col.nullable = !(notnull || rowid) || s.outerjoin;
        }
        if (col.marker == '!') col.nullable = false;
        if (col.marker == '?') col.nullable = true;
        s.cols.push_back(std::move(col));
    }
    sqlite3_finalize(st);
#else
    err(c->line, no_sql_check_error);
#endif
    cat_.stmts.push_back(std::move(s));
    return cat_.stmtof[g] = (int)cat_.stmts.size() - 1;
}

// Every statement a schema's global has, in declaration order: what
// sqlite::open(path, SCHEMA) checks the database file against.
inline vector<int> SqlStatementsOfSchema(Ast &ast, const VarDecl *schema, const SqlErr &err,
                                         const SqlStr &str) {
    vector<int> out;
    vector<VarDecl *> globals = ast.globals;
    std::stable_sort(globals.begin(), globals.end(), [](VarDecl *a, VarDecl *b) {
        return a->line.fileidx != b->line.fileidx ? a->line.fileidx < b->line.fileidx
                                                  : a->line.line < b->line.line;
    });
    for (auto g : globals) {
        if (g->inits.size() != 1) continue;
        auto init = g->inits[0];
        auto lowered = SqlLoweredId(init, "statement_of");
        if (lowered >= 0) {
            auto &cat_ = Catalog(ast);
            if (cat_.schemas[cat_.stmts[lowered].schema].global == schema) out.push_back(lowered);
            continue;
        }
        if (!IsSqliteCall(init, "statement") || ((Call *)init)->args.size() != 2) continue;
        if (SqlGlobal(ast, ((Call *)init)->args[0]) != schema) continue;
        out.push_back(SqlStatementOf(ast, g, g->line, err, str));
    }
    return out;
}

// --- generated row types -------------------------------------------------------------

// The Goose type a column is read into when the program does not say:
// i64, f64 or u8[] by affinity, Nullable<...> where it can be NULL. An
// expression without a declared type says what it is in its alias.
inline string SqlFieldType(const SqlColumn &col, string &why) {
    auto aff = col.aff;
    if (!col.typeword.empty()) {
        aff = SqlAffinityOf(col.typeword.c_str(), false);
    } else if (aff == SA_NONE) {
        why = cat("column ", col.name, " is an expression, which has no declared type: say "
                  "what it is in its alias, as `as \"", col.name, ": integer\"`");
        return {};
    }
    string t;
    switch (aff) {
        case SA_INTEGER: t = "i64"; break;
        case SA_REAL:    t = "f64"; break;
        case SA_NUMERIC: t = "f64"; break;
        default:         t = "u8[]"; break;
    }
    return col.nullable ? cat("sqlite::Nullable<", t, ">") : t;
}

// Whether a column name is a Goose identifier a field can have.
inline bool SqlIsIdent(const string &s) {
    if (s.empty() || !(isalpha((unsigned char)s[0]) || s[0] == '_')) return false;
    for (auto ch : s)
        if (!(isalnum((unsigned char)ch) || ch == '_')) return false;
    return true;
}

// `struct name { field: type, ... }` for a statement's columns; empty, with
// `why`, where its columns make none.
inline string SqlRowStruct(const SqlStmt &s, string_view name, string &why) {
    if (s.cols.empty()) {
        why = "the statement returns no rows, so there is no row type";
        return {};
    }
    string out = cat("struct ", name, " {");
    set<string> seen;
    for (size_t i = 0; i < s.cols.size(); i++) {
        auto &col = s.cols[i];
        if (!SqlIsIdent(col.name)) {
            why = cat("column ", (int64_t)i, " is named `", col.name, "`, which is no field name: "
                      "give it an alias");
            return {};
        }
        string lower;
        for (auto ch : col.name) lower += (char)tolower((unsigned char)ch);
        if (!seen.insert(lower).second) {
            why = cat("two columns are named ", col.name, ": give one an alias");
            return {};
        }
        auto t = SqlFieldType(col, why);
        if (t.empty()) return {};
        Append(out, i ? ", " : " ", col.name, ": ", t);
    }
    out += " }";
    return out;
}

// The pre-typecheck errors: `file:line: error: msg`, as name resolution
// reports them.
inline SqlErr SqlParseErr(Ast &ast) {
    return [&ast](Line l, const string &msg) {
        throw CompileError { cat(ast.sources[l.fileidx].first, ":", l.line, ": error: ", msg) };
    };
}

// `type X = sqlite::row_type(q);` becomes `struct X { ... }`, parsed into
// the program as a source of its own, before type names are resolved. The
// dump keeps the alias as written: this runs after it is taken.
inline void ExpandSqlRowTypes(Ast &ast) {
    vector<AliasDecl *> pending;
    for (auto d : ast.topdecls)
        if (auto ad = dynamic_cast<AliasDecl *>(d); ad && !ad->al->rowstmt.empty())
            pending.push_back(ad);
    if (pending.empty()) return;
    // An error leaves an empty struct of the name, so resolution goes on,
    // and the checker reports it first thing.
    struct Deferred {};
    SqlErr err = [&ast](Line l, const string &msg) {
        Catalog(ast).deferred.push_back({ l, msg });
        throw Deferred {};
    };
    SqlStr str = [&ast](Node *n) { return SqlStaticStr(ast, n); };
    for (auto ad : pending) {
        auto al = ad->al;
        string body;
        try {
            auto g = ast.LookupGlobal(al->rowstmt, al->ns);
            if (!g) err(al->line, cat("sqlite::row_type: no global ", al->rowstmt));
            auto &s = Catalog(ast).stmts[SqlStatementOf(ast, g, al->line, err, str)];
            string why;
            body = SqlRowStruct(s, al->name, why);
            if (body.empty()) err(al->line, cat("sqlite::row_type(", al->rowstmt, "): ", why));
        } catch (Deferred &) {
            body = cat("struct ", al->name, " {}");
        }
        auto text = cat(al->ns.empty() ? "" : cat("namespace ", al->ns, ";\n"), body, "\n");
        auto fileidx = (int)ast.sources.size();
        ast.sources.emplace_back(cat(ast.sources[al->line.fileidx].first, ":", al->line.line,
                                     " (sqlite::row_type)"),
                                 make_unique<string>(text));
        Parser parser(ast, ast.sources.back().first, ast.sources.back().second->c_str(), fileidx);
        parser.ParseTop();
        ast.topdecls.erase(std::find(ast.topdecls.begin(), ast.topdecls.end(), (Node *)ad));
        ast.aliases.erase(std::find(ast.aliases.begin(), ast.aliases.end(), al));
    }
}

// What `--sqlite-types` prints: a struct for every checked statement that
// returns rows, named after its global, ready to paste.
inline string SqlTypesListing(Ast &ast) {
    auto err = SqlParseErr(ast);
    SqlStr str = [&ast](Node *n) { return SqlStaticStr(ast, n); };
    string out;
    for (auto g : ast.globals) {
        if (g->inits.size() != 1 || !IsSqliteCall(g->inits[0], "statement") || g->names.size() != 1)
            continue;
        auto &s = Catalog(ast).stmts[SqlStatementOf(ast, g, g->line, err, str)];
        if (s.cols.empty()) continue;
        string name;
        auto up = true;
        for (auto ch : g->names[0]) {
            if (ch == '_') { up = true; continue; }
            name += up ? (char)toupper((unsigned char)ch) : ch;
            up = false;
        }
        name += "Row";
        auto &path = ast.sources[g->line.fileidx].first;
        string why;
        auto body = SqlRowStruct(s, name, why);
        if (body.empty()) err(g->line, cat("sqlite: ", g->names[0], ": ", why));
        Append(out, "// ", path.substr(SqlDirOf(path).size()), ":", g->line.line, ": ",
               g->names[0], "\n", body, "\n");
    }
    return out;
}

}  // namespace goose
