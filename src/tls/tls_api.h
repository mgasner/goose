/* The TLS layer's C API: the functions src/tls/tls_layer.c defines over
   Mbed TLS (third_party/mbedtls), listed once in GS_TLS_LAYER_API. That list
   expands into the prototypes below, into the ones the runtime's TLS section
   declares for a program built with the layer (src/runtime/runtime_tls.h),
   and into the symbol table a JIT run registers (src/jit.h).

   Goose never calls these directly. stdlib/http.goose calls the runtime's
   gs_tls_* and gs_net_* functions, and the runtime reaches the layer through
   a table of these (gs_net_tls_ops, runtime_ext.h), so the engine and the
   client sockets in runtime_net.h are written once for plain TCP and TLS,
   and a program built without the layer still builds: its https:// fails
   with an error saying so.

   Only C types cross, and nothing of Mbed TLS: a session or a server
   configuration is an opaque pointer, a file name a C string, and an error
   is text written into the caller's buffer.

   Threads (spec 11.2): nothing here is shared between threads. A client
   session's configuration (its trusted CAs, parsed from the bundle, and its
   random generator) is kept per thread, for the thread's life, and a
   server's per engine, which is one worker's. A session belongs to the
   thread that opened it. docs/design/http.md has why the CA chain is not
   parsed once for the process. */

#ifndef GS_TLS_API_H
#define GS_TLS_API_H

#include <stddef.h>
#include <stdint.h>

/* What a non-blocking step returns besides success and failure. */
#define GS_TLS_WANT_READ (-2)
#define GS_TLS_WANT_WRITE (-3)

#define GS_TLS_LAYER_API(X) \
    /* A client session over connected socket fd, its handshake done: \
       blocking, as the socket is. host is the name sent as SNI and checked \
       against the certificate. ca_file is a PEM bundle of trusted CAs; \
       NULL or "" looks for the system's. insecure skips verification \
       entirely. NULL on failure, with the reason in err. */ \
    X(void *, gs_tls_layer_client, (int fd, const char *host, const char *ca_file, int insecure, \
                                    char *err, size_t errcap)) \
    /* A server configuration from a PEM certificate chain and its key, \
       for one engine; NULL on failure, with the reason in err. */ \
    X(void *, gs_tls_layer_server, (const char *cert_file, const char *key_file, char *err, \
                                    size_t errcap)) \
    X(void, gs_tls_layer_server_free, (void *conf)) \
    /* A server session over accepted non-blocking socket fd; its \
       handshake is stepped by gs_tls_layer_handshake. NULL on failure. */ \
    X(void *, gs_tls_layer_accept, (void *conf, int fd)) \
    /* One step of a server session's handshake: 0 when it is done, \
       GS_TLS_WANT_READ or GS_TLS_WANT_WRITE while it waits for the \
       socket, -1 when it failed. */ \
    X(int, gs_tls_layer_handshake, (void *t)) \
    /* Reads application data into dst: a count, 0 at the end of the \
       stream (close_notify or EOF), -1 on an error, or a GS_TLS_WANT_. */ \
    X(int64_t, gs_tls_layer_read, (void *t, uint8_t *dst, int64_t max)) \
    /* Writes from src: the count taken (at most one record), -1 on an \
       error, or a GS_TLS_WANT_; after a WANT, call again with the same \
       bytes. */ \
    X(int64_t, gs_tls_layer_write, (void *t, const uint8_t *src, int64_t n)) \
    /* Decrypted bytes waiting inside the session, which the socket will not \
       signal. */ \
    X(int64_t, gs_tls_layer_pending, (void *t)) \
    /* Sends close_notify if it can without waiting, and frees the session; \
       the socket stays open. */ \
    X(void, gs_tls_layer_free, (void *t)) \
    /* The Mbed TLS version, as text. */ \
    X(const char *, gs_tls_layer_version, (void))

#ifdef __cplusplus
extern "C" {
#endif

#define GS_TLS_LAYER_PROTO(ret, name, params) ret name params;
GS_TLS_LAYER_API(GS_TLS_LAYER_PROTO)
#undef GS_TLS_LAYER_PROTO

#ifdef __cplusplus
}
#endif

#endif
