/* Goose runtime: the sockets behind stdlib/http.goose (spec §7.10), as
   runtime_ext.h declares them, which this follows; docs/design/http.md has
   the design.

   An engine is one worker's event loop: a kqueue (macOS, BSD) or an epoll
   instance (Linux), its listening socket, and the connections it accepted.
   Engines are not shared: each worker opens its own, and nothing here locks
   on the request path. The Goose side does all of HTTP. The engine moves
   bytes: gs_net_wait reads a connection's input straight onto the top of
   the caller's builder, the program parses what it can, and gs_net_done
   hands back the unparsed rest, which the engine keeps until more arrives.

   A handle names a connection as its slot in the engine's table and that
   slot's generation, so a handle kept past its connection's close names
   nothing rather than whatever reuses the slot. Engines are numbered in one
   process-wide table, so a stray number is refused, not dereferenced.

   Windows has no implementation yet: every call fails (-1 or false). */

#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/uio.h>
#ifdef __linux__
#include <sys/epoll.h>
#define GS_NET_EPOLL 1
#else
#include <sys/event.h>
#define GS_NET_EPOLL 0
#endif
#endif

#ifndef _WIN32

/* How much one read asks for when the program has not said it needs more. */
#define GS_NET_READ 65536
#define GS_NET_EVENTS 256
#define GS_NET_MAX_ENGINES 4096

typedef struct {
    int fd;               /* -1: a free slot */
    uint32_t gen;
    uint8_t closing;      /* close once the pending output is written */
    uint8_t writing;      /* write interest is armed */
    int64_t last_ms;      /* last activity, for the idle timeout */
    int64_t need;         /* deliver no input until this much is buffered */
    uint8_t *in;          /* unparsed input the program handed back */
    int64_t inlen, incap;
    uint8_t *out;         /* output the socket did not take yet */
    int64_t outoff, outlen, outcap;
    int32_t next_free;
} gs_net_conn;

typedef struct {
    int poll;             /* kqueue or epoll fd */
    int lfd;              /* the listening socket */
    int accepting;        /* the listener is registered */
    gs_net_conn *conns;
    int32_t nconns, capconns, free_head;
    int64_t live;
    int64_t idle_ms;
    int64_t last_sweep_ms;
#if GS_NET_EPOLL
    struct epoll_event evs[GS_NET_EVENTS];
#else
    struct kevent evs[GS_NET_EVENTS];
#endif
    int nev, iev;
} gs_net_engine;

static gs_net_engine *gs_net_engines[GS_NET_MAX_ENGINES];
static pthread_mutex_t gs_net_mutex = PTHREAD_MUTEX_INITIALIZER;

static int64_t gs_net_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void gs_net_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}

/* A host name or address as a C string; -1 if it does not fit or holds a
   NUL. */
static int gs_net_cstr(sl_u8 s, char *buf, int cap) {
    if (s.len < 0 || s.len >= cap || memchr(s.data, 0, (size_t)s.len)) return -1;
    memcpy(buf, s.data, (size_t)s.len);
    buf[s.len] = 0;
    return (int)s.len;
}

/* ---------------------------------------------------------------------------
   Listening. On Linux every call opens a socket of its own with
   SO_REUSEPORT, and the kernel spreads connections over them. Elsewhere
   SO_REUSEPORT gives every connection to the socket bound last, so the
   calls for one address share the socket the first one opened: each
   worker's engine waits on it, and the accept one of them wins is that
   worker's connection. */

#if !GS_NET_EPOLL
typedef struct { char host[256]; int64_t port; int fd; } gs_net_shared;
static gs_net_shared gs_net_listeners[64];
static int gs_net_nlisteners;
#endif

static int gs_net_open_listener(const char *host, int64_t port, int64_t backlog) {
    struct addrinfo hints, *res = NULL, *ai;
    char portstr[16];
    int fd = -1, one = 1;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    snprintf(portstr, sizeof(portstr), "%lld", (long long)port);
    if (getaddrinfo(host[0] ? host : NULL, portstr, &hints, &res) != 0) return -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#if GS_NET_EPOLL
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
#endif
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 &&
            listen(fd, backlog > 0 ? (int)backlog : SOMAXCONN) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) gs_net_nonblock(fd);
    return fd;
}

