// The C ceiling for the serving suite (bench/http/design.md): the standard
// C event core (libuv) and the standard fast C parser (picohttpparser), one
// loop per thread, answering the routes server.goose answers with the same
// bytes. Every thread's loop waits on one listening socket, as the Goose
// engine does on macOS, and the accept a thread wins is its connection.
//
//   uv_server <port> <threads>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <uv.h>

#include "picohttpparser.h"

#define MAX_HEADERS 64
#define MAX_BODY (1 << 24)

static int listen_fd;
static char blob[1 << 20];

typedef struct {
    uv_loop_t loop;
    uv_tcp_t server;
    time_t date_at;
    char date[32];
} worker_t;

typedef struct {
    uv_tcp_t tcp;
    worker_t *w;
    char *in;
    size_t inlen, incap;
    char *out;
    size_t outlen, outcap;
    int closing;
} conn_t;

typedef struct {
    uv_write_t req;
    char *data;
} write_t;

static void out_append(conn_t *c, const void *p, size_t n) {
    if (c->outlen + n > c->outcap) {
        size_t cap = c->outcap ? c->outcap : 4096;
        while (cap < c->outlen + n) cap *= 2;
        c->out = realloc(c->out, cap);
        c->outcap = cap;
    }
    memcpy(c->out + c->outlen, p, n);
    c->outlen += n;
}

static const char *date_of(worker_t *w) {
    time_t now = time(NULL);
    if (now != w->date_at) {
        struct tm tm;
        gmtime_r(&now, &tm);
        strftime(w->date, sizeof(w->date), "%a, %d %b %Y %H:%M:%S GMT", &tm);
        w->date_at = now;
    }
    return w->date;
}

static void on_close(uv_handle_t *h) {
    conn_t *c = (conn_t *)h;
    free(c->in);
    free(c->out);
    free(c);
}

static void on_written(uv_write_t *req, int status) {
    write_t *wr = (write_t *)req;
    free(wr->data);
    free(wr);
    (void)status;
}

// Writes a then b, as much as the socket takes now, queueing a copy of the
// rest.
static void send2(conn_t *c, const char *a, size_t alen, const char *b, size_t blen) {
    uv_buf_t bufs[2] = { uv_buf_init((char *)a, (unsigned)alen), uv_buf_init((char *)b, (unsigned)blen) };
    int nb = blen ? 2 : 1;
    int n = uv_try_write((uv_stream_t *)&c->tcp, bufs, nb);
    if (n == UV_EAGAIN) n = 0;
    if (n < 0) return;
    size_t sent = (size_t)n;
    if (sent >= alen + blen) return;
    size_t rest = alen + blen - sent;
    write_t *wr = malloc(sizeof(write_t));
    wr->data = malloc(rest);
    size_t k = 0;
    if (sent < alen) {
        memcpy(wr->data, a + sent, alen - sent);
        k = alen - sent;
        memcpy(wr->data + k, b, blen);
    } else {
        memcpy(wr->data, b + (sent - alen), rest);
    }
    uv_buf_t buf = uv_buf_init(wr->data, (unsigned)rest);
    uv_write(&wr->req, (uv_stream_t *)&c->tcp, &buf, 1, on_written);
}

static void head(conn_t *c, int status, const char *ctype, size_t len, int close) {
    char h[512];
    const char *line = status == 200 ? "HTTP/1.1 200 OK\r\n"
                     : status == 404 ? "HTTP/1.1 404 Not Found\r\n"
                     : status == 413 ? "HTTP/1.1 413 Content Too Large\r\n"
                                     : "HTTP/1.1 400 Bad Request\r\n";
    int n = snprintf(h, sizeof(h),
                     "%sServer: goose\r\nDate: %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n%s\r\n",
                     line, date_of(c->w), ctype, len, close ? "Connection: close\r\n" : "");
    out_append(c, h, (size_t)n);
}

static int same_ci(const char *a, size_t n, const char *lower) {
    if (strlen(lower) != n) return 0;
    for (size_t i = 0; i < n; i++)
        if ((a[i] | 0x20) != lower[i]) return 0;
    return 1;
}

