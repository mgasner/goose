// Goose compiler — the entry points of the phases built as translation units
// of their own. optimize.cpp holds the optimizer and BCE behind these;
// typecheck.cpp, typecheck_calls.cpp, codegen.cpp and codegen_nodes.cpp hold
// members of TypeCheck and CodeGen, declared in typecheck.h and codegen.h.
#pragma once

namespace goose {

int OptimizeAndCheckBounds(Ast &ast, int optlevel, bool specs, bool nobce, bool bcelines,
                           bool bcetest, bool stats, FILE *msgs);

// What the language server runs after a clean check: the optimizer at
// optlevel and BCE, throwing BCE's error where a checkfree function keeps a
// check, so that its verdicts are a build's.
void OptimizeAndVerifyCheckfree(Ast &ast, int optlevel);

}  // namespace goose
