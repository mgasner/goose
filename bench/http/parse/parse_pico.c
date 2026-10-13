// Suite P's baseline (bench/http/design.md): picohttpparser doing what
// parse.goose does to each request -- parse it, find the headers framing
// depends on, and frame (and for chunked bodies, decode) the body -- with
// the same command line, output and checksum.
//
//   parse_pico <corpus> <seq|fresh|prefix> <target_ns> <batches>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "picohttpparser.h"

#define MAX_HEADERS 64

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int same_ci(const char *a, size_t n, const char *lower, size_t ln) {
    if (n != ln) return 0;
    for (size_t i = 0; i < n; i++)
        if ((a[i] | 0x20) != lower[i]) return 0;
    return 1;
}

static int has_token_ci(const char *v, size_t n, const char *lower, size_t ln) {
    size_t i = 0;
    while (i <= n) {
        size_t e = i;
        while (e < n && v[e] != ',') e++;
        size_t a = i, b = e;
        while (a < b && (v[a] == ' ' || v[a] == '\t')) a++;
        while (b > a && (v[b - 1] == ' ' || v[b - 1] == '\t')) b--;
        if (same_ci(v + a, b - a, lower, ln)) return 1;
        i = e + 1;
    }
    return 0;
}

// One request at buf: its length, 0 if incomplete, -1 if malformed; the
// checksum term in *check.
static long parse_one(char *buf, size_t len, int64_t *check, int64_t *need) {
    const char *method, *path;
    size_t mlen, plen, nh = MAX_HEADERS;
    int minor;
    struct phr_header hs[MAX_HEADERS];
    int r = phr_parse_request(buf, len, &method, &mlen, &path, &plen, &minor, hs, &nh, 0);
    if (r == -2) return 0;
    if (r < 0) return -1;
    long long clen = -1;
    int chunked = 0, conn_close = 0, conn_keep = 0, expect = 0;
    for (size_t i = 0; i < nh; i++) {
        const char *n = hs[i].name;
        size_t nl = hs[i].name_len;
        if (nl == 14 && same_ci(n, nl, "content-length", 14)) {
            long long v = 0;
            if (hs[i].value_len == 0 || hs[i].value_len > 18) return -1;
            for (size_t k = 0; k < hs[i].value_len; k++) {
                char c = hs[i].value[k];
                if (c < '0' || c > '9') return -1;
                v = v * 10 + (c - '0');
            }
            if (clen >= 0 && clen != v) return -1;
            clen = v;
        } else if (nl == 17 && same_ci(n, nl, "transfer-encoding", 17)) {
            if (!same_ci(hs[i].value, hs[i].value_len, "chunked", 7)) return -1;
            chunked = 1;
        } else if (nl == 10 && same_ci(n, nl, "connection", 10)) {
            if (has_token_ci(hs[i].value, hs[i].value_len, "close", 5)) conn_close = 1;
            if (has_token_ci(hs[i].value, hs[i].value_len, "keep-alive", 10)) conn_keep = 1;
        } else if (nl == 6 && same_ci(n, nl, "expect", 6)) {
            expect = same_ci(hs[i].value, hs[i].value_len, "100-continue", 12);
        }
    }
    (void)conn_close;
    (void)conn_keep;
    (void)expect;
    size_t blen;
    long total;
    if (chunked) {
        if (clen >= 0) return -1;
        struct phr_chunked_decoder d;
        memset(&d, 0, sizeof(d));
        d.consume_trailer = 1;
        size_t sz = len - (size_t)r;
        ssize_t rest = phr_decode_chunked(&d, buf + r, &sz);
        if (rest == -2) return 0;
        if (rest < 0) return -1;
        blen = sz;
        // What the decoder left undecoded follows the decoded body.
        total = (long)(len - (size_t)rest);
    } else {
        if (clen < 0) clen = 0;
        if (len - (size_t)r < (size_t)clen) {
            *need = r + clen;
            return 0;
        }
        blen = (size_t)clen;
        total = r + (long)clen;
    }
    *check += (int64_t)(mlen + plen + 3 * nh + blen) + total;
    return total;
}

static char *text, *work;
static size_t textlen;
static int mode;   // 0 seq, 1 fresh, 2 prefix

static int64_t run(int64_t reps, int64_t *check) {
    int64_t units = 0;
    *check = 0;
    if (mode == 2) {
        int64_t c = 0, need = 0;
        long whole = parse_one(work, textlen, &c, &need);
        for (int64_t r = 0; r < reps; r++)
            for (long len = 1; len < whole; len++) {
                need = 0;
                long n = parse_one(work, (size_t)len, &c, &need);
                if (n != 0) {
                    printf("prefix of %ld bytes parsed as %ld\n", len, n);
                    exit(1);
                }
                *check += need + 1;
                units++;
            }
        return units;
    }
    for (int64_t r = 0; r < reps; r++) {
        if (mode == 1) memcpy(work, text, textlen);
        size_t at = 0;
        while (at < textlen) {
            int64_t need = 0;
            long n = parse_one(work + at, textlen - at, check, &need);
            if (n <= 0) {
                printf("parse failed at byte %zu: %ld\n", at, n);
                exit(1);
            }
            at += (size_t)n;
            units++;
        }
    }
    return units;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: parse_pico <corpus> <seq|fresh|prefix> <target_ns> <batches>\n");
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;
    fseek(f, 0, SEEK_END);
    textlen = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    text = malloc(textlen + 1);
    work = malloc(textlen + 1);
    if (fread(text, 1, textlen, f) != textlen) return 1;
    fclose(f);
    memcpy(work, text, textlen);
    mode = !strcmp(argv[2], "fresh") ? 1 : !strcmp(argv[2], "prefix") ? 2 : 0;
    int64_t target = atoll(argv[3]), batches = atoll(argv[4]), sink = 0, c;

    int64_t u1 = run(1, &c);
    printf("check %lld units %lld\n", (long long)c, (long long)u1);
    int64_t w0 = now_ns();
    for (int i = 0; i < 50 && now_ns() - w0 < target / 4; i++) {
        run(1, &c);
        sink += c;
    }
    int64_t reps = 1;
    for (;;) {
        int64_t t = now_ns();
        run(reps, &c);
        sink += c;
        if (now_ns() - t >= target) break;
        reps *= 2;
    }
    for (int64_t b = 0; b < batches; b++) {
        int64_t t = now_ns();
        int64_t u = run(reps, &c);
        int64_t dt = now_ns() - t;
        sink += c;
        printf("batch units=%lld ns=%lld\n", (long long)u, (long long)dt);
    }
    printf("sink %lld\n", (long long)(sink % 7));
    return 0;
}