GS_API int64_t gs_net_listen(sl_u8 host, int64_t port, int64_t backlog) {
    char h[256];
    if (gs_net_cstr(host, h, sizeof(h)) < 0 || port < 0 || port > 65535) return -1;
#if GS_NET_EPOLL
    return gs_net_open_listener(h, port, backlog);
#else
    pthread_mutex_lock(&gs_net_mutex);
    int fd = -1;
    for (int i = 0; i < gs_net_nlisteners; i++)
        if (port != 0 && gs_net_listeners[i].port == port && !strcmp(gs_net_listeners[i].host, h))
            fd = gs_net_listeners[i].fd;
    if (fd < 0) {
        fd = gs_net_open_listener(h, port, backlog);
        if (fd >= 0 && port != 0 && gs_net_nlisteners < 64) {
            gs_net_shared *s = &gs_net_listeners[gs_net_nlisteners++];
            strcpy(s->host, h);
            s->port = port;
            s->fd = fd;
        }
    }
    pthread_mutex_unlock(&gs_net_mutex);
    return fd;
#endif
}

/* The port a socket is bound to (a listener opened on port 0 has one the
   system chose), or -1. */
GS_API int64_t gs_net_port(int64_t fd) {
    struct sockaddr_storage ss;
    socklen_t n = sizeof(ss);
    if (fd < 0 || getsockname((int)fd, (struct sockaddr *)&ss, &n) != 0) return -1;
    if (ss.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&ss)->sin_port);
    if (ss.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
    return -1;
}

/* ---------------------------------------------------------------------------
   The poller: interest in reading, and in writing while output is pending. */

static int gs_net_watch(gs_net_engine *e, int fd, uint64_t tag, int write, int add) {
#if GS_NET_EPOLL
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN | EPOLLRDHUP | (write ? EPOLLOUT : 0);
    ev.data.u64 = tag;
    return epoll_ctl(e->poll, add ? EPOLL_CTL_ADD : EPOLL_CTL_MOD, fd, &ev);
#else
    struct kevent ch[2];
    int n = 0;
    if (add) EV_SET(&ch[n++], fd, EVFILT_READ, EV_ADD, 0, 0, (void *)(uintptr_t)tag);
    if (write || !add)
        EV_SET(&ch[n++], fd, EVFILT_WRITE, write ? EV_ADD | EV_ENABLE : EV_DISABLE, 0, 0,
               (void *)(uintptr_t)tag);
    return kevent(e->poll, ch, n, NULL, 0, NULL);
#endif
}

#define GS_NET_LISTENER_TAG (~(uint64_t)0)

static void gs_net_listen_on(gs_net_engine *e, int on) {
    if (e->accepting == on) return;
    e->accepting = on;
#if GS_NET_EPOLL
    if (on) {
        struct epoll_event ev;
        memset(&ev, 0, sizeof(ev));
        ev.events = EPOLLIN;
        ev.data.u64 = GS_NET_LISTENER_TAG;
        epoll_ctl(e->poll, EPOLL_CTL_ADD, e->lfd, &ev);
    } else {
        epoll_ctl(e->poll, EPOLL_CTL_DEL, e->lfd, NULL);
    }
#else
    struct kevent ch;
    EV_SET(&ch, e->lfd, EVFILT_READ, on ? EV_ADD : EV_DELETE, 0, 0,
           (void *)(uintptr_t)GS_NET_LISTENER_TAG);
    kevent(e->poll, &ch, 1, NULL, 0, NULL);
#endif
}

static gs_net_engine *gs_net_engine_of(int64_t id) {
    if (id < 0 || id >= GS_NET_MAX_ENGINES) return NULL;
    return gs_net_engines[id];
}

/* An engine waiting on listener lfd; its number, or -1. idle_ms closes a
   connection that has been silent that long (0: never). */
