// Checked SQL in the checker (docs/design/sqlite_checked.md). A call through
// a checked statement is lowered, in place, into the unchecked library call
// it stands for, with the statement's SQL in it, and then checked as that
// call: everything after the checker sees only ordinary calls.
//
//   sqlite::schema(m, ...) / schema_file(p, ...)  ->  sqlite::schema_of(K)
//   sqlite::statement(S, sql)                     ->  sqlite::statement_of(N)
//   sqlite::exec(db, q, args...)                  ->  sqlite::exec(db, "sql", args...)
//       (query, each, one and the scalar forms the same)
//   sqlite::rows<T>(db, q, args...)               ->  sqlite::query(db, "sql", args...)
//                                                         { r => T { f: read(r, i), ... } }
//   sqlite::one<T>(db, q, args...)                ->  sqlite::one_of(db, "sql", args...)
//                                                         { r, has => if has { T {...} } else { T's default } }
//   sqlite::each<T>(db, q, args...) { u => ... }  ->  sqlite::each(db, "sql", args...)
//                                                         { r => let u = T {...}; ... }
//   sqlite::open(path, S[, def]) / migrate(db, S) ->  open_schema / migrate_schema with S's
//                                                     migrations and what each statement is
//
// The arguments are checked against the statement's parameters here, and a
// struct argument binds named parameters by field. The row's fields are
// matched with the columns by name, their types with the columns' declared
// types, and a column that can be NULL needs a sqlite::Nullable field.
#pragma once

