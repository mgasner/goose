/* Goose runtime: the TLS section, part of the program rather than of the
   runtime, spliced in after runtime_ext.h when the program calls into it
   (stdlib/http.goose's https:// client and serve_tls), standalone or not.
   It is the one place that decides whether the program has TLS: built with
   GS_TLS_LINKED defined, it hands the runtime (runtime_net.h) the table of
   the TLS layer's functions (src/tls/tls_api.h), which the program then
   links (`goose --tls-link cc` names the archive, and defines
   GS_TLS_LINKED); built without it, it hands over no table, and https://
   fails with an error saying how to build with TLS. A JIT run defines it
   when the compiler has the layer built in.

   Being in the program, not in the runtime object, keeps that object the
   same for every program: one built without TLS links with it as before.
   No prototype is emitted for a function this defines. */

#ifdef GS_TLS_LINKED
/* As src/tls/tls_api.h declares them. */
void *gs_tls_layer_client(int fd, const char *host, const char *ca_file, int insecure, char *err,
                          size_t errcap);
void *gs_tls_layer_server(const char *cert_file, const char *key_file, char *err, size_t errcap);
void gs_tls_layer_server_free(void *conf);
void *gs_tls_layer_accept(void *conf, int fd);
int gs_tls_layer_handshake(void *t);
int64_t gs_tls_layer_read(void *t, uint8_t *dst, int64_t max);
int64_t gs_tls_layer_write(void *t, const uint8_t *src, int64_t n);
int64_t gs_tls_layer_pending(void *t);
void gs_tls_layer_free(void *t);
static const gs_net_tls_ops gs_tls_ops = {
    gs_tls_layer_client, gs_tls_layer_server, gs_tls_layer_server_free,
    gs_tls_layer_accept, gs_tls_layer_handshake, gs_tls_layer_read,
    gs_tls_layer_write, gs_tls_layer_pending, gs_tls_layer_free,
};
#define GS_TLS_OPS (&gs_tls_ops)
#else
#define GS_TLS_OPS ((const gs_net_tls_ops *)0)
#endif

/* Whether this program has TLS. */
static uint8_t gs_tls_available(void) { return GS_TLS_OPS != 0; }

static int64_t gs_tls_client(int64_t fd, sl_u8 host, sl_u8 ca_file, uint8_t insecure) {
    return gs_net_tls_client(GS_TLS_OPS, fd, host, ca_file, insecure);
}

static int64_t gs_tls_open_engine(int64_t lfd, int64_t idle_ms, sl_u8 cert_file, sl_u8 key_file) {
    return gs_net_open_tls(GS_TLS_OPS, lfd, idle_ms, cert_file, key_file);
}