GS_API int64_t gs_net_open(int64_t lfd, int64_t idle_ms) {
    if (lfd < 0) return -1;
#ifdef SIGPIPE
    signal(SIGPIPE, SIG_IGN);
#endif
    gs_net_engine *e = (gs_net_engine *)calloc(1, sizeof(gs_net_engine));
    if (!e) return -1;
#if GS_NET_EPOLL
    e->poll = epoll_create1(EPOLL_CLOEXEC);
#else
    e->poll = kqueue();
#endif
    if (e->poll < 0) {
        free(e);
        return -1;
    }
    e->lfd = (int)lfd;
    e->free_head = -1;
    e->idle_ms = idle_ms;
    e->last_sweep_ms = gs_net_now_ms();
    gs_net_listen_on(e, 1);
    int64_t id = -1;
    pthread_mutex_lock(&gs_net_mutex);
    for (int i = 0; i < GS_NET_MAX_ENGINES; i++)
        if (!gs_net_engines[i]) {
            gs_net_engines[i] = e;
            id = i;
            break;
        }
    pthread_mutex_unlock(&gs_net_mutex);
    if (id < 0) {
        close(e->poll);
        free(e);
    }
    return id;
}

/* ---------------------------------------------------------------------------
   Connections. */

static int64_t gs_net_handle(gs_net_engine *e, int32_t slot) {
    return ((int64_t)e->conns[slot].gen << 32) | (int64_t)(uint32_t)slot;
}

static gs_net_conn *gs_net_conn_of(gs_net_engine *e, int64_t h) {
    if (h < 0) return NULL;
    int64_t slot = h & 0xffffffff;
    if (slot >= e->nconns) return NULL;
    gs_net_conn *c = &e->conns[slot];
    if (c->fd < 0 || c->gen != (uint32_t)(h >> 32)) return NULL;
    return c;
}

static void gs_net_close_conn(gs_net_engine *e, gs_net_conn *c) {
    if (c->fd < 0) return;
    close(c->fd);   /* which also drops its registrations */
    c->fd = -1;
    c->gen = (c->gen + 1) & 0x7fffffff;   /* keeps every handle positive */
    free(c->in);
    free(c->out);
    c->in = c->out = NULL;
    c->inlen = c->incap = c->outoff = c->outlen = c->outcap = 0;
    int32_t slot = (int32_t)(c - e->conns);
    c->next_free = e->free_head;
    e->free_head = slot;
    e->live--;
}

static void gs_net_accept(gs_net_engine *e) {
    for (int k = 0; k < 64; k++) {
        int fd = accept(e->lfd, NULL, NULL);
        if (fd < 0) {
            /* Out of descriptors: stop listening until the next sweep, or
               the listener would wake the loop for nothing. */
            if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM)
                gs_net_listen_on(e, 0);
            return;
        }
        gs_net_nonblock(fd);
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        int32_t slot = e->free_head;
        if (slot >= 0) {
            e->free_head = e->conns[slot].next_free;
        } else {
            if (e->nconns == e->capconns) {
                int32_t cap = e->capconns ? e->capconns * 2 : 64;
                gs_net_conn *cs = (gs_net_conn *)realloc(e->conns, sizeof(gs_net_conn) * (size_t)cap);
                if (!cs) {
                    close(fd);
                    return;
                }
                e->conns = cs;
                e->capconns = cap;
            }
            slot = e->nconns++;
            memset(&e->conns[slot], 0, sizeof(gs_net_conn));
        }
        gs_net_conn *c = &e->conns[slot];
        c->fd = fd;
        c->closing = c->writing = 0;
        c->need = 0;
        c->last_ms = gs_net_now_ms();
        e->live++;
        if (gs_net_watch(e, fd, (uint64_t)gs_net_handle(e, slot), 0, 1) != 0)
            gs_net_close_conn(e, c);
    }
}

/* Writes what is pending; 0 when all of it went, 1 when some waits for the
   socket, -1 when the connection failed (and is closed). */
static int gs_net_flush(gs_net_engine *e, gs_net_conn *c) {
    while (c->outoff < c->outlen) {
        ssize_t n = send(c->fd, c->out + c->outoff, (size_t)(c->outlen - c->outoff),
#ifdef MSG_NOSIGNAL
                         MSG_NOSIGNAL
#else
                         0
#endif
        );
        if (n > 0) {
            c->outoff += n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!c->writing) {
                c->writing = 1;
                gs_net_watch(e, c->fd, (uint64_t)gs_net_handle(e, (int32_t)(c - e->conns)), 1, 0);
            }
            return 1;
        }
        gs_net_close_conn(e, c);
        return -1;
    }
    c->outoff = c->outlen = 0;
    if (c->writing) {
        c->writing = 0;
        gs_net_watch(e, c->fd, (uint64_t)gs_net_handle(e, (int32_t)(c - e->conns)), 0, 0);
    }
    if (c->closing) {
        gs_net_close_conn(e, c);
        return -1;
    }
    return 0;
}

