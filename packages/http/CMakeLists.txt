# The http package's native part: goose_http, the sockets and engine
# (src/http_layer.c) that http.goose declares its extern fns against, and,
# when Mbed TLS is there, the TLS layer over it (src/tls_layer.c), which
# gives the package https:// and serve_tls. Built by the Goose compiler
# through its wrapper project when a program needs the package
# (docs/design/packages.md §5.2), or into the compiler itself as a builtin
# package (§7.1).
#
# TLS is part of this package rather than one of its own because the engine
# calls the TLS layer from C, and two packages' C parts may not call each
# other (packages.md §5.5). It is optional: without Mbed TLS, or with
# -DGOOSE_HTTP_TLS=OFF, the package builds without it, and https:// fails
# with an error saying how to build it in.

cmake_minimum_required(VERSION 3.22)
project(goose_http_package C)

if(WIN32)
    # The sockets are not written for Windows yet: every call fails.
    set(goose_http_windows ON)
endif()

add_library(goose_http STATIC
    src/http_api.h
    src/http_layer.c
)
set_target_properties(goose_http PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON
                      INTERPROCEDURAL_OPTIMIZATION OFF)
if(MSVC)
    target_compile_options(goose_http PRIVATE /W4 /utf-8)
    target_compile_definitions(goose_http PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
    target_compile_options(goose_http PRIVATE -Wall -Wextra -Wno-missing-field-initializers
                           -Wno-unused-parameter)
endif()
find_package(Threads REQUIRED)
target_link_libraries(goose_http PUBLIC Threads::Threads)

# --- Mbed TLS ---------------------------------------------------------------------
# Beside this file, or the Goose tree's own while the package lives in that
# tree. Neither is committed: scripts/fetch_mbedtls.py in the Goose tree
# fetches the pinned release and checks its hash (third_party/mbedtls/README.md
# there).
option(GOOSE_HTTP_TLS "Build the http package's TLS layer when Mbed TLS is there" ON)
set(GOOSE_MBEDTLS_DIR "" CACHE PATH "The directory holding Mbed TLS's library/ and include/")
if(NOT GOOSE_MBEDTLS_DIR)
    foreach(cand "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mbedtls"
                 "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/mbedtls")
        if(EXISTS "${cand}/library/ssl_tls.c")
            set(GOOSE_MBEDTLS_DIR "${cand}")
            break()
        endif()
    endforeach()
endif()
if(goose_http_windows OR NOT GOOSE_HTTP_TLS)
    message(STATUS "http: built without TLS")
    return()
endif()
if(NOT GOOSE_MBEDTLS_DIR)
    message(STATUS "http: Mbed TLS is not there (run scripts/fetch_mbedtls.py); "
                   "building without TLS")
    return()
endif()

# Mbed TLS with the layer's configuration (src/mbedtls_user_config.h:
# threading on; DTLS, renegotiation and debugging off), built optimized
# even in a Debug build, as its own build does: an unoptimized handshake is
# slow enough to matter in the tests. No warnings: third-party code is not
# ours to act on.
file(GLOB goose_mbedtls_sources CONFIGURE_DEPENDS "${GOOSE_MBEDTLS_DIR}/library/*.c")
add_library(goose_http_mbedtls STATIC ${goose_mbedtls_sources})
target_include_directories(goose_http_mbedtls
    PUBLIC "${GOOSE_MBEDTLS_DIR}/include" "${CMAKE_CURRENT_SOURCE_DIR}/src"
    PRIVATE "${GOOSE_MBEDTLS_DIR}/library")
target_compile_definitions(goose_http_mbedtls PUBLIC
    MBEDTLS_USER_CONFIG_FILE="mbedtls_user_config.h")
set_target_properties(goose_http_mbedtls PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON
                      INTERPROCEDURAL_OPTIMIZATION OFF)
target_compile_options(goose_http_mbedtls PRIVATE -w -O2)
target_link_libraries(goose_http_mbedtls PUBLIC Threads::Threads)

target_sources(goose_http PRIVATE src/tls_api.h src/tls_layer.c src/mbedtls_user_config.h)
target_compile_definitions(goose_http PRIVATE GS_HTTP_TLS=1)
target_link_libraries(goose_http PUBLIC goose_http_mbedtls)

file(STRINGS "${GOOSE_MBEDTLS_DIR}/include/mbedtls/build_info.h" mbedtls_version_line
     REGEX "^#define MBEDTLS_VERSION_STRING ")
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" mbedtls_version "${mbedtls_version_line}")
message(STATUS "http: TLS over Mbed TLS ${mbedtls_version}, static")
