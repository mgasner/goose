// Goose compiler — the typechecker's member templates (members of TypeCheck,
// typecheck.h), which every typechecker translation unit instantiates with
// lambdas of its own and so must see in full.
#pragma once

namespace goose {

// From typecheck_types.h.

// A question about two types answered once where both graphs are complete,
// as AppendArrayElemsReached's is; an unfinished graph takes the walk each
// time. A complete graph stays complete, so a pair once answered needs no
// second look at its graphs.
template<typename F> bool TypeCheck::StableTypeQuery(TypePairCache &cache, TypeExpr *t,
                                                     TypeExpr *of, F walk) {
    pair key { t, of };
    if (auto known = cache.find(key)) {
        // Assertion builds compare each cached answer with the walk.
        assert(*known == walk());
        return *known;
    }
    if (typesbuilding || !stabletypes.Ready(t) || !stabletypes.Ready(of)) return walk();
    auto r = walk();
    cache[key] = r;
    return r;
}

// From typecheck_exprs.h.

// The operands of n, in evaluation order (§2), each with how n consumes it
// once its later operands have run. A call consumes its receiver and
// arguments at the call; print, str and format render each argument just
// before the next runs (EmitFormatInto, EmitStr), so an earlier argument is
// nothing afterwards, and only the one being rendered is held (HeldOperands).
// A condition and a scrutinee are read before the construct's parts run, so
// they hold nothing over them: a match binder is a variable in scope, which
// the scans see. A `for` walks its sequence in place, so that is held while
// the body runs (HoldForSequence).
template<typename F> void TypeCheck::ForOperands(Node *n, F f) {
    if (auto c = Is<Call>(n)) {
        auto builtin = c->builtin >= 0;
        auto member = builtin && (BuiltinByKind(c->builtin).flags & BF_MEMBER);
        auto render = builtin && (c->builtin == B_PRINT || c->builtin == B_STR ||
                                  c->builtin == B_FORMAT);
        auto first = true;
        auto kind = [&]() {
            auto k = member && first ? HK_RECEIVER : render ? HK_NONE : HK_VALUE;
            first = false;
            return k;
        };
        if (auto d = Is<Dot>(c->callee)) f(d->obj, kind());
        for (auto a : c->args) f(a, kind());
        return;
    }
    if (auto ix = Is<Index>(n)) {
        f(ix->obj, HK_ELEMS);
        f(ix->idx, HK_VALUE);
        return;
    }
    if (auto se = Is<SliceExpr>(n)) {
        f(se->obj, HK_ELEMS);
        if (se->lo) f(se->lo, HK_VALUE);
        if (se->hi) f(se->hi, HK_VALUE);
        return;
    }
    if (auto b = Is<Binary>(n)) {
        f(b->left, HK_VIEW);
        f(b->right, HK_VALUE);
        return;
    }
    if (auto a = Is<Assign>(n)) {
        f(a->lval, HK_LOCATION);
        f(a->rhs, HK_VALUE);
        return;
    }
    if (auto al = Is<ArrayLit>(n)) {
        for (auto e : al->elems) f(e, HK_VALUE);
        if (al->fillval) f(al->fillval, HK_VALUE);
        if (al->fillcount) f(al->fillcount, HK_VALUE);
        if (al->capexpr) f(al->capexpr, HK_VALUE);
        return;
    }
    if (auto sl = Is<StructLit>(n)) {
        for (auto &fi : sl->inits) f(fi.val, HK_VALUE);
        return;
    }
    if (auto r = Is<Return>(n)) {
        for (auto v : r->vals) f(v, HK_VALUE);
        return;
    }
    if (auto vd = Is<VarDecl>(n)) {
        for (auto i : vd->inits) f(i, HK_VALUE);
        return;
    }
    if (Is<Unary>(n) || Is<AsCast>(n) || Is<Dot>(n) || Is<IncDec>(n) || Is<Break>(n)) {
        n->Children([&](Node *ch) { f(ch, HK_VALUE); });
        return;
    }
    // A range's bounds, like a count, are read once, before the first
    // iteration: they hold nothing.
    if (auto fl = Is<ForLoop>(n)) {
        if (!Is<RangeExpr>(fl->iter)) f(fl->iter, HK_SEQUENCE);
        return;
    }
    // Conditions, scrutinees, blocks and bodies: nothing held.
}

// What the operand n of `parent`, whose value is v, holds live: its value
// where it is a reference or slice; an array's elements where the parent
// views them (HK_VIEW), or indexes or slices them (HK_ELEMS, the elements the
// path leads to, a temporary's exactly); the references a holder holds,
// each as a reference to its pointee; a builtin's receiver as a reference
// to the array it is, or its elements where the builtin reads them
// (to_bytes, a slice); an assignment's location as recorded (CheckAssign).
template<typename F>
void TypeCheck::HoldAs(Node *n, const Val &v, HoldKind kind, Node *parent, const char *render,
                       F f) {
    if (!v.type || kind == HK_NONE) return;
    auto t = v.type;
    auto hold = [&](Val hv, bool location = false, bool elems = false) {
        f(Held { n, std::move(hv), location, render, elems });
    };
    switch (kind) {
        case HK_LOCATION:
            hold(v, true);
            return;
        case HK_ELEMS: {
            auto d = IsPlainRef(t) ? DecayRef(v) : v;
            TypeExpr *elem = d.type->kind == TY_ARRAY ? d.type->arr->sub
                             : d.type->kind == TY_SLICE ? d.type->sub : nullptr;
            if (!elem) return;
            if (IsTemp(d.Root())) d.Set(d.Root(), true);
            d.type = ast.SliceOf(elem, n->line);
            hold(d, false, true);
            return;
        }
        case HK_RECEIVER: {
            auto c = (Call *)parent;
            auto rt = IsPlainRef(t) ? t->ref->sub : t;
            TypeExpr *elem = rt->kind == TY_ARRAY ? rt->arr->sub
                             : rt->kind == TY_SLICE ? rt->sub : nullptr;
            auto held = v;
            auto elems = c->builtin == B_TO_BYTES || rt->kind == TY_SLICE;
            if (elems) {
                if (!elem) return;
                held.type = ast.SliceOf(elem, n->line);
            } else if (held.type->kind != TY_REF) {
                held.type = ast.RefTo(rt, n->line);
            }
            if (IsTemp(held.Root()) && t->kind != TY_REF && t->kind != TY_SLICE)
                held.Set(held.Root(), true);
            hold(held, false, elems);
            return;
        }
        case HK_SEQUENCE:
            HoldForSequence((ForLoop *)parent, v, f);
            return;
        default: break;
    }
    // HK_VALUE and HK_VIEW: values constructed in argument, literal and
    // result slots own their copies; references, slices and reference fields
    // still retain borrows, and an array operand viewed as a sequence its
    // elements until the operation ends.
    if (IsRefOrSlice(t)) {
        hold(v);
        return;
    }
    if (kind == HK_VIEW && t->kind == TY_ARRAY && ClassOf(t) != SC_FIXED) {
        auto view = v;
        view.type = ast.SliceOf(t->arr->sub, n->line);
        hold(view, false, true);
    }
    if (HoldsPlainRef(t)) {
        vector<TypeExpr *> pointees;
        RefPointees(t, pointees);
        auto held = v;
        held.TakeAlts(ContentsOf(v));
        for (auto pt : pointees) {
            held.type = ast.RefTo(pt, n->line);
            hold(held);
        }
    }
}

// What a `for` over an array or slice, whose sequence has the value v, reads
// on every iteration while its body runs (§6.5). Codegen spells the path to
// the sequence into the loop (ForLoop::CgStmt, GenLoc): each reference or
// slice the path loads out of a field or element is loaded again, from where
// it lies, and the sequence is walked in place, as a view of its elements --
// unless it is a variable, which the loop names and the scans see, or a
// resizable array, whose length the loop reads again and whose elements
// never move. A reference to a slice is held as it is: the slice it refers
// to is read again too (HeldRefsMayPointInto).
template<typename F> void TypeCheck::HoldForSequence(ForLoop *fl, const Val &v, F f) {
    if (fl->iterkind != IK_ARRAY && fl->iterkind != IK_SLICE) return;
    auto hold = [&](Node *n, Val hv, bool reread) {
        // A temporary is storage of its own, which nothing names to shrink.
        for (auto &a : hv.alts)
            if (IsTemp(a.root)) a.exact = true;
        f(Held { .node = n, .v = std::move(hv), .loop = fl, .reread = reread });
    };
    // `&` of a path is that path.
    auto unwrap = [](Node *n) {
        auto u = Is<Unary>(n);
        if (u && u->op == T_BITAND && (Is<Ident>(u->child) || Is<Dot>(u->child) ||
                                       Is<Index>(u->child)) &&
            u->child->exprtype && u->child->exprtype->kind != TY_REF)
            return u->child;
        return n;
    };
    auto path = unwrap(fl->iter);
    if (!Is<Ident>(path)) {
        auto seq = v;
        if (IsPlainRef(seq.type) && seq.type->ref->sub->kind != TY_SLICE) seq = DecayRef(seq);
        auto st = seq.type;
        if (st->kind != TY_ARRAY) {
            hold(fl->iter, seq, false);
        } else if (ClassOf(st) != SC_RESIZABLE) {
            seq.type = ast.SliceOf(st->arr->sub, fl->iter->line);
            hold(fl->iter, seq, false);
        }
    }
    for (auto n = path;;) {
        Node *obj;
        if (auto d = Is<Dot>(n); d && !d->variantconst) obj = d->obj;
        else if (auto ix = Is<Index>(n)) obj = ix->obj;
        else break;
        // The slot lies in what obj is, or leads to.
        auto ov = nodevals.find(obj);
        if (n->exprtype && IsRefOrSlice(n->exprtype) && ov) {
            auto slot = DecayRef(*ov);
            slot.byteview = false;
            slot.type = ast.SliceOf(LoadType(n->exprtype), n->line);
            hold(n, slot, true);
        }
        n = unwrap(obj);
    }
}

// Every value evaluated before the point being checked that is still live:
// the operands each node on the path has evaluated so far (its parent
// consumes them after this point), as their parents hold them. A call at
// the point itself, applying its callee's effects, has consumed its own
// operands: what the callee does to them its parameters' pairs judge
// (§5.1, NoteLiveViews). The exception is the argument print, str or format
// is rendering (`cur.renderarg`): its views, where a struct, enum or array
// argument lies (`cur.renderwhere`), and the parts the rendering is walking
// in place (`cur.renderwalks`), which an overload of a part runs in the
// middle of rendering.
template<typename F> void TypeCheck::HeldOperands(F f) {
    for (auto &e : cur.nodepath) {
        auto own = e.discovering || (&e == &cur.nodepath.back() && Is<Call>(e.node));
        auto i = 0;
        ForOperands(e.node, [&](Node *ch, HoldKind kind) {
            auto at = i++;
            if (at >= e.pos) return;
            auto cv = nodevals.find(ch);
            if (!cv) return;
            if (ch == cur.renderarg && cur.rendering) {
                HoldAs(ch, *cv, HK_VIEW, e.node, cur.rendering, f);
                if (ch == cur.renderwhere) {
                    auto where = *cv;
                    where.type = ast.RefTo(where.type, ch->line);
                    f(Held { ch, std::move(where), false, cur.rendering });
                }
                for (auto &w : cur.renderwalks) {
                    auto walked = w;
                    walked.type = ast.RefTo(w.type, ch->line);
                    f(Held { .node = ch, .v = std::move(walked), .render = cur.rendering,
                             .inplace = true });
                }
                return;
            }
            if (own) return;
            HoldAs(ch, *cv, kind, e.node, nullptr, f);
        });
    }
}

// Every part of the statement that runs after the point being checked: the
// operands each node on the path has not evaluated yet, the one being
// checked excluded, and where the point is in the head of a construct, the
// parts the head decides between. Each comes with the frame it is checked in.
template<typename F> void TypeCheck::LaterOperands(F f) {
    for (size_t k = 0; k < cur.nodepath.size(); k++) {
        auto &e = cur.nodepath[k];
        auto last = k + 1 == cur.nodepath.size();
        auto i = 0;
        ForOperands(e.node, [&](Node *ch, HoldKind) {
            auto at = i++;
            if (at > e.pos || (last && at == e.pos)) f(ch, e.frame);
        });
        if (!last) AfterHead(e.node, cur.nodepath[k + 1].node, [&](Node *p) { f(p, e.frame); });
    }
}

// What construct n runs after its head -- an if's condition, a match's
// scrutinee, a for's sequence, a while's condition -- where `next` is the
// node being checked inside it: while that is the head, every part the head
// leads to; while it is one of those parts, nothing more of n, since the
// other branches do not run.
template<typename F> void TypeCheck::AfterHead(Node *n, Node *next, F f) {
    if (auto fi = Is<IfExpr>(n)) {
        if (next != fi->cond) return;
        f(fi->thenb);
        if (fi->elseb) f(fi->elseb);
    } else if (auto m = Is<MatchExpr>(n)) {
        if (next != m->scrutinee) return;
        for (auto &arm : m->arms) f(arm.body);
    } else if (auto fl = Is<ForLoop>(n)) {
        auto r = Is<RangeExpr>(fl->iter);
        if (r && next == r->lo) f(r->hi);
        if (next == fl->iter || (r && (next == r->lo || next == r->hi))) f(fl->body);
    } else if (auto w = Is<While>(n)) {
        if (next == w->cond) f(w->body);
    }
}

// From typecheck_flow.h.

// A control construct's value (§6.4), which `check` checks at a
// destination type. With none, a first check takes its branches as they
// are, the construct on joinpath; where they join as a slice there
// (JoinBranches) -- a string literal in one, an array in another -- a
// second checks them as values of that slice type, each array a
// whole-array slice of itself rather than the copy the construct's value
// otherwise is (TempCopy). The first check's warnings, and the copies of
// non-fixed storage it would report (CheckBranchCopy), wait until it is
// known to stand, and the second replaces what it logged for the
// construction checks (growlog). A construct already on the path is a
// branch of the one whose first check it is part of, which settles its
// value.
template<typename F> Val TypeCheck::CheckJoin(Node *x, TypeExpr *expected, F check) {
    if ((expected && expected->kind != TY_VOID) || joinpath == x) return check(expected);
    auto entry = SaveFlow();
    auto warnbase = cur.pendingwarnings.size();
    auto growbase = cur.growlog.size();
    Val v;
    {
        struct Probe {
            TypeCheck &tc;
            JoinPathScope js;
            Probe(TypeCheck &t, Node *n) : tc(t), js(t, n) { tc.cur.joinprobes++; }
            ~Probe() { tc.cur.joinprobes--; }
        } probe(*this, x);
        v = check(expected);
    }
    // Arrays of different types alone: an argument's are its call's to
    // judge against the parameter (argpath).
    if (v.joinslice && !v.joinhasslice) {
        if (argpath != x) NoArrayJoin(v);
        if (!WarningsHeld()) FlushWarnings();
        return v;
    }
    if (v.joinslice) {
        RestoreFlow(entry);
        cur.pendingwarnings.resize(warnbase);
        // The second check logs the growths and shrinks in the branches
        // again, for the values under construction around the construct.
        cur.growlog.resize(growbase);
        // The construct is no typed slot and constructs into no storage of
        // its own: what receives its value judges it as a slice's.
        DestScope ds(*this, Dest {});
        SlotScope ss(*this, false);
        return check(v.type);
    }
    if (!WarningsHeld()) FlushWarnings();
    // An argument's is left to its check against its parameter (argpath).
    if (v.implicitcopy && argpath != x) ImplicitCopyError(v.implicitcopy);
    // Numeric branches join as one type (MergeVals), which each branch's
    // value, checked with none, now takes.
    if (v.type && (IsIntT(v.type) || v.type->kind == TY_FLT)) RetypeBranches(x, v.type);
    return TempCopy(v);
}

// From typecheck_calls.h.

// Runs f, which checks the default of parameter `param` of the function
// mi resolved c to, in the default's own frame (DefaultScope).
template<typename F>
void TypeCheck::InParamDefault(Call *c, const MatchInfo &mi, FnSpec *env, size_t param, F f) {
    EachDefaultInPlace([&](Frame &fr) {
        if (fr.defaultfn == mi.sf && fr.defaultparam == (int)param)
            Error(c, cat("the default of parameter ", mi.sf->params[param].name, " of ",
                         mi.sf->qname, " leads to this call, which takes it again (§7.1)"));
    });
    DefaultScope ds(*this, env, c->line);
    auto &fr = frames.back();
    fr.defaultfn = mi.sf;
    fr.defaultparam = (int)param;
    if (auto it = declsiteof.find({ mi.env, mi.sf }); mi.sf->isnested && it != declsiteof.end())
        fr.defaultsite = it->second;
    f();
}

// From typecheck_builtins.h.

template <typename P, typename X>
void TypeCheck::NoteRootEvent(VarDef *root, P param, X external) {
    auto current = CurRealFrame().spec;
    if (!current) return;
    if (root->type) {
        if (root->isglobal || root->ownerspec != current) external(current, root);
        return;
    }
    for (auto fi = (int)frames.size() - 1; fi >= 0; fi--) {
        auto spec = frames[fi].spec;
        if (!spec) continue;
        auto found = false;
        // A view's class is reached through its parameter's slot, which its
        // callers' storage behind the slot bounds (FnSpec::views).
        for (size_t i = 0; i < spec->params.size(); i++) {
            if (RefRootOf(spec->params[i]) != root && ViewClassOf(spec, i) != root) continue;
            param(spec, (int)i);
            found = true;
        }
        if (found) {
            if (spec != current) external(current, root);
            return;
        }
    }
}

// What the stores into holder from event `from` on put there, following
// copies of other containers' contents to those containers' own stores.
// A copy of a global's contents counts as a reference bounded by the
// global: stores into a global may come from functions not checked yet.
// What came out of the storage of a parameter's class alone (StoreEvent::
// classread) holds what the activation stored there, followed as a copy's
// source is, and what the callers did, which f takes the event for.
template<typename F> void TypeCheck::EachHolderRoot(VarDef *holder, size_t from, F f) {
    set<VarDef *> seen;
    function<void(VarDef *, size_t)> walk = [&](VarDef *h, size_t start) {
        if (!seen.insert(h).second) return;
        for (auto i = start; i < storeevents.size(); i++) {
            auto e = storeevents[i];
            if (e.container != h) continue;
            if (e.src && !e.src->isglobal && e.src->type) {
                walk(e.src, 0);
                continue;
            }
            if (e.classread) {
                walk(e.src, 0);
                f(e);
                continue;
            }
            // A copy out of a global or a parameter's class is bounded by
            // it: a global's stores may come from functions not checked yet,
            // a class's are the caller's.
            if (e.src) {
                e.root = e.src;
                e.exact = false;
                if (e.src->isglobal) e.pointee = nullptr;
            }
            if (e.root) f(e);
        }
    };
    walk(holder, from);
}

// The code under n that CheckBuiltUses judges: `named` gets each Ident
// naming a variable, with the path of fields it is read through, which
// may lead away from what the variable holds; `called` gets each call
// with each specialization it may run. A rebind's target is not named:
// moving a reference reaches nothing it points at.
template<typename F, typename G> void TypeCheck::EachUse(Node *n, F named, G called) {
    function<void(Node *)> walk = [&](Node *n) {
        if (!n) return;
        if (auto a = Is<Assign>(n); a && a->op == T_DOTASSIGN && Is<Ident>(a->lval)) {
            walk(a->rhs);
            return;
        }
        auto base = n;
        for (auto d = Is<Dot>(base); d && d->fieldidx >= 0; d = Is<Dot>(base)) base = d->obj;
        if (auto id = Is<Ident>(base); id && id->vdef) {
            named(id, n);
            if (base != n) return;
        }
        if (auto c = Is<Call>(n)) {
            if (c->spec) called(c, c->spec);
            for (auto sp : c->dispatch) called(c, sp);
            for (auto &fs : c->fmtspecs) called(c, fs.second);
        }
        RunChildren(n, walk);
    };
    walk(n);
}

}  // namespace goose
