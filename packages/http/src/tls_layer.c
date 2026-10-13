/* The TLS layer over Mbed TLS: what tls_api.h declares, for the http
   package's client sockets and engine (http_layer.c) to run HTTPS through.
   docs/design/http.md, in the Goose tree, has the design.

   Client. A session is opened over a socket http_layer.c connected, which is
   blocking with SO_RCVTIMEO and SO_SNDTIMEO set; a send or receive that
   times out ends the session with an error rather than waiting again. It
   verifies the server's certificate against a bundle of trusted CAs and
   checks it names the host (which also goes out as SNI); TLS 1.2 is the
   least it accepts and 1.3 the most.

   Server. A configuration holds a certificate chain and its key, for one
   engine. Its sessions run over the engine's non-blocking sockets: the
   handshake, reads and writes return GS_TLS_WANT_READ or _WRITE where the
   socket would block, and the engine waits for it.

   Threads. Nothing here is shared between threads, beyond what Mbed TLS
   itself keeps for the process (the PSA crypto core, with its own locks;
   MBEDTLS_THREADING_C). A client's configurations, one per CA bundle, with
   the parsed bundle and a random generator, are the calling thread's, made
   on its first https:// connection and freed when it exits. A server
   configuration is its engine's. */

#include "tls_api.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/ssl_ciphersuites.h"
#include "mbedtls/version.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"

#ifdef MSG_NOSIGNAL
#define GS_TLS_SEND_FLAGS MSG_NOSIGNAL
#else
#define GS_TLS_SEND_FLAGS 0
#endif

static void gs_tls_say(char *err, size_t cap, const char *what, int ret) {
    if (!err || cap == 0) return;
    if (ret) {
        char text[160];
        mbedtls_strerror(ret, text, sizeof(text));
        snprintf(err, cap, "%s: %s", what, text);
    } else {
        snprintf(err, cap, "%s", what);
    }
}

/* ---------------------------------------------------------------------------
   Sessions and the socket under them. */

typedef struct {
    mbedtls_ssl_context ssl;
    int fd;
    int nonblock;   /* the engine's: EAGAIN is a WANT, not a timeout */
} gs_tls_session;

static int gs_tls_send_cb(void *ctx, const unsigned char *buf, size_t len) {
    gs_tls_session *s = (gs_tls_session *)ctx;
    for (;;) {
        ssize_t n = send(s->fd, buf, len, GS_TLS_SEND_FLAGS);
        if (n >= 0) return (int)n;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return s->nonblock ? MBEDTLS_ERR_SSL_WANT_WRITE : MBEDTLS_ERR_SSL_TIMEOUT;
        return errno == EPIPE || errno == ECONNRESET ? MBEDTLS_ERR_NET_CONN_RESET
                                                     : MBEDTLS_ERR_NET_SEND_FAILED;
    }
}

static int gs_tls_recv_cb(void *ctx, unsigned char *buf, size_t len) {
    gs_tls_session *s = (gs_tls_session *)ctx;
    for (;;) {
        ssize_t n = recv(s->fd, buf, len, 0);
        if (n >= 0) return (int)n;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return s->nonblock ? MBEDTLS_ERR_SSL_WANT_READ : MBEDTLS_ERR_SSL_TIMEOUT;
        return errno == ECONNRESET ? MBEDTLS_ERR_NET_CONN_RESET : MBEDTLS_ERR_NET_RECV_FAILED;
    }
}

static gs_tls_session *gs_tls_session_new(const mbedtls_ssl_config *conf, int fd, int nonblock) {
    gs_tls_session *s = (gs_tls_session *)calloc(1, sizeof(gs_tls_session));
    if (!s) return NULL;
    mbedtls_ssl_init(&s->ssl);
    s->fd = fd;
    s->nonblock = nonblock;
    if (mbedtls_ssl_setup(&s->ssl, conf) != 0) {
        mbedtls_ssl_free(&s->ssl);
        free(s);
        return NULL;
    }
    mbedtls_ssl_set_bio(&s->ssl, s, gs_tls_send_cb, gs_tls_recv_cb, NULL);
    return s;
}

