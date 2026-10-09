# Builds the optional sqlite module: goose_sqlite, the C layer that
# stdlib/sqlite.goose declares its extern fns against (src/sqlite/), with the
# SQLite amalgamation vendored in third_party/sqlite compiled into it.
# Included from CMakeLists.txt only when the amalgamation is there and
# GOOSE_SQLITE is on; without it the compiler builds exactly as before, and
# only running an sqlite program in JIT mode, or checking SQL at compile time,
# reports that it was not compiled in.
#
# As with gfx, physics and ui, the same archive goes into goose, for JIT runs
# and for checking SQL at compile time, and into programs built from the
# generated C, whose link inputs are written to
# ${CMAKE_BINARY_DIR}/sqlite/<config>/link-{msvc,cc}.rsp for
# `goose --sqlite-link msvc|cc` to print.

set(SQLITE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/sqlite")

add_library(goose_sqlite STATIC
    src/sqlite/sqlite_api.h
    src/sqlite/sqlite_layer.c
    "${SQLITE_DIR}/sqlite3.c"
)
target_include_directories(goose_sqlite PUBLIC "${SQLITE_DIR}")
# The options of docs/design/sqlite.md: multi-thread mode, which the layer
# makes safe by keeping each connection on the thread that opened it; the
# defaults a new program wants; column metadata, which checking SQL at
# compile time reads; and the common extensions.
target_compile_definitions(goose_sqlite PUBLIC
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
set_target_properties(goose_sqlite PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON
                      INTERPROCEDURAL_OPTIMIZATION OFF)
# Warnings for the layer, none for SQLite: third-party code is not ours to
# act on.
if(MSVC)
    set_source_files_properties(src/sqlite/sqlite_layer.c PROPERTIES COMPILE_OPTIONS "/W4;/utf-8")
    set_source_files_properties("${SQLITE_DIR}/sqlite3.c" PROPERTIES COMPILE_OPTIONS "/W0")
    target_compile_definitions(goose_sqlite PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    set_source_files_properties(src/sqlite/sqlite_layer.c PROPERTIES COMPILE_OPTIONS
                                "-Wall;-Wextra;-Wno-missing-field-initializers")
    set_source_files_properties("${SQLITE_DIR}/sqlite3.c" PROPERTIES COMPILE_OPTIONS "-w")
endif()
find_package(Threads REQUIRED)
target_link_libraries(goose_sqlite PUBLIC Threads::Threads)
if(NOT WIN32)
    target_link_libraries(goose_sqlite PUBLIC m ${CMAKE_DL_LIBS})
endif()

# --- link inputs for programs built from the generated C ---------------------------
set(SQLITE_LINK_DIR "${CMAKE_BINARY_DIR}/sqlite/$<CONFIG>")
set(sqlite_cc_libs)
if(NOT WIN32)
    set(sqlite_cc_libs "-lm\n-pthread\n")
endif()
file(GENERATE OUTPUT "${SQLITE_LINK_DIR}/link-cc.rsp" CONTENT
"\"$<TARGET_LINKER_FILE:goose_sqlite>\"
${sqlite_cc_libs}")
if(WIN32)
    file(GENERATE OUTPUT "${SQLITE_LINK_DIR}/link-msvc.rsp" CONTENT
"\"$<TARGET_LINKER_FILE:goose_sqlite>\"
")
endif()

file(STRINGS "${SQLITE_DIR}/sqlite3.h" sqlite_version_line REGEX "^#define SQLITE_VERSION ")
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" sqlite_version "${sqlite_version_line}")
set(GOOSE_HAVE_SQLITE ON)
message(STATUS "sqlite: SQLite ${sqlite_version}, static")