static int gs_net_keep(uint8_t **p, int64_t *len, int64_t *cap, const uint8_t *src, int64_t n) {
    if (n <= 0) return 1;
    if (*len + n > *cap) {
        int64_t nc = *cap ? *cap : 4096;
        while (nc < *len + n) nc *= 2;
        uint8_t *q = (uint8_t *)realloc(*p, (size_t)nc);
        if (!q) return 0;
        *p = q;
        *cap = nc;
    }
    memcpy(*p + *len, src, (size_t)n);
    *len += n;
    return 1;
}

static void gs_net_sweep(gs_net_engine *e, int64_t now) {
    e->last_sweep_ms = now;
    if (!e->accepting) gs_net_listen_on(e, 1);
    if (e->idle_ms <= 0) return;
    for (int32_t i = 0; i < e->nconns; i++) {
        gs_net_conn *c = &e->conns[i];
        if (c->fd >= 0 && now - c->last_ms > e->idle_ms) gs_net_close_conn(e, c);
    }
}

/* Blocks until a connection has input, and appends all of it to buf: what
   the program handed back last time, then what the socket has. Its handle,
   or -1 if the engine is unknown or its poller failed. */
GS_API int64_t gs_net_wait(int64_t id, gs_rref buf) {
    gs_net_engine *e = gs_net_engine_of(id);
    if (!e) return -1;
    for (;;) {
        while (e->iev < e->nev) {
#if GS_NET_EPOLL
            struct epoll_event *ev = &e->evs[e->iev++];
            uint64_t tag = ev->data.u64;
            int readable = (ev->events & (EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR)) != 0;
            int writable = (ev->events & EPOLLOUT) != 0;
#else
            struct kevent *ev = &e->evs[e->iev++];
            uint64_t tag = (uint64_t)(uintptr_t)ev->udata;
            int readable = ev->filter == EVFILT_READ;
            int writable = ev->filter == EVFILT_WRITE;
#endif
            if (tag == GS_NET_LISTENER_TAG) {
                gs_net_accept(e);
                continue;
            }
            gs_net_conn *c = gs_net_conn_of(e, (int64_t)tag);
            if (!c) continue;   /* closed earlier in this batch */
            if (writable && gs_net_flush(e, c) < 0) continue;
            if (!readable || c->closing) continue;
            /* Read straight onto the builder, after the input kept from
               last time, until the program's need is met. */
            int64_t base = buf.hdr->len;
            uint8_t *top0 = buf.stk->top;
            gs_bld_append(buf, c->in, c->inlen);
            int64_t have = c->inlen, got = 0;
            int eof = 0;
            for (;;) {
                int64_t want = c->need > have ? c->need - have : 0;
                if (want < GS_NET_READ) want = GS_NET_READ;
                ssize_t n = read(c->fd, buf.stk->top, (size_t)want);
                if (n > 0) {
                    buf.stk->top += n;
                    buf.hdr->len += n;
                    have += n;
                    got += n;
                    /* A short read drained the socket; a big one may not
                       have, but a sender cannot hold the loop forever. */
                    if (have >= c->need && (n < want || got >= ((int64_t)1 << 22))) break;
                    continue;
                }
                if (n < 0 && errno == EINTR) continue;
                if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) eof = 1;
                break;
            }
            if (eof && !got) {
                buf.stk->top = top0;
                buf.hdr->len = base;
                gs_net_close_conn(e, c);
                continue;
            }
            /* Any byte that arrives is activity: a large body coming in
               pieces is not idle, though the program has not seen it. */
            if (got) c->last_ms = gs_net_now_ms();
            if (!got || have < c->need) {
                /* Not enough yet: keep it here, so the program does not
                   parse the same head again for each piece of a body. */
                int ok = 1;
                if (got) {
                    c->inlen = 0;
                    ok = gs_net_keep(&c->in, &c->inlen, &c->incap, top0, have);
                }
                buf.stk->top = top0;
                buf.hdr->len = base;
                if (!ok || eof) gs_net_close_conn(e, c);
                continue;
            }
            c->inlen = 0;
            c->need = 0;
            return (int64_t)tag;
        }
        int64_t now = gs_net_now_ms();
        if (now - e->last_sweep_ms >= 1000) gs_net_sweep(e, now);
#if GS_NET_EPOLL
        int n = epoll_wait(e->poll, e->evs, GS_NET_EVENTS, 1000);
#else
        struct timespec ts = { 1, 0 };
        int n = kevent(e->poll, NULL, 0, e->evs, GS_NET_EVENTS, &ts);
#endif
        if (n < 0 && errno != EINTR) return -1;
        e->nev = n < 0 ? 0 : n;
        e->iev = 0;
    }
}

