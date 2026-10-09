// Goose compiler — deferred calls (docs/design/deferred_calls.md): the
// membership pass, run once every name is resolved and before checking.
//
// A deferred type `deferred D(params) -> rets;` is an enum. Every
// construction `D(f, a1, ..., an)` anywhere in the program makes f a member
// of D: a variant of D whose fields are f's first n parameters (the stored
// ones), and whose remaining parameters must be D's. For each member the
// pass writes three functions, which the checker, optimizer and backends
// then treat as any others:
//
//   fn deferred__D__f(stored params) -> D.. { D.f { stored params } }
//   fn deferred__D__call(p: D.f, params) -> rets { f(p.a1, ..., params) }
//   fn deferred__D__callref(p: D.f&, params) -> rets { the same }
//
// and rewrites the construction into a call of the first. The empty call,
// variant 0, gets the two case functions only, which abort. An invocation
// `d(args)` is the checker's to recognize, since only it knows the callee's
// type (TypeCheck::CheckInvocation): it calls one of the two case function
// sets with d first, which dispatches on its tag (§8.2). The by-reference
// set serves a variable-mode value held in storage, so a member's stored
// payload is bound where it lies as a match binder would bind it (§8.1).
//
// Membership is decided from the source alone, so it is an over-approximation:
// a construction in a function nothing calls still makes its function a
// member. That costs a tag value and, in fixed mode, possibly payload size.
#pragma once

namespace goose {

struct DeferredPass {
    Ast &ast;
    explicit DeferredPass(Ast &_ast) : ast(_ast) {}

    [[noreturn]] void ErrorAt(Line line, const string &msg) {
        throw CompileError { cat(ast.sources[line.fileidx].first, ":", line.line,
                                 ": error: ", msg) };
    }

    static string TypeText(const TypeExpr *t) {
        string s;
        t->Dump(s);
        return s;
    }

    // Whether a member's parameter or result has exactly the deferred type's
    // type. Resolution has replaced aliases and spelled declarations by
    // their qualified names, so the text of two equal types is equal.
    static bool SameType(const TypeExpr *a, const TypeExpr *b) {
        return TypeText(a) == TypeText(b);
    }

    // Why sf cannot be a member of en with nstored stored arguments; empty
    // when it can.
    string Unfit(SFunction *sf, SEnum *en, size_t nstored) {
        if (sf->isthread) return "a thread_fn cannot be stored";
        if (sf->isnested) return "a nested function cannot be stored";
        if (sf->deferredof) return "a deferred type's own functions cannot be stored";
        if (!sf->generics.empty()) return "a generic function cannot be stored";
        for (auto &p : sf->params)
            if (!p.type)
                return cat("parameter ", p.name, " has no type, which makes the function generic");
        auto k = en->dparams.size();
        if (sf->params.size() != nstored + k)
            return cat("it takes ", sf->params.size(), " parameter(s), not the ", nstored,
                       " stored argument(s) given plus the ", k, " ", en->qname,
                       " is called with");
        for (size_t i = 0; i < k; i++) {
            auto &mp = sf->params[nstored + i];
            auto &dp = en->dparams[i];
            if (!SameType(mp.type, dp.type) || mp.isvar != dp.isvar)
                return cat("its parameter ", mp.name, " is ", mp.isvar ? "var " : "",
                           TypeText(mp.type), " where ", en->qname, " passes ",
                           dp.isvar ? "var " : "", TypeText(dp.type));
        }
        if (en->drets.empty()) {
            if (sf->has_rets && !sf->rets.empty())
                return cat("it returns a value, and ", en->qname, " returns none");
        } else {
            if (!sf->has_rets || sf->rets.size() != en->drets.size())
                return cat("it must declare ", en->drets.size(), " result(s), as ",
                           en->qname, " does");
            for (size_t i = 0; i < en->drets.size(); i++)
                if (!SameType(sf->rets[i], en->drets[i]))
                    return cat("its result ", TypeText(sf->rets[i]), " is not ",
                               en->qname, "'s ", TypeText(en->drets[i]));
        }
        return "";
    }

    struct Member {
        SEnum *en;
        SFunction *sf;
        size_t nstored;
        Line line;              // The first construction storing it.
        int variant = -1;       // Index into en->variants.
    };
    vector<Member> members;
    vector<SEnum *> deferreds;

    int MemberIndex(SEnum *en, SFunction *sf) {
        for (size_t i = 0; i < members.size(); i++)
            if (members[i].en == en && members[i].sf == sf) return (int)i;
        return -1;
    }

