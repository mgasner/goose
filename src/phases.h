// Goose compiler — the entry points of the phases built as translation units
// of their own. optimize.cpp holds the optimizer and BCE behind this one;
// typecheck.cpp, typecheck_calls.cpp, codegen.cpp and codegen_nodes.cpp hold
// members of TypeCheck and CodeGen, declared in typecheck.h and codegen.h.
#pragma once

namespace goose {

int OptimizeAndCheckBounds(Ast &ast, int optlevel, bool specs, bool nobce, bool bcelines,
                           bool bcetest, FILE *msgs);

}  // namespace goose