/* Sends a then b (either may be empty) on a connection, in one writev
   when the socket takes it all, keeping what it does not take; false if
   the connection is gone. */
GS_API uint8_t gs_net_write(int64_t id, int64_t h, sl_u8 a, sl_u8 b) {
    gs_net_engine *e = gs_net_engine_of(id);
    gs_net_conn *c = e ? gs_net_conn_of(e, h) : NULL;
    if (!c) return 0;
    if (c->outlen == 0) {
        struct iovec iov[2];
        int n = 0;
        if (a.len > 0) { iov[n].iov_base = a.data; iov[n].iov_len = (size_t)a.len; n++; }
        if (b.len > 0) { iov[n].iov_base = b.data; iov[n].iov_len = (size_t)b.len; n++; }
        int64_t sent = 0;
        while (n > 0) {
            ssize_t w = writev(c->fd, iov, n);
            if (w < 0 && errno == EINTR) continue;
            if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            if (w < 0) {
                gs_net_close_conn(e, c);
                return 0;
            }
            sent += w;
            if (sent >= a.len + b.len) return 1;
            break;
        }
        if (sent < a.len) {
            if (!gs_net_keep(&c->out, &c->outlen, &c->outcap, a.data + sent, a.len - sent) ||
                !gs_net_keep(&c->out, &c->outlen, &c->outcap, b.data, b.len)) {
                gs_net_close_conn(e, c);
                return 0;
            }
        } else if (!gs_net_keep(&c->out, &c->outlen, &c->outcap, b.data + (sent - a.len),
                                b.len - (sent - a.len))) {
            gs_net_close_conn(e, c);
            return 0;
        }
        return gs_net_flush(e, c) >= 0;
    }
    if (!gs_net_keep(&c->out, &c->outlen, &c->outcap, a.data, a.len) ||
        !gs_net_keep(&c->out, &c->outlen, &c->outcap, b.data, b.len)) {
        gs_net_close_conn(e, c);
        return 0;
    }
    return 1;
}

/* Ends a delivery: rest is the input the program did not consume, kept for
   the next one, which waits until need bytes are buffered in all (0: any
   new input). close ends the connection once its output is written. */
GS_API void gs_net_done(int64_t id, int64_t h, sl_u8 rest, int64_t need, uint8_t close_) {
    gs_net_engine *e = gs_net_engine_of(id);
    gs_net_conn *c = e ? gs_net_conn_of(e, h) : NULL;
    if (!c) return;
    if (close_) {
        c->closing = 1;
        if (c->outoff >= c->outlen) gs_net_close_conn(e, c);
        return;
    }
    c->inlen = 0;
    if (rest.len > 0 && !gs_net_keep(&c->in, &c->inlen, &c->incap, rest.data, rest.len)) {
        gs_net_close_conn(e, c);
        return;
    }
    c->need = need > rest.len ? need : 0;
}

/* The connections an engine has open. */
GS_API int64_t gs_net_live(int64_t id) {
    gs_net_engine *e = gs_net_engine_of(id);
    return e ? e->live : -1;
}

GS_API void gs_net_close(int64_t id) {
    gs_net_engine *e = gs_net_engine_of(id);
    if (!e) return;
    for (int32_t i = 0; i < e->nconns; i++) gs_net_close_conn(e, &e->conns[i]);
    close(e->poll);
    free(e->conns);
    pthread_mutex_lock(&gs_net_mutex);
    gs_net_engines[id] = NULL;
    pthread_mutex_unlock(&gs_net_mutex);
    free(e);
}

/* ---------------------------------------------------------------------------
   A blocking client, for tests and tools: connect, send, receive, close. */