    // Names nothing written can spell the same way by accident: a
    // generated function lives in its deferred type's namespace.
    string_view GenName(SEnum *en, string_view what) {
        return ast.Intern(cat("deferred__", en->name, "__", what));
    }
    // The spelling an Ident uses to reach a generated function from anywhere.
    string_view Reach(SEnum *en, string_view leaf) {
        return ast.Intern(cat(en->ns, "::", leaf));
    }

    SFunction *NewFn(SEnum *en, string_view leaf, Line line) {
        auto sf = new SFunction();
        ast.functions.push_back(sf);
        sf->name = leaf;
        sf->ns = en->ns;
        sf->qname = ast.QualifiedName(en->ns, leaf);
        sf->line = line;
        sf->deferredof = en;
        ast.NS(en->ns).functionmap[leaf].push_back(sf);
        return sf;
    }

    TypeExpr *VariantType(SEnum *en, int vi, Line line) {
        auto &v = en->variants[vi];
        return ast.VariantOf(ast.EnumOf(en, {}, false, line), v.name, &v, line);
    }

    // A case function: p is variant vi of en, by reference or by value, and
    // the rest are en's parameters; the body calls the member, or for the
    // empty call aborts.
    void MakeCase(SEnum *en, int vi, bool byref) {
        auto &v = en->variants[vi];
        auto line = en->line;
        auto sf = NewFn(en, GenName(en, byref ? "callref" : "call"), line);
        sf->dmember = v.member;
        sf->isrec = v.member && v.member->isrec;
        // The payload parameter's name must not hide one of en's.
        string pname = "deferred__p";
        for (auto again = true; again;) {
            again = false;
            for (auto &dp : en->dparams)
                if (dp.name == pname) { pname += "_"; again = true; }
        }
        Param pp;
        pp.name = ast.Intern(pname);
        auto vt = VariantType(en, vi, line);
        pp.type = byref ? ast.RefTo(vt, line) : vt;
        sf->params.push_back(pp);
        for (auto &dp : en->dparams) {
            Param p;
            p.name = dp.name;
            p.type = dp.type;
            p.isvar = dp.isvar;
            sf->params.push_back(p);
        }
        sf->rets = en->drets;
        sf->has_rets = en->dhas_rets;
        auto body = ast.New<Block>(line);
        sf->body = body;
        Node *call;
        if (!v.member) {
            call = ast.New<Call>(line, ast.New<Ident>(line, ast.Intern("::abort"), en->ns));
            Is<Call>(call)->args.push_back(
                ast.New<StrLit>(line, cat("invoked an empty ", en->qname)));
        } else {
            auto c = ast.New<Call>(line, ast.New<Ident>(line, v.member->qname, en->ns));
            c->pinned = v.member;
            // A stored value is passed as the member's by-value parameter
            // takes it: a scalar loads, anything else is copy(p.f), since a
            // variable-size value is never copied implicitly (§4.1).
            for (auto &f : v.fields) {
                Node *a = ast.New<Dot>(line, ast.New<Ident>(line, pp.name, en->ns), f.name, en->ns);
                auto k = f.type->kind;
                if (k != TY_INT && k != TY_FLT && k != TY_BOOL) {
                    auto cp = ast.New<Call>(line, ast.New<Ident>(line, ast.Intern("::copy"), en->ns));
                    cp->args.push_back(a);
                    a = cp;
                }
                c->args.push_back(a);
            }
            for (auto &dp : en->dparams) c->args.push_back(ast.New<Ident>(line, dp.name, en->ns));
            call = c;
        }
        if (!v.member || en->drets.empty()) {
            body->tail = call;
        } else {
            auto r = ast.New<Return>(line);
            r->vals.push_back(call);
            body->stmts.push_back(r);
        }
    }

    // A member's constructor: its stored parameters in, the value out, in
    // variable mode until the checker knows whether fixed mode is open to
    // the type (TypeCheck's setup).
    SFunction *MakeConstructor(Member &m) {
        auto en = m.en;
        auto &v = en->variants[m.variant];
        auto line = m.line;
        auto sf = NewFn(en, GenName(en, cat("new__", v.name)), line);
        sf->dmember = m.sf;
        sf->isdctor = true;
        for (size_t i = 0; i < m.nstored; i++) {
            Param p;
            p.name = m.sf->params[i].name;
            p.type = m.sf->params[i].type;
            sf->params.push_back(p);
        }
        sf->rets.push_back(ast.EnumOf(en, {}, true, line));
        sf->has_rets = true;
        auto lit = ast.New<StructLit>(line, VariantType(en, m.variant, line));
        for (auto &f : v.fields) {
            FieldInit fi;
            fi.name = f.name;
            fi.val = ast.New<Ident>(line, f.name, en->ns);
            lit->inits.push_back(fi);
        }
        auto body = ast.New<Block>(line);
        body->tail = lit;
        sf->body = body;
        return sf;
    }

