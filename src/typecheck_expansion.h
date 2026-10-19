// Specialization-time structural expansion. The generated trees use the
// ordinary checker, optimizer and code generator; no runtime iterator exists.
#pragma once

namespace goose {

inline Node *TypeCheck::ExpansionConstant(Node *n, set<VarDecl *> &visiting) {
    // Checking a named global may have inserted its ordinary integer-to-
    // float conversion. This is not permission for a source-level cast.
    if (auto a = Is<AsCast>(n); a && a->implicit) {
        auto c = ExpansionConstant(a->child, visiting);
        if (auto i = Is<IntLit>(c)) {
            auto f = ast.New<FltLit>(n->line, i->uns ? (double)(uint64_t)i->val : (double)i->val);
            f->fixedtype = a->type;
            if (a->type->fltstorage == FS_F32) f->val = (float)f->val;
            return f;
        }
        Error(n, "unsupported conversion in const for constant source");
    }
    Val v;
    bool literal;
    set<VarDecl *> integers;
    ConstUse use { n, "const for source" };
    if (ConstIntValue(n, v, literal, integers, &use)) {
        auto i = ast.New<IntLit>(n->line, v.ival, string_view {}, v.uns);
        // An unannotated named literal keeps its ordinary adaptability.
        // Arithmetic still follows ConstIntValue's evaluation widths.
        if (auto id = Is<Ident>(n)) {
            auto g = ast.LookupGlobal(id->name, id->ns);
            if (g && !g->type && g->defs[0]->constlit) literal = true;
        }
        if (!literal) i->fixedtype = v.type;
        return i;
    }
    if (Is<StrLit>(n) || Is<BoolLit>(n) || Is<FltLit>(n)) return n->Clone(ast);
    if (auto u = Is<Unary>(n); u && u->op == T_MINUS) {
        if (auto f = Is<FltLit>(u->child)) return ast.New<FltLit>(n->line, -f->val);
    }
    if (auto id = Is<Ident>(n)) {
        auto g = ast.LookupGlobal(id->name, id->ns);
        if (g && !g->isvar && g->inits.size() == 1) {
            if (!visiting.insert(g).second) Error(n, "cycle in const for constant initializer");
            use.named = g->defs[0];
            RelyOnConstant(use, g->defs[0]);
            auto c = ExpansionConstant(g->inits[0], visiting);
            visiting.erase(g);
            auto t = g->defs[0]->type ? g->defs[0]->type : g->type;
            if (t && t->kind == TY_FLT) {
                if (auto i = Is<IntLit>(c))
                    c = ast.New<FltLit>(n->line, i->uns ? (double)(uint64_t)i->val : (double)i->val);
                auto f = Is<FltLit>(c);
                if (!f) Error(n, "const for named floating constant requires a numeric constant initializer");
                if (g->type || !g->defs[0]->constlit) f->fixedtype = ast.PlainOf(t);
                if (t->fltstorage == FS_F32) f->val = (float)f->val;
                return c;
            }
            if (Is<FltLit>(c) && !t) return c;
            if (Is<BoolLit>(c) && (!t || t->kind == TY_BOOL)) return c;
            if (Is<StrLit>(c) && (!t || (t->kind == TY_SLICE && IsU8(t->sub)))) return c;
        }
    }
    Error(n, "const for source requires a scalar or string constant, or supported integer constant expression");
}

inline void TypeCheck::ExpandConstFor(ConstFor *cf, const function<void(ExpansionClone &)> &emit) {
    // Resolve the complete source before creating any fragment instances.
    vector<vector<ExpansionArg>> entries;
    vector<string> descriptions;
    if (cf->source == ES_CONSTANTS) {
        for (size_t i = 0; i < cf->constants.size(); i++) {
            auto n = cf->constants[i];
            ConstNames(n, "const for source");
            set<VarDecl *> visiting;
            auto value = ExpansionConstant(n, visiting);
            entries.push_back({ { cf->bindings[0], value } });
            descriptions.push_back(cat("constant entry ", i + 1, " (", ExprStr(n), ")"));
        }
    } else {
        vector<TypeExpr *> types;
        for (auto raw : cf->types) {
            ConstNamesIn(raw);
            auto t = Subst(raw);
            if (HasGenerics(t)) Error(cf, cat("const for source requires a concrete type, got ", TypeStr(t)));
            if (cf->source == ES_FIELDS && t->kind != TY_STRUCT)
                Error(cf, cat("fields requires a concrete struct type, got ", TypeStr(t)));
            if (t->kind != TY_FN) ValidateType(t, cf->line, VT_POINTEE);
            types.push_back(t);
        }
        if (cf->source == ES_FIELDS) {
            auto t = ast.PlainOf(types[0]);
            auto inst = GetStructInst(t);
            for (auto &f : inst->st->fields) {
                if (f.ispad) continue;
                entries.push_back({ { cf->bindings[0], ast.New<StrLit>(cf->line, string(f.name)) },
                                    { cf->bindings[1], nullptr, nullptr, t, f.name } });
                descriptions.push_back(cat("field ", TypeStr(t), ".", f.name));
            }
        } else {
            for (auto t : types) {
                entries.push_back({ { cf->bindings[0], nullptr, t } });
                descriptions.push_back(cat("type ", TypeStr(t)));
            }
        }
    }
    for (size_t i = 0; i < entries.size(); i++) {
        ExpansionClone ctx;
        ctx.args = std::move(entries[i]);
        ctx.trace = ast.Intern(cat("\n  in const for ", descriptions[i], " at ", Where(cf->line),
                                  cf->expansiontrace));
        ctx.size = &expansionsize;
        ctx.error = [&](Line line, const string &msg) {
            ErrorIn(LocOf(line), msg, Chain(ctx.trace));
        };
        auto saved = ast.expansionclone;
        ast.expansionclone = &ctx;
        // Cloning is the only operation using this context. Recursive
        // expansion and ordinary checking take place after it is restored.
        try { emit(ctx); } catch (...) { ast.expansionclone = saved; throw; }
        ast.expansionclone = saved;
    }
}

inline Block *TypeCheck::ExpandStatements(ConstFor *cf) {
    auto out = ast.New<Block>(cf->line);
    out->origin = cf->Origin();
    out->expansiontrace = cf->expansiontrace;
    ExpandConstFor(cf, [&](ExpansionClone &) {
        auto body = (Block *)cf->body->Clone(ast);
        body->expansionboundary = true;
        out->stmts.push_back(body);
    });
    return out;
}

inline void TypeCheck::ExpandInitializers(vector<FieldInit> &inits) {
    if (none_of(inits.begin(), inits.end(), [](const FieldInit &fi) { return Is<ConstFor>(fi.val); }))
        return;
    vector<FieldInit> flat;
    for (auto &fi : inits) {
        if (auto cf = Is<ConstFor>(fi.val)) {
            vector<FieldInit> generated;
            ExpandConstFor(cf, [&](ExpansionClone &) {
                for (auto &entry : cf->inits) generated.push_back(ast.CloneFieldInit(entry));
            });
            ExpandInitializers(generated);
            flat.insert(flat.end(), generated.begin(), generated.end());
        } else {
            flat.push_back(fi);
        }
    }
    inits = std::move(flat);
}

} // namespace goose