/* A random generator: entropy from the system, a CTR-DRBG over it. */
typedef struct {
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
} gs_tls_rng;

static int gs_tls_rng_init(gs_tls_rng *r, const char *who) {
    mbedtls_entropy_init(&r->entropy);
    mbedtls_ctr_drbg_init(&r->drbg);
    return mbedtls_ctr_drbg_seed(&r->drbg, mbedtls_entropy_func, &r->entropy,
                                 (const unsigned char *)who, strlen(who));
}

static void gs_tls_rng_free(gs_tls_rng *r) {
    mbedtls_ctr_drbg_free(&r->drbg);
    mbedtls_entropy_free(&r->entropy);
}

/* What Mbed TLS keeps for the process, made once, before any thread
   configures anything: the PSA crypto core, which TLS 1.3 runs on (it
   locks its own state after this), and the list of cipher suites the
   build supports, which mbedtls_ssl_config_defaults otherwise fills in on
   its first call with no lock, a data race between two threads making
   their first configuration at once. */
static pthread_once_t gs_tls_once = PTHREAD_ONCE_INIT;
static int gs_tls_started;

static void gs_tls_start_once(void) {
    gs_tls_started = psa_crypto_init() == PSA_SUCCESS;
    (void)mbedtls_ssl_list_ciphersuites();
}

static int gs_tls_start(char *err, size_t cap) {
    pthread_once(&gs_tls_once, gs_tls_start_once);
    if (!gs_tls_started) {
        gs_tls_say(err, cap, "TLS: cannot start the crypto library", 0);
        return 0;
    }
    return 1;
}

/* ---------------------------------------------------------------------------
   The client: the calling thread's configurations, one per CA bundle. */

typedef struct gs_tls_client_conf {
    struct gs_tls_client_conf *next;
    char *ca_file;   /* the bundle as asked for ("" for the system's) */
    int insecure;
    mbedtls_x509_crt ca;
    mbedtls_ssl_config conf;
} gs_tls_client_conf;

typedef struct {
    gs_tls_rng rng;
    int seeded;
    gs_tls_client_conf *confs;
} gs_tls_thread;

static pthread_key_t gs_tls_key;
static pthread_once_t gs_tls_key_once = PTHREAD_ONCE_INIT;

static void gs_tls_thread_free(void *p) {
    gs_tls_thread *th = (gs_tls_thread *)p;
    while (th->confs) {
        gs_tls_client_conf *c = th->confs;
        th->confs = c->next;
        mbedtls_ssl_config_free(&c->conf);
        mbedtls_x509_crt_free(&c->ca);
        free(c->ca_file);
        free(c);
    }
    if (th->seeded) gs_tls_rng_free(&th->rng);
    free(th);
}

static void gs_tls_make_key(void) { pthread_key_create(&gs_tls_key, gs_tls_thread_free); }

static gs_tls_thread *gs_tls_this_thread(char *err, size_t cap) {
    pthread_once(&gs_tls_key_once, gs_tls_make_key);
    gs_tls_thread *th = (gs_tls_thread *)pthread_getspecific(gs_tls_key);
    if (th) return th;
    th = (gs_tls_thread *)calloc(1, sizeof(gs_tls_thread));
    if (!th) {
        gs_tls_say(err, cap, "TLS: out of memory", 0);
        return NULL;
    }
    int ret = gs_tls_rng_init(&th->rng, "goose tls client");
    if (ret != 0) {
        gs_tls_rng_free(&th->rng);
        free(th);
        gs_tls_say(err, cap, "TLS: cannot seed the random generator", ret);
        return NULL;
    }
    th->seeded = 1;
    pthread_setspecific(gs_tls_key, th);
    return th;
}

/* Where the system keeps its trusted CAs, as one PEM file: SSL_CERT_FILE
   if set, as OpenSSL reads it, then the usual places. */
