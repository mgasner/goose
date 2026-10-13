# Builds the optional TLS layer behind https:// in the http module:
# goose_tls, the layer in src/tls/ over Mbed TLS, whose library/ and
# include/ trees scripts/fetch_mbedtls.py vendors into third_party/mbedtls
# (not committed). Included from CMakeLists.txt only when they are there and
# GOOSE_TLS is on; without them the compiler builds exactly as before, and
# an https:// URL fails with an error saying TLS was not built in.
#
# As with a builtin package's native part, the same archive goes into goose,
# for JIT runs, and into programs built from the generated C, whose link
# inputs are written to ${CMAKE_BINARY_DIR}/tls/<config>/link-cc.rsp for
# `goose build` to link and `goose --tls-link cc` to print. Unlike theirs,
# that file also defines GS_TLS_LINKED, which is what turns on the runtime's
# TLS section (src/runtime/runtime_tls.h): a program compiled without it
# builds with no TLS and nothing more to link.

set(MBEDTLS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mbedtls")

if(WIN32)
    # The runtime's sockets are not written for Windows yet (runtime_net.h).
    message(STATUS "tls: the http module's sockets do not run on Windows yet; building without TLS")
    return()
endif()

file(GLOB mbedtls_sources CONFIGURE_DEPENDS "${MBEDTLS_DIR}/library/*.c")
add_library(goose_tls STATIC
    src/tls/tls_api.h
    src/tls/tls_layer.c
    src/tls/mbedtls_user_config.h
    ${mbedtls_sources}
)
target_include_directories(goose_tls PRIVATE "${MBEDTLS_DIR}/include" "${MBEDTLS_DIR}/library"
                           "${CMAKE_CURRENT_SOURCE_DIR}/src/tls")
target_compile_definitions(goose_tls PRIVATE MBEDTLS_USER_CONFIG_FILE="mbedtls_user_config.h")
set_target_properties(goose_tls PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON
                      INTERPROCEDURAL_OPTIMIZATION OFF)
# Warnings for the layer, none for Mbed TLS: third-party code is not ours to
# act on. Mbed TLS is built optimized even in a Debug build, as its own
# build does: an unoptimized handshake is slow enough to matter in the tests.
set_source_files_properties(src/tls/tls_layer.c PROPERTIES COMPILE_OPTIONS
                            "-Wall;-Wextra;-Wno-missing-field-initializers")
set_source_files_properties(${mbedtls_sources} PROPERTIES COMPILE_OPTIONS "-w;-O2")
find_package(Threads REQUIRED)
target_link_libraries(goose_tls PUBLIC Threads::Threads)

# --- link inputs for programs built from the generated C ---------------------------
set(TLS_LINK_DIR "${CMAKE_BINARY_DIR}/tls/$<CONFIG>")
file(GENERATE OUTPUT "${TLS_LINK_DIR}/link-cc.rsp" CONTENT
"-DGS_TLS_LINKED=1
\"$<TARGET_LINKER_FILE:goose_tls>\"
-pthread
")

file(STRINGS "${MBEDTLS_DIR}/include/mbedtls/build_info.h" mbedtls_version_line
     REGEX "^#define MBEDTLS_VERSION_STRING ")
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" mbedtls_version "${mbedtls_version_line}")
set(GOOSE_HAVE_TLS ON)
message(STATUS "tls: Mbed TLS ${mbedtls_version}, static")