namespace goose {

namespace {
// The names the lowered blocks bind: no program spells them.
constexpr const char *SQL_ROW = "__sqlite_row";
constexpr const char *SQL_HAS = "__sqlite_has";
}

inline Ident *TypeCheck::SqlIdent(Line line, string_view leaf, string_view ns) {
    return ast.New<Ident>(line, ast.Intern(cat("sqlite::", leaf)), ns);
}

// The checked statement an argument names: a global declared with
// sqlite::statement, which a local of its name does not hide. -1 for
// anything else.
inline int TypeCheck::SqlStmtArg(Node *a) {
    auto id = Is<Ident>(a);
    if (!id) return -1;
    if (auto vd = LookupVar(id->name, id->ns); !vd || !vd->isglobal) return -1;
    auto g = ast.LookupGlobal(id->name, id->ns);
    if (!g || g->inits.size() != 1) return -1;
    if (!IsSqliteCall(g->inits[0], "statement") && SqlLoweredId(g->inits[0], "statement_of") < 0)
        return -1;
    return SqlStatementOf(ast, g, a->line, SqlErrs(), SqlStrs());
}

inline const VarDecl *TypeCheck::SqlSchemaArg(Node *a) {
    auto id = Is<Ident>(a);
    if (!id) return nullptr;
    if (auto vd = LookupVar(id->name, id->ns); !vd || !vd->isglobal) return nullptr;
    auto g = ast.LookupGlobal(id->name, id->ns);
    if (!g || g->inits.size() != 1) return nullptr;
    auto init = g->inits[0];
    if (!IsSqliteCall(init, "schema") && !IsSqliteCall(init, "schema_file") &&
        SqlLoweredId(init, "schema_of") < 0)
        return nullptr;
    SqlSchemaOf(ast, g, a->line, SqlErrs(), SqlStrs());
    return g;
}

inline SqlErr TypeCheck::SqlErrs() {
    return [this](Line l, const string &m) { Error(l, m); };
}

inline SqlStr TypeCheck::SqlStrs() {
    return [this](Node *n) { return ConstStrLit(n); };
}

// The global a schema or statement declaration initializes: they are only
// that.
inline VarDecl *TypeCheck::SqlDeclaredBy(Call *c, string_view what) {
    for (auto g : ast.globals)
        if (g->inits.size() == 1 && (g->inits[0] == c || g->inits[0] == c->Origin()))
            return g;
    Error(c, cat("sqlite::", what, " declares a global: `let NAME = sqlite::", what, "(...);`"));
}

// The arguments a statement's parameters get: as many as it has, in order,
// or, for named parameters, one struct whose fields name them.
inline vector<Node *> TypeCheck::SqlParams(Call *c, const SqlStmt &st, string_view qname,
                                           size_t first) {
    vector<Node *> given(c->args.begin() + (long)first, c->args.end());
    auto stmtname = st.global && !st.global->names.empty() ? st.global->names[0] : "the statement";
    TypeExpr *t = nullptr;
    if (st.named && given.size() == 1) {
        auto a = given[0];
        if (auto sl = Is<StructLit>(a); sl && sl->type->kind == TY_STRUCT) {
            t = Subst(sl->type);
        } else if (Is<Ident>(a) || Is<Dot>(a)) {
            auto v = CheckV(a, nullptr);
            auto vt = v.type && v.type->kind == TY_REF ? v.type->ref->sub : v.type;
            if (vt && vt->kind == TY_STRUCT && vt->struc->st->qname != "sqlite::Nullable") t = vt;
        }
    }
    if (!t) {
        if (given.size() != (size_t)st.nparams)
            Error(c, cat(qname, ": ", stmtname, " takes ", (int64_t)st.nparams, " parameter",
                         st.nparams == 1 ? "" : "s", ", given ", (int64_t)given.size()));
        return given;
    }
    // A struct binds the named parameters by field.
    auto si = GetStructInst(t);
    auto sl = Is<StructLit>(given[0]);
    vector<Node *> out;
    set<string_view> used;
    for (auto &pn : st.pnames) {
        int fi = -1;
        for (size_t i = 0; i < si->st->fields.size(); i++)
            if (!si->st->fields[i].ispad && si->st->fields[i].name == pn) fi = (int)i;
        if (fi < 0)
            Error(c, cat(qname, ": ", TypeStr(t), " has no field for the parameter :", pn, " of ",
                         stmtname));
        used.insert(si->st->fields[fi].name);
        auto &field = si->st->fields[fi];
        if (!sl) {
            out.push_back(ast.New<Dot>(given[0]->line, given[0]->Clone(ast), field.name));
            continue;
        }
        Node *val = nullptr;
        for (size_t k = 0; k < sl->inits.size(); k++) {
            auto &init = sl->inits[k];
            if (init.name.empty() ? (int)k == fi : init.name == field.name) val = init.val;
        }
        if (!val && field.defaultval &&
            (Is<IntLit>(field.defaultval) || Is<FltLit>(field.defaultval) ||
             Is<BoolLit>(field.defaultval) || Is<StrLit>(field.defaultval)))
            val = field.defaultval->Clone(ast);
        if (!val)
            Error(sl, cat(qname, ": give the field ", field.name, " a value: it binds the "
                          "parameter :", pn));
        out.push_back(val);
    }
    for (auto &f : si->st->fields)
        if (!f.ispad && !used.count(f.name))
            Error(c, cat(qname, ": ", stmtname, " has no parameter :", f.name, " for the field ",
                         f.name, " of ", TypeStr(t)));
    return out;
}

// What reads column `i` of the lowered block's row into a value of type
// `ft`, after checking the column can be one.
inline Node *TypeCheck::SqlReader(Call *c, TypeExpr *ft, int i, const SqlColumn &col,
                                  string_view what, string_view qname) {
    auto line = c->line;
    auto read = [&](string_view fn, vector<Node *> extra = {}) -> Node * {
        auto rc = ast.New<Call>(line, SqlIdent(line, fn, {}));
        rc->args.push_back(ast.New<Ident>(line, SQL_ROW));
        rc->args.push_back(ast.New<IntLit>(line, i));
        for (auto e : extra) rc->args.push_back(e);
        return rc;
    };
    auto mismatch = [&](const char *wants) {
        string decl;
        for (auto ch : col.decl) decl += (char)toupper((unsigned char)ch);
        Error(c, cat(qname, ": ", what, " is ", TypeStr(ft), ", but column ", col.name, " is ",
                     SqlAffinityName(col.aff),
                     decl.empty() || decl == SqlAffinityName(col.aff) ? "" : cat(" (", col.decl, ")"),
                     ", which reads as ", wants));
    };
    auto any = col.aff == SA_NONE || col.aff == SA_NUMERIC;
    if (ft->kind == TY_STRUCT && ft->struc->st->qname == "sqlite::Nullable") {
        auto si = GetStructInst(ft);
        int vi = -1;
        for (size_t k = 0; k < si->st->fields.size(); k++)
            if (si->st->fields[k].name == "v") vi = (int)k;
        auto sl = ast.New<StructLit>(line, ft);
        sl->implicit = true;
        sl->inits.push_back({ "has", ast.New<Unary>(line, T_NOT, read("is_null")) });
        auto inner = col;
        inner.nullable = false;
        sl->inits.push_back({ "v", SqlReader(c, si->ftypes[vi], i, inner, what, qname) });
        return sl;
    }
    if (col.nullable)
        Error(c, cat(qname, ": column ", col.name, " can be NULL",
                     col.table.empty() ? "" : cat(" (", col.table, ".", col.origin, ")"),
                     "; declare ", what, " as sqlite::Nullable<", TypeStr(ft),
                     ">, or select coalesce(...) as \"", col.name, "!\" if it never is"));
    switch (ft->kind) {
        case TY_INT:
            if (!any && col.aff != SA_INTEGER) mismatch("TEXT, a float or a blob, not an integer");
            switch (ft->intstorage) {
                case IS_I64: case IS_VARINT: return read("int");
                case IS_I8:  return read("read_i8");
                case IS_I16: return read("read_i16");
                case IS_I32: return read("read_i32");
                case IS_U8:  return read("read_u8");
                case IS_U16: return read("read_u16");
                case IS_U32: return read("read_u32");
                case IS_U64: return read("read_u64");
            }
            break;
        case TY_BOOL:
            if (!any && col.aff != SA_INTEGER) mismatch("something other than 0 or 1");
            return read("read_bool");
        case TY_FLT:
            if (!any && col.aff != SA_REAL && col.aff != SA_INTEGER) mismatch("text or a blob");
            return read(ft->fltstorage == FS_F64 ? "real" : "read_f32");
        case TY_ARRAY:
            if (ft->arr->sub->kind == TY_INT && ft->arr->sub->intstorage == IS_U8 &&
                ft->arr->akind != A_FIXED) {
                if (!any && col.aff != SA_TEXT && col.aff != SA_BLOB)
                    mismatch("a number, not text or a blob");
                auto blob = col.aff == SA_BLOB;
                if (ft->arr->akind == A_LIMITED && ft->arr->size >= 0)
                    return read(blob ? "blob_cap" : "text_cap",
                                { ast.New<IntLit>(line, ft->arr->size) });
                return read(blob ? "blob" : "text");
            }
            break;
        default: break;
    }
    // The program's own type, through its read overload.
    auto found = false;
    if (auto ns = ast.FindNS("sqlite"))
        if (auto it = ns->functionmap.find("read"); it != ns->functionmap.end())
            for (auto sf : it->second)
                if (sf->params.size() == 3 && sf->params[2].type &&
                    sf->params[2].type->kind == TY_REF && TypeEq(sf->params[2].type->ref->sub, ft))
                    found = true;
    if (!found)
        Error(c, cat(qname, ": ", what, " is ", TypeStr(ft), ", which a column is not read as; "
                     "declare fn sqlite::read(r: sqlite::Row, i: i64, out: ", TypeStr(ft),
                     "&) -> bool to read it"));
    auto rc = Is<Call>(read("read_value"));
    rc->tyargs.push_back(ft);
    rc->implicit = true;
    return rc;
}

// The value a row becomes: a struct whose fields match the columns by
// name, or, for any other type, the one column.
// What a row struct for the statement looks like, to show with an error
// about one that does not match: empty where its columns make none.
inline string SqlSuggestion(const SqlStmt &st, string_view name) {
    string why;
    auto s = SqlRowStruct(st, name, why);
    return s.empty() ? s : cat("; a struct that matches it: ", s);
}

inline Node *TypeCheck::SqlDecoder(Call *c, TypeExpr *t, const SqlStmt &st, string_view qname) {
    if (st.cols.empty())
        Error(c, cat(qname, ": ", st.global->names[0], " returns no rows"));
    if (t->kind != TY_STRUCT || t->struc->st->qname == "sqlite::Nullable") {
        if (st.cols.size() != 1)
            Error(c, cat(qname, ": ", st.global->names[0], " returns ", (int64_t)st.cols.size(),
                         " columns, which a ", TypeStr(t), " cannot hold: read them into a struct"));
        return SqlReader(c, t, 0, st.cols[0], cat("the result type"), qname);
    }
    auto lower = [](string_view s) {
        string out;
        for (auto ch : s) out += (char)tolower((unsigned char)ch);
        return out;
    };
    auto si = GetStructInst(t);
    vector<bool> used(st.cols.size(), false);
    auto sl = ast.New<StructLit>(c->line, t);
    sl->implicit = true;
    for (size_t k = 0; k < si->st->fields.size(); k++) {
        auto &f = si->st->fields[k];
        if (f.ispad) continue;
        int col = -1;
        for (size_t j = 0; j < st.cols.size(); j++)
            if (lower(st.cols[j].name) == lower(f.name)) {
                if (col >= 0)
                    Error(c, cat(qname, ": two columns are named ", f.name, "; give one an alias"));
                col = (int)j;
            }
        if (col < 0) {
            if (f.defaultval) continue;
            Error(c, cat(qname, ": ", st.global->names[0], " has no column for the field ", f.name,
                         " of ", TypeStr(t), " (fields match columns by name: alias a column ",
                         f.name, ", or give the field a default)",
                         SqlSuggestion(st, si->st->name)));
        }
        used[col] = true;
        sl->inits.push_back({ f.name, SqlReader(c, si->ftypes[k], col, st.cols[col],
                                                cat("field ", f.name), qname) });
    }
    for (size_t j = 0; j < st.cols.size(); j++)
        if (!used[j])
            Error(c, cat(qname, ": ", TypeStr(t), " has no field for column ", st.cols[j].name,
                         " (fields match columns by name: rename the field, alias the column, "
                         "or leave it out of the select)", SqlSuggestion(st, si->st->name)));
    return sl;
}

// A block literal with these parameters and this value.
inline FunVal *TypeCheck::SqlBlock(Line line, vector<const char *> params, Block *body) {
    auto fv = ast.New<FunVal>(line, body);
    for (auto p : params) fv->params.push_back(Param { p });
    fv->explicit_params = true;
    return fv;
}

// Lowers `c` if it is a call of checked SQL, leaving it a call of an
// ordinary library function; false for any other call, which is untouched.
inline bool TypeCheck::LowerSqliteCall(Call *c, Ident *id) {
    auto ref = SplitName(id->name, id->ns);
    if (ref.ns != "sqlite") return false;
    auto leaf = ref.leaf;
    auto qname = cat("sqlite::", leaf);
    auto line = c->line;
    auto retarget = [&](string_view fn, vector<Node *> args) {
        c->callee = SqlIdent(line, fn, id->ns);
        c->args = std::move(args);
        c->tyargs.clear();
    };
    if (leaf == "schema" || leaf == "schema_file") {
        auto g = SqlDeclaredBy(c, leaf);
        auto k = SqlSchemaOf(ast, g, line, SqlErrs(), SqlStrs());
        retarget("schema_of", { ast.New<IntLit>(line, k) });
        c->trailing = nullptr;
        return true;
    }
    if (leaf == "statement") {
        auto g = SqlDeclaredBy(c, leaf);
        auto n = SqlStatementOf(ast, g, line, SqlErrs(), SqlStrs());
        retarget("statement_of", { ast.New<IntLit>(line, n) });
        c->trailing = nullptr;
        return true;
    }
    if (leaf == "row_type")
        Error(c, "sqlite::row_type names a type: `type Row = sqlite::row_type(q);`");
    if (leaf == "open" || leaf == "migrate") {
        if (c->args.size() < 2) return false;
        auto g = SqlSchemaArg(c->args[1]);
        if (!g) return false;
        auto &cat_ = Catalog(ast);
        auto &schema = cat_.schemas[cat_.schemaof[g]];
        auto migs = ast.New<ArrayLit>(line);
        for (auto &m : schema.migrations) migs->elems.push_back(ast.New<StrLit>(line, m));
        auto expst = ast.LookupStruct("sqlite::Expected", "");
        auto exps = ast.New<ArrayLit>(line);
        for (auto n : SqlStatementsOfSchema(ast, g, SqlErrs(), SqlStrs())) {
            auto &st = cat_.stmts[n];
            string decls;
            for (size_t i = 0; i < st.cols.size(); i++) Append(decls, i ? "," : "", st.cols[i].decl);
            auto e = ast.New<StructLit>(line, ast.StructOf(expst, {}, line));
            e->implicit = true;
            e->inits.push_back({ "sql", ast.New<StrLit>(line, st.sql) });
            e->inits.push_back({ "params", ast.New<IntLit>(line, st.nparams) });
            e->inits.push_back({ "decltypes", ast.New<StrLit>(line, decls) });
            exps->elems.push_back(e);
        }
        if (leaf == "migrate") {
            if (c->args.size() != 2) Error(c, "sqlite::migrate(db, SCHEMA) takes the connection and the schema");
            retarget("migrate_schema", { c->args[0], migs, exps });
            return true;
        }
        if (c->args.size() > 3) Error(c, "sqlite::open(path, SCHEMA, def) takes at most three arguments");
        Node *def = c->args.size() == 3 ? c->args[2] : nullptr;
        if (!def) {
            auto d = ast.New<StructLit>(line, ast.StructOf(ast.LookupStruct("sqlite::OpenDef", ""), {}, line));
            d->implicit = true;
            def = d;
        }
        retarget("open_schema", { c->args[0], def, migs, exps });
        return true;
    }
    static const set<string_view> runs = { "exec", "query", "each", "one", "rows", "scalar_int",
                                           "scalar_real", "scalar_text" };
    if (!runs.count(leaf)) return false;
    auto stn = c->args.size() >= 2 ? SqlStmtArg(c->args[1]) : -1;
    if (stn < 0) {
        if (leaf == "rows" || !c->tyargs.empty())
            Error(c, cat(qname, "<T>(db, q, ...) takes a checked statement: a global declared as "
                         "`let q = sqlite::statement(SCHEMA, sql);`"));
        return false;
    }
    auto &st = Catalog(ast).stmts[stn];
    auto stmtname = st.global->names[0];
    auto params = SqlParams(c, st, qname, 2);
    vector<Node *> args = { c->args[0], ast.New<StrLit>(line, st.sql) };
    args.insert(args.end(), params.begin(), params.end());
    auto typed = !c->tyargs.empty();
    if (typed && c->tyargs.size() != 1) Error(c, cat(qname, "<T> takes one type argument"));
    if (typed && leaf != "rows" && leaf != "one" && leaf != "each")
        Error(c, cat(qname, " takes no type argument"));
    if (leaf != "exec" && !typed && st.cols.empty())
        Error(c, cat(qname, ": ", stmtname, " returns no rows; run it with sqlite::exec"));
    if (leaf == "exec" && st.readonly && !st.cols.empty())
        Warn(c, cat("sqlite::exec: ", stmtname, " only reads, and exec drops its rows; use "
                    "sqlite::rows or sqlite::each"));
    if (!typed) {
        if (leaf == "rows") Error(c, "sqlite::rows<T> needs the row type: sqlite::rows<User>(db, q, ...)");
        retarget(leaf, args);
        return true;
    }
    auto t = Subst(c->tyargs[0]);
    if (leaf == "rows") {
        if (c->trailing) Error(c, "sqlite::rows<T> builds the rows itself: it takes no block");
        auto body = ast.New<Block>(line);
        body->tail = SqlDecoder(c, t, st, qname);
        retarget("query", args);
        c->trailing = SqlBlock(line, { SQL_ROW }, body);
        return true;
    }
    if (leaf == "one") {
        if (c->trailing) Error(c, "sqlite::one<T> returns the row: it takes no block");
        auto thenb = ast.New<Block>(line);
        thenb->tail = SqlDecoder(c, t, st, qname);
        auto elseb = ast.New<Block>(line);
        string why;
        if (!HasDefault(t, why))
            Error(c, cat("sqlite::one<", TypeStr(t), ">: there may be no row, and ", TypeStr(t),
                         " has no default to return then: ", why));
        elseb->tail = DefaultValue(t, line);
        auto body = ast.New<Block>(line);
        body->tail = ast.New<IfExpr>(line, ast.New<Ident>(line, SQL_HAS), thenb, elseb);
        retarget("one_of", args);
        c->trailing = SqlBlock(line, { SQL_ROW, SQL_HAS }, body);
        return true;
    }
    // each<T>: the row decoded into the block's own parameter.
    auto fv = c->trailing;
    if (!fv) Error(c, "sqlite::each<T> needs a block for the rows: sqlite::each<User>(db, q) { u => ... }");
    if (fv->params.size() > 1) Error(fv, "sqlite::each<T>'s block takes one parameter, the row");
    auto name = fv->params.empty() ? string_view("it") : fv->params[0].name;
    auto decl = ast.New<VarDecl>(line, false);
    decl->names.push_back(name);
    if (!fv->params.empty() && fv->params[0].type) decl->type = fv->params[0].type;
    decl->inits.push_back(SqlDecoder(c, t, st, qname));
    auto body = ast.New<Block>(fv->body->line);
    body->stmts.push_back(decl);
    for (auto s : fv->body->stmts) body->stmts.push_back(s);
    body->tail = fv->body->tail;
    auto merged = SqlBlock(fv->line, { SQL_ROW }, body);
    merged->col = fv->col;
    retarget("each", args);
    c->trailing = merged;
    return true;
}

}  // namespace goose