static const char *gs_tls_system_bundle(void) {
    static const char *const places[] = {
        "/etc/ssl/cert.pem",                                   /* macOS, the BSDs, Alpine */
        "/etc/ssl/certs/ca-certificates.crt",                  /* Debian, Ubuntu, Arch */
        "/etc/pki/tls/certs/ca-bundle.crt",                    /* Fedora, RHEL */
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",   /* Fedora, RHEL */
        "/etc/ssl/ca-bundle.pem",                              /* openSUSE */
        "/usr/local/etc/ssl/cert.pem",                         /* FreeBSD ports */
    };
    const char *env = getenv("SSL_CERT_FILE");
    if (env && env[0]) return env;
    for (size_t i = 0; i < sizeof(places) / sizeof(places[0]); i++)
        if (access(places[i], R_OK) == 0) return places[i];
    return NULL;
}

static gs_tls_client_conf *gs_tls_client_conf_of(gs_tls_thread *th, const char *ca_file,
                                                 int insecure, char *err, size_t cap) {
    if (!ca_file) ca_file = "";
    for (gs_tls_client_conf *c = th->confs; c; c = c->next)
        if (c->insecure == insecure && (insecure || !strcmp(c->ca_file, ca_file))) return c;
    gs_tls_client_conf *c = (gs_tls_client_conf *)calloc(1, sizeof(gs_tls_client_conf));
    if (!c) {
        gs_tls_say(err, cap, "TLS: out of memory", 0);
        return NULL;
    }
    c->insecure = insecure;
    c->ca_file = strdup(insecure ? "" : ca_file);
    mbedtls_x509_crt_init(&c->ca);
    mbedtls_ssl_config_init(&c->conf);
    int ret = 0;
    if (!c->ca_file) {
        gs_tls_say(err, cap, "TLS: out of memory", 0);
        goto fail;
    }
    if (!insecure) {
        const char *path = ca_file[0] ? ca_file : gs_tls_system_bundle();
        if (!path) {
            gs_tls_say(err, cap,
                       "TLS: no CA bundle found (set the client's ca_file, or SSL_CERT_FILE)", 0);
            goto fail;
        }
        /* A bundle may hold certificates Mbed TLS cannot parse (a positive
           count of them); the rest are still trusted. */
        ret = mbedtls_x509_crt_parse_file(&c->ca, path);
        if (ret < 0 || c->ca.version == 0) {
            char what[600];
            snprintf(what, sizeof(what), "TLS: cannot read the CA bundle %s", path);
            gs_tls_say(err, cap, what, ret < 0 ? ret : 0);
            goto fail;
        }
    }
    ret = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        gs_tls_say(err, cap, "TLS: cannot configure", ret);
        goto fail;
    }
    mbedtls_ssl_conf_min_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &th->rng.drbg);
    if (insecure) {
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_NONE);
    } else {
        mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(&c->conf, &c->ca, NULL);
    }
    c->next = th->confs;
    th->confs = c;
    return c;
fail:
    mbedtls_ssl_config_free(&c->conf);
    mbedtls_x509_crt_free(&c->ca);
    free(c->ca_file);
    free(c);
    return NULL;
}

/* Why a client's handshake failed, said plainly for the common causes. */
static void gs_tls_handshake_error(gs_tls_session *s, int ret, char *err, size_t cap) {
    if (ret == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
        uint32_t flags = mbedtls_ssl_get_verify_result(&s->ssl);
        const char *why = NULL;
        if (flags & MBEDTLS_X509_BADCERT_CN_MISMATCH)
            why = "TLS: the server's certificate does not name this host";
        else if (flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED)
            why = "TLS: the server's certificate is not signed by a trusted CA";
        else if (flags & MBEDTLS_X509_BADCERT_EXPIRED)
            why = "TLS: the server's certificate has expired";
        else if (flags & MBEDTLS_X509_BADCERT_FUTURE)
            why = "TLS: the server's certificate is not valid yet";
        if (why) {
            gs_tls_say(err, cap, why, 0);
        } else {
            char info[200];
            int n = mbedtls_x509_crt_verify_info(info, sizeof(info), "", flags);
            while (n > 0 && (info[n - 1] == '\n' || info[n - 1] == ' ')) info[--n] = 0;
            snprintf(err, cap, "TLS: the server's certificate failed verification: %s",
                     n > 0 ? info : "unknown reason");
        }
        return;
    }
    if (ret == MBEDTLS_ERR_SSL_TIMEOUT) {
        gs_tls_say(err, cap, "TLS: the handshake timed out", 0);
        return;
    }
    gs_tls_say(err, cap, "TLS: the handshake failed", ret);
}

