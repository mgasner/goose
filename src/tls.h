// The compiler's side of TLS for the http module: whether the layer over
// Mbed TLS (src/tls/) is built in, which a JIT run of a program using
// https:// gets, and where a program built from the generated C finds it to
// link. Without it, such a program still typechecks, emits the same C and
// runs; its https:// fails with an error saying TLS is not built in.
//
// Unlike the native parts of the blessed packages (builtin.h, native.h),
// this layer is the compiler's own: http.goose is a stdlib module, and the
// runtime reaches the layer through a table the program passes it
// (runtime_tls.h), so that a program without TLS builds and links as
// before. `goose build` and a JIT run add it to what the program's packages
// bring when the program reaches the TLS section (main.cpp).

#pragma once

#ifdef GOOSE_HAVE_TLS
#include "tls/tls_api.h"
#endif

namespace goose {

#ifdef GOOSE_HAVE_TLS
inline constexpr bool have_tls = true;
#else
inline constexpr bool have_tls = false;
#endif

inline const char *no_tls_error = "this compiler was built without Mbed TLS; run "
                                  "python scripts/fetch_mbedtls.py and reconfigure";

// The response file of link inputs (and the GS_TLS_LINKED define) a program
// built from the generated C needs for TLS (cmake/tls.cmake), for --tls-link
// and `goose build`. `style` is "cc" for gcc and clang; the layer is not
// built for MSVC. Looked for in the directory GOOSE_TLS_LINK names, for a
// moved build tree, then in `tls/` next to the compiler binary, for an
// installed one, then where CMake wrote it.
inline string TlsLinkFile(const string &exedir, const string &style) {
    if (style != "msvc" && style != "cc")
        throw CompileError { cat("--tls-link takes msvc or cc, not ", style) };
    if (style == "msvc") throw CompileError { "--tls-link: TLS is not built on Windows yet" };
    if (!have_tls) throw CompileError { no_tls_error };
    auto name = cat("link-", style, ".rsp");
    vector<string> dirs;
    if (auto dir = getenv("GOOSE_TLS_LINK")) dirs.push_back(dir);
    dirs.push_back(cat(exedir, "tls"));
    #ifdef GOOSE_TLS_LINK_PATH
        dirs.push_back(GOOSE_TLS_LINK_PATH);
    #endif
    for (auto &dir : dirs) {
        auto path = cat(dir, "/", name);
        if (auto f = fopen(path.c_str(), "rb")) {
            fclose(f);
            return path;
        }
    }
    throw CompileError { cat("cannot find ", name, " (set GOOSE_TLS_LINK to its directory)") };
}

// The layer's functions, by name, for a JIT run of a program that reaches
// the TLS section (RunJit takes them with the packages' own).
inline void AddTlsSymbols(vector<pair<string, const void *>> &symbols) {
    #ifdef GOOSE_HAVE_TLS
        #define GS_TLS_SYMBOL(ret, name, params) symbols.emplace_back(#name, (const void *)&name);
        GS_TLS_LAYER_API(GS_TLS_SYMBOL)
        #undef GS_TLS_SYMBOL
    #else
        (void)symbols;
    #endif
}

}  // namespace goose
