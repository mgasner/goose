# The sqlite package's native part: goose_sqlite3, the SQLite amalgamation,
# and goose_sqlite, the C layer over it that sqlite.goose declares its extern
# fns against (src/). Built by the Goose compiler through its wrapper project
# when a program needs the package (docs/design/packages.md §5.2), or into
# the compiler itself as a builtin package (§7.1). The compiler also links
# goose_sqlite3 on its own, built in or not, to check SQL at compile time.

cmake_minimum_required(VERSION 3.22)
project(goose_sqlite_package C)

# The amalgamation: beside this file, or the Goose tree's own while the
# package lives in that tree. Neither is committed: scripts/fetch_sqlite.py
# in the Goose tree fetches it (third_party/sqlite/README.md there).
set(GOOSE_SQLITE_AMALGAMATION "" CACHE PATH "The directory holding sqlite3.c and sqlite3.h")
if(NOT GOOSE_SQLITE_AMALGAMATION)
    foreach(cand "${CMAKE_CURRENT_SOURCE_DIR}/third_party/sqlite"
                 "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/sqlite")
        if(EXISTS "${cand}/sqlite3.c" AND EXISTS "${cand}/sqlite3.h")
            set(GOOSE_SQLITE_AMALGAMATION "${cand}")
            break()
        endif()
    endforeach()
endif()
if(NOT GOOSE_SQLITE_AMALGAMATION)
    message(STATUS "sqlite: the SQLite amalgamation is not there (run scripts/fetch_sqlite.py); "
                   "building nothing")
    return()
endif()

# --- SQLite ---------------------------------------------------------------------
# The options of docs/design/sqlite.md: multi-thread mode, which the layer
# makes safe by keeping each connection on the thread that opened it; the
# defaults a new program wants; column metadata, which checking SQL at
# compile time reads; and the common extensions. No warnings: third-party
# code is not ours to act on.
add_library(goose_sqlite3 STATIC "${GOOSE_SQLITE_AMALGAMATION}/sqlite3.c")
target_include_directories(goose_sqlite3 PUBLIC "${GOOSE_SQLITE_AMALGAMATION}")
target_compile_definitions(goose_sqlite3 PUBLIC
    SQLITE_THREADSAFE=2
    SQLITE_DQS=0
    SQLITE_DEFAULT_FOREIGN_KEYS=1
    SQLITE_DEFAULT_WAL_SYNCHRONOUS=1
    SQLITE_OMIT_LOAD_EXTENSION
    SQLITE_OMIT_DEPRECATED
    SQLITE_ENABLE_COLUMN_METADATA
    SQLITE_ENABLE_FTS5
    SQLITE_ENABLE_RTREE
    SQLITE_ENABLE_MATH_FUNCTIONS
)
set_target_properties(goose_sqlite3 PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON
                      INTERPROCEDURAL_OPTIMIZATION OFF)
if(MSVC)
    target_compile_options(goose_sqlite3 PRIVATE /W0)
else()
    target_compile_options(goose_sqlite3 PRIVATE -w)
endif()
find_package(Threads REQUIRED)
target_link_libraries(goose_sqlite3 PUBLIC Threads::Threads)
if(NOT WIN32)
    target_link_libraries(goose_sqlite3 PUBLIC m ${CMAKE_DL_LIBS})
endif()

# --- the sqlite layer -------------------------------------------------------------
add_library(goose_sqlite STATIC
    src/sqlite_api.h
    src/sqlite_layer.c
)
target_link_libraries(goose_sqlite PUBLIC goose_sqlite3)
set_target_properties(goose_sqlite PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON
                      INTERPROCEDURAL_OPTIMIZATION OFF)
if(MSVC)
    target_compile_options(goose_sqlite PRIVATE /W4 /utf-8)
    target_compile_definitions(goose_sqlite PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(goose_sqlite PRIVATE -Wall -Wextra -Wno-missing-field-initializers)
endif()

file(STRINGS "${GOOSE_SQLITE_AMALGAMATION}/sqlite3.h" sqlite_version_line
     REGEX "^#define SQLITE_VERSION ")
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" sqlite_version "${sqlite_version_line}")
message(STATUS "sqlite: SQLite ${sqlite_version}, static")