void *gs_tls_layer_client(int fd, const char *host, const char *ca_file, int insecure, char *err,
                          size_t errcap) {
    if (!gs_tls_start(err, errcap)) return NULL;
    gs_tls_thread *th = gs_tls_this_thread(err, errcap);
    if (!th) return NULL;
    gs_tls_client_conf *c = gs_tls_client_conf_of(th, ca_file, insecure, err, errcap);
    if (!c) return NULL;
    gs_tls_session *s = gs_tls_session_new(&c->conf, fd, 0);
    if (!s) {
        gs_tls_say(err, errcap, "TLS: cannot start a session", 0);
        return NULL;
    }
    /* The name to send as SNI and to find in the certificate. Set even when
       not verifying: the server may pick its certificate by it. */
    int ret = mbedtls_ssl_set_hostname(&s->ssl, host);
    if (ret != 0) {
        gs_tls_say(err, errcap, "TLS: bad host name", ret);
        gs_tls_layer_free(s);
        return NULL;
    }
    do ret = mbedtls_ssl_handshake(&s->ssl);
    while (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE);
    if (ret != 0) {
        gs_tls_handshake_error(s, ret, err, errcap);
        mbedtls_ssl_free(&s->ssl);
        free(s);
        return NULL;
    }
    return s;
}

/* ---------------------------------------------------------------------------
   The server: a configuration per engine, sessions per connection. */

typedef struct {
    gs_tls_rng rng;
    mbedtls_x509_crt chain;
    mbedtls_pk_context key;
    mbedtls_ssl_config conf;
} gs_tls_server_conf;

void gs_tls_layer_server_free(void *p) {
    gs_tls_server_conf *sc = (gs_tls_server_conf *)p;
    if (!sc) return;
    mbedtls_ssl_config_free(&sc->conf);
    mbedtls_pk_free(&sc->key);
    mbedtls_x509_crt_free(&sc->chain);
    gs_tls_rng_free(&sc->rng);
    free(sc);
}