    void Run() {
        for (auto en : ast.enums)
            if (en->isdeferred) deferreds.push_back(en);
        if (deferreds.empty()) return;
        // Nothing written names a deferred type's variant: resolution has
        // rejected those (ResolveTypeNames), so the variant types are all ours.
        // Every construction, in parse order, which makes the variant order
        // (and so the tags) deterministic.
        vector<pair<Call *, int>> constructions;
        auto nnodes = ast.allnodes.size();
        for (size_t ni = 0; ni < nnodes; ni++) {
            auto c = Is<Call>(ast.allnodes[ni]);
            if (!c) continue;
            auto id = Is<Ident>(c->callee);
            if (!id) continue;
            auto en = ast.LookupEnum(id->name, id->ns);
            // An alias of a deferred type constructs it too; resolution has
            // substituted the alias's own type already.
            if (!en)
                if (auto al = ast.LookupAlias(id->name, id->ns);
                    al && al->type->kind == TY_ENUM && al->type->enu->args.empty())
                    en = al->type->enu->en;
            if (!en || !en->isdeferred) continue;
            if (!c->tyargs.empty()) ErrorAt(c->line, cat(en->qname, " is not generic"));
            if (c->trailing)
                ErrorAt(c->line, cat("a deferred call stores a named function, not a block: ",
                                     en->qname, "(function, arguments...)"));
            Ident *fid = c->args.empty() ? nullptr : Is<Ident>(c->args[0]);
            if (!fid)
                ErrorAt(c->line, cat("a construction of the deferred type ", en->qname,
                                     " names the function to store first: ", en->name,
                                     "(function, arguments...)"));
            auto &cands = ast.LookupFunctions(fid->name, fid->ns);
            if (cands.empty())
                ErrorAt(c->line, cat(fid->name, " is not a top-level function, which is all ",
                                     en->qname, " can store"));
            auto nstored = c->args.size() - 1;
            SFunction *found = nullptr;
            string why;
            auto nfit = 0;
            for (auto sf : cands) {
                auto w = Unfit(sf, en, nstored);
                if (w.empty()) {
                    found = sf;
                    nfit++;
                } else if (why.empty()) {
                    why = w;
                }
            }
            if (!nfit) {
                if (cands.size() == 1)
                    ErrorAt(c->line, cat(fid->name, " cannot be stored as ", en->qname, ": ", why));
                ErrorAt(c->line, cat("no function ", fid->name, " can be stored as ", en->qname,
                                     " with ", nstored, " stored argument(s); one reason: ",
                                     why));
            }
            if (nfit > 1)
                ErrorAt(c->line, cat("more than one function ", fid->name, " can be stored as ",
                                     en->qname, " with ", nstored, " stored argument(s)"));
            auto mi = MemberIndex(en, found);
            if (mi < 0) {
                members.push_back(Member { en, found, nstored, c->line });
                mi = (int)members.size() - 1;
            }
            constructions.push_back({ c, mi });
        }
        // The variants, every one before any pointer to one is taken.
        for (auto &m : members) {
            auto en = m.en;
            SVariant v;
            string name(m.sf->name);
            for (auto n = 2; en->FindVariant(name); n++) name = cat(m.sf->name, "_", n);
            v.name = ast.Intern(name);
            v.has_payload = true;
            v.member = m.sf;
            for (size_t i = 0; i < m.nstored; i++) {
                Field f;
                f.name = m.sf->params[i].name;
                f.type = m.sf->params[i].type;
                v.fields.push_back(f);
            }
            en->variants.push_back(v);
            m.variant = (int)en->variants.size() - 1;
        }
        for (auto en : deferreds) {
            en->dcall = Reach(en, GenName(en, "call"));
            en->dcallref = Reach(en, GenName(en, "callref"));
            for (size_t vi = 0; vi < en->variants.size(); vi++) {
                MakeCase(en, (int)vi, false);
                MakeCase(en, (int)vi, true);
            }
        }
        vector<SFunction *> ctors;
        for (auto &m : members) ctors.push_back(MakeConstructor(m));
        for (auto [c, mi] : constructions) {
            auto ctor = ctors[mi];
            c->callee = ast.New<Ident>(c->callee->line, Reach(members[mi].en, ctor->name),
                                       members[mi].en->ns);
            c->pinned = ctor;
            c->args.erase(c->args.begin());
        }
    }
};

inline void CollectDeferredMembers(Ast &ast) { DeferredPass(ast).Run(); }

}  // namespace goose