/* A connected socket, or -1. A send or receive that waits timeout_ms
   (0: forever) fails. */
GS_API int64_t gs_net_connect(sl_u8 host, int64_t port, int64_t timeout_ms) {
    char h[256], portstr[16];
    struct addrinfo hints, *res = NULL, *ai;
    int fd = -1, one = 1;
    if (gs_net_cstr(host, h, sizeof(h)) < 0 || port <= 0 || port > 65535) return -1;
#ifdef SIGPIPE
    signal(SIGPIPE, SIG_IGN);
#endif
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portstr, sizeof(portstr), "%lld", (long long)port);
    if (getaddrinfo(h, portstr, &hints, &res) != 0) return -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) {
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        if (timeout_ms > 0) {
            struct timeval tv;
            tv.tv_sec = (time_t)(timeout_ms / 1000);
            tv.tv_usec = (suseconds_t)(timeout_ms % 1000) * 1000;
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        }
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    }
    return fd;
}

GS_API uint8_t gs_net_send(int64_t fd, sl_u8 data) {
    int64_t at = 0;
    while (at < data.len) {
        ssize_t n = send((int)fd, data.data + at, (size_t)(data.len - at),
#ifdef MSG_NOSIGNAL
                         MSG_NOSIGNAL
#else
                         0
#endif
        );
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        at += n;
    }
    return 1;
}

/* Appends what one read gets, at most max bytes: their count, 0 at the end
   of the stream, -1 on an error. */
GS_API int64_t gs_net_recv(int64_t fd, gs_rref out, int64_t max) {
    if (max <= 0) return 0;
    for (;;) {
        ssize_t n = recv((int)fd, out.stk->top, (size_t)max, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n > 0) {
            out.stk->top += n;
            out.hdr->len += n;
        }
        return n;
    }
}

GS_API void gs_net_close_fd(int64_t fd) {
    if (fd >= 0) close((int)fd);
}

#else  /* _WIN32: not yet */

GS_API int64_t gs_net_listen(sl_u8 host, int64_t port, int64_t backlog) { return -1; }
GS_API int64_t gs_net_port(int64_t fd) { return -1; }
GS_API int64_t gs_net_open(int64_t lfd, int64_t idle_ms) { return -1; }
GS_API int64_t gs_net_wait(int64_t id, gs_rref buf) { return -1; }
GS_API uint8_t gs_net_write(int64_t id, int64_t h, sl_u8 a, sl_u8 b) { return 0; }
GS_API void gs_net_done(int64_t id, int64_t h, sl_u8 rest, int64_t need, uint8_t close_) {}
GS_API int64_t gs_net_live(int64_t id) { return -1; }
GS_API void gs_net_close(int64_t id) {}
/* A connected socket, or -1. A send or receive that waits timeout_ms
   (0: forever) fails. */
GS_API int64_t gs_net_connect(sl_u8 host, int64_t port, int64_t timeout_ms) { return -1; }
GS_API uint8_t gs_net_send(int64_t fd, sl_u8 data) { return 0; }
GS_API int64_t gs_net_recv(int64_t fd, gs_rref out, int64_t max) { return -1; }
GS_API void gs_net_close_fd(int64_t fd) {}

#endif

/* The current time as an HTTP date (IMF-fixdate, 29 bytes) in out, which
   must hold 29; the count written, or 0. Formatted once a second per
   thread. */
GS_API int64_t gs_net_date(sl_u8 out) {
    static GS_TLS time_t last;
    static GS_TLS char text[32];
    static const char days[] = "SunMonTueWedThuFriSat";
    static const char months[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
    if (out.len < 29) return 0;
    time_t now = time(NULL);
    if (now != last) {
        struct tm tm;
#ifdef _WIN32
        gmtime_s(&tm, &now);
#else
        gmtime_r(&now, &tm);
#endif
        snprintf(text, sizeof(text), "%.3s, %02d %.3s %04d %02d:%02d:%02d GMT",
                 days + 3 * tm.tm_wday, tm.tm_mday, months + 3 * tm.tm_mon, tm.tm_year + 1900,
                 tm.tm_hour, tm.tm_min, tm.tm_sec);
        last = now;
    }
    memcpy(out.data, text, 29);
    return 29;
}
