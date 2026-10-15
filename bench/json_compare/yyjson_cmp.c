// yyjson (bench/json/third_party/yyjson.c) on the json_compare tasks, for
// scale: `yyjson_cmp <task> <file> <reps>`, the same output as the Goose
// programs. Tasks: parse, kostya_dom, write (a parsed document, minified),
// read. yyjson has no streaming reader, so there is no kostya_stream.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../json/third_party/yyjson.h"

static long long now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void kostya(const char *buf, size_t len, double *ax, double *ay, double *az) {
    yyjson_doc *d = yyjson_read(buf, len, 0);
    if (!d) { fprintf(stderr, "parse failed\n"); exit(1); }
    yyjson_val *coords = yyjson_obj_get(yyjson_doc_get_root(d), "coordinates");
    double x = 0, y = 0, z = 0;
    size_t i, m; yyjson_val *c;
    yyjson_arr_foreach(coords, i, m, c) {
        x += yyjson_get_num(yyjson_obj_get(c, "x"));
        y += yyjson_get_num(yyjson_obj_get(c, "y"));
        z += yyjson_get_num(yyjson_obj_get(c, "z"));
    }
    double n = (double)yyjson_arr_size(coords);
    *ax = x / n; *ay = y / n; *az = z / n;
    yyjson_doc_free(d);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: yyjson_cmp task file reps\n"); return 2; }
    const char *task = argv[1];
    FILE *f = fopen(argv[2], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(len); fread(buf, 1, len, f); fclose(f);
    int reps = atoi(argv[3]);
    yyjson_doc *pre = strcmp(task, "write") == 0 ? yyjson_read(buf, len, 0) : NULL;
    double sink = 0; size_t outlen = 0;
    printf("ns=");
    for (int r = 0; r <= reps; r++) {
        long long t0 = now_ns();
        if (!strcmp(task, "parse")) {
            yyjson_doc *d = yyjson_read(buf, len, 0);
            if (!d) { fprintf(stderr, "parse failed\n"); return 1; }
            sink += yyjson_doc_get_val_count(d);
            yyjson_doc_free(d);
        } else if (!strcmp(task, "kostya_dom")) {
            double x, y, z; kostya(buf, len, &x, &y, &z);
            sink += x + y + z;
            if (r == 0) fprintf(stderr, "avg=%.17g %.17g %.17g\n", x, y, z);
        } else if (!strcmp(task, "write")) {
            char *out = yyjson_write(pre, 0, &outlen);
            free(out);
        } else if (!strcmp(task, "read")) {
            sink += len;
        } else { fprintf(stderr, "unknown task %s\n", task); return 2; }
        long long t1 = now_ns();
        if (r > 0) printf(r > 1 ? ",%lld" : "%lld", t1 - t0);
    }
    printf("\nbytes=%ld outbytes=%zu sink=%g\n", len, outlen, sink);
    return 0;
}