void *gs_tls_layer_server(const char *cert_file, const char *key_file, char *err, size_t errcap) {
    if (!gs_tls_start(err, errcap)) return NULL;
    gs_tls_server_conf *sc = (gs_tls_server_conf *)calloc(1, sizeof(gs_tls_server_conf));
    if (!sc) {
        gs_tls_say(err, errcap, "TLS: out of memory", 0);
        return NULL;
    }
    mbedtls_x509_crt_init(&sc->chain);
    mbedtls_pk_init(&sc->key);
    mbedtls_ssl_config_init(&sc->conf);
    char what[600];
    int ret = gs_tls_rng_init(&sc->rng, "goose tls server");
    if (ret != 0) {
        gs_tls_say(err, errcap, "TLS: cannot seed the random generator", ret);
        goto fail;
    }
    ret = mbedtls_x509_crt_parse_file(&sc->chain, cert_file);
    if (ret != 0) {
        snprintf(what, sizeof(what), "TLS: cannot read the certificate %s", cert_file);
        gs_tls_say(err, errcap, what, ret > 0 ? 0 : ret);
        goto fail;
    }
    ret = mbedtls_pk_parse_keyfile(&sc->key, key_file, NULL, mbedtls_ctr_drbg_random, &sc->rng.drbg);
    if (ret != 0) {
        snprintf(what, sizeof(what), "TLS: cannot read the key %s", key_file);
        gs_tls_say(err, errcap, what, ret);
        goto fail;
    }
    ret = mbedtls_ssl_config_defaults(&sc->conf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret == 0) {
        mbedtls_ssl_conf_min_tls_version(&sc->conf, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_max_tls_version(&sc->conf, MBEDTLS_SSL_VERSION_TLS1_3);
        mbedtls_ssl_conf_rng(&sc->conf, mbedtls_ctr_drbg_random, &sc->rng.drbg);
        ret = mbedtls_pk_check_pair(&sc->chain.pk, &sc->key, mbedtls_ctr_drbg_random,
                                    &sc->rng.drbg);
        if (ret == 0) ret = mbedtls_ssl_conf_own_cert(&sc->conf, &sc->chain, &sc->key);
        if (ret != 0) {
            gs_tls_say(err, errcap, "TLS: the key does not go with the certificate", ret);
            goto fail;
        }
    } else {
        gs_tls_say(err, errcap, "TLS: cannot configure", ret);
        goto fail;
    }
    return sc;
fail:
    gs_tls_layer_server_free(sc);
    return NULL;
}

void *gs_tls_layer_accept(void *conf, int fd) {
    gs_tls_server_conf *sc = (gs_tls_server_conf *)conf;
    return sc ? gs_tls_session_new(&sc->conf, fd, 1) : NULL;
}

int gs_tls_layer_handshake(void *t) {
    gs_tls_session *s = (gs_tls_session *)t;
    int ret = mbedtls_ssl_handshake(&s->ssl);
    if (ret == 0) return 0;
    if (ret == MBEDTLS_ERR_SSL_WANT_READ) return GS_TLS_WANT_READ;
    if (ret == MBEDTLS_ERR_SSL_WANT_WRITE) return GS_TLS_WANT_WRITE;
    return -1;
}

/* ---------------------------------------------------------------------------
   Both sides. */

int64_t gs_tls_layer_read(void *t, uint8_t *dst, int64_t max) {
    gs_tls_session *s = (gs_tls_session *)t;
    if (max <= 0) return 0;
    if (max > (1 << 30)) max = 1 << 30;
    for (;;) {
        int ret = mbedtls_ssl_read(&s->ssl, dst, (size_t)max);
        if (ret > 0) return ret;
        switch (ret) {
        case 0:
        case MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY:
        case MBEDTLS_ERR_SSL_CONN_EOF:
            return 0;
        case MBEDTLS_ERR_SSL_WANT_READ:
            return GS_TLS_WANT_READ;
        case MBEDTLS_ERR_SSL_WANT_WRITE:
            return GS_TLS_WANT_WRITE;
        /* A TLS 1.3 server may send tickets, and its client may be told of
           them; neither is data. */
        case MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET:
            continue;
        default:
            return -1;
        }
    }
}

int64_t gs_tls_layer_write(void *t, const uint8_t *src, int64_t n) {
    gs_tls_session *s = (gs_tls_session *)t;
    if (n <= 0) return 0;
    if (n > (1 << 30)) n = 1 << 30;
    int ret = mbedtls_ssl_write(&s->ssl, src, (size_t)n);
    if (ret >= 0) return ret;
    if (ret == MBEDTLS_ERR_SSL_WANT_READ) return GS_TLS_WANT_READ;
    if (ret == MBEDTLS_ERR_SSL_WANT_WRITE) return GS_TLS_WANT_WRITE;
    return -1;
}

int64_t gs_tls_layer_pending(void *t) {
    return (int64_t)mbedtls_ssl_get_bytes_avail(&((gs_tls_session *)t)->ssl);
}

void gs_tls_layer_free(void *t) {
    gs_tls_session *s = (gs_tls_session *)t;
    if (!s) return;
    /* One try: a non-blocking socket that cannot take it now goes without,
       and a blocking one has its send timeout. */
    if (mbedtls_ssl_is_handshake_over(&s->ssl)) mbedtls_ssl_close_notify(&s->ssl);
    mbedtls_ssl_free(&s->ssl);
    free(s);
}

const char *gs_tls_layer_version(void) { return MBEDTLS_VERSION_STRING; }
