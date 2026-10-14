// Goose compiler — the middle end's translation unit: the optimizer and
// bounds-check elimination.
#include "includes.h"
#include "utils.h"
#include "small_vector.h"
#include "flat_map.h"
#include "lexer.h"
#include "ast.h"
#include "dump.h"
#include "clone.h"
#include "builtins.h"
#include "gfx.h"
#include "typecheck.h"
#include "codegen.h"
#include "phases.h"
#include "optimize.h"
#include "optimize_basecase.h"
#include "optimize_tre.h"
#include "optimize_loops.h"
#include "bce.h"

namespace goose {

// The middle end: optimization, then bounds-check elimination. Returns the
// exit code to stop with, or -1 to go on to code generation.
int OptimizeAndCheckBounds(Ast &ast, int optlevel, bool specs, bool nobce, bool bcelines,
                           bool bcetest, FILE *msgs) {
    Optimizer opt(ast, optlevel);
    if (specs) {
        string s;
        opt.DumpSpecs(s);
        fputs(s.c_str(), stdout);
    }
    fprintf(msgs, "typechecked ok: %d specialization(s), %d struct/%d enum instance(s); "
            "optimized -O%d: %d inlined, %d base case(s), %d folded, %d propagated, "
            "%d tail loop(s)\n",
            (int)ast.fnspecs.size(), (int)ast.structinsts.size(),
            (int)ast.enuminsts.size(), optlevel, opt.inlined, opt.basecases,
            opt.folded, opt.propagated, opt.tailloops);
    BCE bce(ast);
    if (!nobce) {
        bce.RunAll();
        fprintf(msgs, "bce: elided %d/%d index and %d/%d slice checks\n",
                bce.idxelided, bce.idxtotal, bce.slelided, bce.sltotal);
    }
    // Per-line outcomes, for comparing two builds of the pass.
    if (bcelines)
        for (auto &[where, counts] : bce.lineout)
            fprintf(msgs, "bce-line: %s:%d: %d elided, %d kept\n",
                    ast.sources[where.first].first.c_str(), where.second,
                    counts.first, counts.second);
    if (bcetest) {
        auto fails = bce.VerifyAnnotations();
        if (fails) {
            fprintf(stderr, "bce-test: %d annotation failure(s)\n", fails);
            return 1;
        }
        fprintf(msgs, "bce-test: all annotations verified\n");
    }
    return -1;
}

}  // namespace goose
