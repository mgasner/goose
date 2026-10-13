// The compiler's side of TLS for the http module: whether the layer over
// Mbed TLS (src/tls/) is built in, which a JIT run of a program using
// https:// gets, and where a program built from the generated C finds it to
// link. Without it, such a program still typechecks, emits the same C and
// runs; its https:// fails with an error saying TLS is not built in.

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
// built from the generated C needs for TLS (cmake/tls.cmake), for --tls-link.
inline string TlsLinkFile(const string &exedir, const string &style) {
    #ifdef GOOSE_TLS_LINK_PATH
        const char *built = GOOSE_TLS_LINK_PATH;
    #else
        const char *built = nullptr;
    #endif
    if (style == "msvc") throw CompileError { "--tls-link: TLS is not built on Windows yet" };
    return NativeLinkFile("--tls-link", have_tls, no_tls_error, "tls", "GOOSE_TLS_LINK", built,
                          exedir, style);
}

}  // namespace goose
