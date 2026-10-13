/* The http package's C API: the functions http_layer.c defines, which
   http.goose declares as `extern "gs_http_..." fn`, listed once in
   GS_HTTP_API. test/api_check.py checks the two agree.

   Only C types cross. A Goose `u8[:]` is gs_http_bytes, passed by value. A
   `u8[>..]&` is gs_http_builder, which an append extends at the top of the
   array's data stack, as the runtime's own functions append. Engines,
   connections, sockets and TLS sessions are integers: a socket is its file
   descriptor, the others numbers into the layer's own tables.

   Threads (spec 11.2): an engine belongs to the worker that opened it, a
   client socket or TLS session to whoever holds it, and the reason the
   last TLS operation failed is per thread. Nothing here may be reached
   from the main thread only. */

#ifndef GS_HTTP_API_H
#define GS_HTTP_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma pack(push, 1)

typedef struct { uint8_t *data; int64_t len; } gs_http_bytes;   /* u8[:], the generated sl_u8 */

/* A reference to a Goose `u8[>..]`, the generated gs_rref: the array's
   header and the data stack its elements top, which an append extends. */
struct gs_http_rhdr { uint8_t *base; int64_t len; };
struct gs_http_stack { uint8_t *top; };
typedef struct { struct gs_http_rhdr *hdr; struct gs_http_stack *stk; } gs_http_builder;

#pragma pack(pop)

#define GS_HTTP_API(X) \
    /* Servers: a listener, and an engine per worker over it. */ \
    X(int64_t, gs_http_listen, (gs_http_bytes host, int64_t port, int64_t backlog)) \
    X(int64_t, gs_http_port, (int64_t fd)) \
    X(int64_t, gs_http_open, (int64_t lfd, int64_t idle_ms)) \
    X(int64_t, gs_http_open_tls, (int64_t lfd, int64_t idle_ms, gs_http_bytes cert_file, gs_http_bytes key_file)) \
    X(int64_t, gs_http_wait, (int64_t id, gs_http_builder buf)) \
    X(uint8_t, gs_http_write, (int64_t id, int64_t h, gs_http_bytes a, gs_http_bytes b)) \
    X(void, gs_http_done, (int64_t id, int64_t h, gs_http_bytes rest, int64_t need, uint8_t close_)) \
    X(int64_t, gs_http_live, (int64_t id)) \
    X(void, gs_http_close, (int64_t id)) \
    X(int64_t, gs_http_date, (gs_http_bytes out)) \
    /* Client sockets, blocking. */ \
    X(int64_t, gs_http_connect, (gs_http_bytes host, int64_t port, int64_t timeout_ms)) \
    X(uint8_t, gs_http_send, (int64_t fd, gs_http_bytes data)) \
    X(int64_t, gs_http_recv, (int64_t fd, gs_http_builder out, int64_t max)) \
    X(void, gs_http_close_fd, (int64_t fd)) \
    /* TLS over a client socket, when the package has it. */ \
    X(uint8_t, gs_http_tls_available, (void)) \
    X(int64_t, gs_http_tls_client, (int64_t fd, gs_http_bytes host, gs_http_bytes ca_file, uint8_t insecure)) \
    X(uint8_t, gs_http_tls_send, (int64_t h, gs_http_bytes data)) \
    X(int64_t, gs_http_tls_recv, (int64_t h, gs_http_builder out, int64_t max)) \
    X(void, gs_http_tls_close, (int64_t h)) \
    X(int64_t, gs_http_tls_error, (gs_http_bytes out))

#define GS_HTTP_PROTO(ret, name, params) ret name params;
GS_HTTP_API(GS_HTTP_PROTO)
#undef GS_HTTP_PROTO

#ifdef __cplusplus
}
#endif

#endif
