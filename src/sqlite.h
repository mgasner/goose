// The compiler's side of the optional sqlite module (stdlib/sqlite.goose):
// whether the layer over SQLite (src/sqlite/) is built in, which a JIT run of
// a program using it needs, as does checking SQL at compile time, and where a
// program built from the generated C finds it to link. Without it, a program
// using only the unchecked API still typechecks and emits the same C.

#pragma once

namespace goose {

#ifdef GOOSE_HAVE_SQLITE
inline constexpr bool have_sqlite = true;
#else
inline constexpr bool have_sqlite = false;
#endif

// What running an sqlite program in this process says when the layer is not
// built in. The test runners report it as a skip.
inline const char *no_sqlite_error = "this compiler was built without SQLite; restore "
                                     "third_party/sqlite and reconfigure";

// The response file of link inputs a program built from the generated C
// needs to use sqlite (cmake/sqlite.cmake), for --sqlite-link.
inline string SqliteLinkFile(const string &exedir, const string &style) {
    #ifdef GOOSE_SQLITE_LINK_PATH
        const char *built = GOOSE_SQLITE_LINK_PATH;
    #else
        const char *built = nullptr;
    #endif
    return NativeLinkFile("--sqlite-link", have_sqlite, no_sqlite_error, "sqlite",
                          "GOOSE_SQLITE_LINK", built, exedir, style);
}

}  // namespace goose