// Answers every whole request in c->in; returns the bytes consumed.
static size_t serve(conn_t *c) {
    size_t at = 0;
    while (at < c->inlen) {
        const char *method, *path;
        size_t mlen, plen, nh = MAX_HEADERS;
        int minor;
        struct phr_header hs[MAX_HEADERS];
        int r = phr_parse_request(c->in + at, c->inlen - at, &method, &mlen, &path, &plen, &minor, hs, &nh, 0);
        if (r == -2) break;
        if (r < 0) {
            head(c, 400, "text/plain", 0, 1);
            c->closing = 1;
            return c->inlen;
        }
        long long clen = 0;
        int close = minor == 0, chunked = 0;
        for (size_t i = 0; i < nh; i++) {
            if (same_ci(hs[i].name, hs[i].name_len, "content-length"))
                clen = strtoll(hs[i].value, NULL, 10);
            else if (same_ci(hs[i].name, hs[i].name_len, "transfer-encoding"))
                chunked = 1;
            else if (same_ci(hs[i].name, hs[i].name_len, "connection")) {
                if (hs[i].value_len == 5 && !strncasecmp(hs[i].value, "close", 5)) close = 1;
                if (hs[i].value_len == 10 && !strncasecmp(hs[i].value, "keep-alive", 10)) close = 0;
            }
        }
        if (chunked || clen < 0 || clen > MAX_BODY) {
            head(c, chunked ? 400 : 413, "text/plain", 0, 1);
            c->closing = 1;
            return c->inlen;
        }
        if (c->inlen - at - (size_t)r < (size_t)clen) break;
        const char *body = c->in + at + r;
        int head_only = mlen == 4 && !memcmp(method, "HEAD", 4);
        if (plen == 10 && !memcmp(path, "/plaintext", 10)) {
            head(c, 200, "text/plain", 13, close);
            if (!head_only) out_append(c, "Hello, World!", 13);
        } else if (plen == 5 && !memcmp(path, "/json", 5)) {
            char j[64];
            int n = snprintf(j, sizeof(j), "{\"message\":\"%s\"}", "Hello, World!");
            head(c, 200, "application/json", (size_t)n, close);
            if (!head_only) out_append(c, j, (size_t)n);
        } else if (plen > 7 && !memcmp(path, "/bytes/", 7)) {
            long n = strtol(path + 7, NULL, 10);
            if (n < 0 || n > (long)sizeof(blob)) n = 0;
            head(c, 200, "application/octet-stream", (size_t)n, close);
            if (!head_only) {
                if (n >= 16384) {
                    send2(c, c->out, c->outlen, blob, (size_t)n);
                    c->outlen = 0;
                } else {
                    out_append(c, blob, (size_t)n);
                }
            }
        } else if (plen == 5 && !memcmp(path, "/echo", 5)) {
            char j[32];
            int n = snprintf(j, sizeof(j), "%lld", clen);
            head(c, 200, "text/plain", (size_t)n, close);
            if (!head_only) out_append(c, j, (size_t)n);
        } else {
            head(c, 404, "text/plain", 0, close);
        }
        (void)body;
        at += (size_t)r + (size_t)clen;
        if (close) {
            c->closing = 1;
            return c->inlen;
        }
    }
    return at;
}

static void on_alloc(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
    conn_t *c = (conn_t *)h;
    if (c->incap - c->inlen < 65536) {
        c->incap = c->incap ? c->incap * 2 : 65536;
        while (c->incap - c->inlen < 65536) c->incap *= 2;
        c->in = realloc(c->in, c->incap);
    }
    *buf = uv_buf_init(c->in + c->inlen, (unsigned)(c->incap - c->inlen));
    (void)suggested;
}

static void on_read(uv_stream_t *s, ssize_t n, const uv_buf_t *buf) {
    conn_t *c = (conn_t *)s;
    (void)buf;
    if (n < 0) {
        uv_close((uv_handle_t *)s, on_close);
        return;
    }
    c->inlen += (size_t)n;
    size_t used = serve(c);
    if (c->outlen) send2(c, c->out, c->outlen, NULL, 0);
    c->outlen = 0;
    if (c->closing) {
        uv_close((uv_handle_t *)s, on_close);
        return;
    }
    memmove(c->in, c->in + used, c->inlen - used);
    c->inlen -= used;
}

static void on_connection(uv_stream_t *server, int status) {
    if (status < 0) return;
    worker_t *w = server->data;
    conn_t *c = calloc(1, sizeof(conn_t));
    c->w = w;
    uv_tcp_init(&w->loop, &c->tcp);
    if (uv_accept(server, (uv_stream_t *)&c->tcp) != 0) {
        uv_close((uv_handle_t *)&c->tcp, on_close);
        return;
    }
    uv_tcp_nodelay(&c->tcp, 1);
    uv_read_start((uv_stream_t *)&c->tcp, on_alloc, on_read);
}

static void run_worker(void *arg) {
    worker_t *w = arg;
    uv_loop_init(&w->loop);
    uv_tcp_init(&w->loop, &w->server);
    w->server.data = w;
    if (uv_tcp_open(&w->server, dup(listen_fd)) != 0 ||
        uv_listen((uv_stream_t *)&w->server, 4096, on_connection) != 0) {
        fprintf(stderr, "uv_server: cannot listen\n");
        exit(1);
    }
    uv_run(&w->loop, UV_RUN_DEFAULT);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: uv_server <port> <threads>\n");
        return 2;
    }
    int port = atoi(argv[1]), threads = atoi(argv[2]);
    memset(blob, 'x', sizeof(blob));
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a = { 0 };
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listen_fd, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(listen_fd, 4096) != 0) {
        perror("uv_server: bind");
        return 1;
    }
    worker_t *ws = calloc((size_t)threads, sizeof(worker_t));
    uv_thread_t *ts = calloc((size_t)threads, sizeof(uv_thread_t));
    for (int i = 0; i < threads; i++) uv_thread_create(&ts[i], run_worker, &ws[i]);
    for (int i = 0; i < threads; i++) uv_thread_join(&ts[i]);
    return 0;
}
