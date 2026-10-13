// Times yyjson on one file, best of `reps`: parse (DOM), parse + walk, and
// write (minified), each in MB/s; write per byte of output, as json_bench.
// Usage: yyjson_bench file.json reps
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../third_party/yyjson.h"

static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

// Visits every value and reads every scalar, as json_bench's walk does.
static long walk(yyjson_val *v) {
    long n = 1;
    if (yyjson_is_arr(v)) { size_t i, m; yyjson_val *e; yyjson_arr_foreach(v, i, m, e) n += walk(e); }
    else if (yyjson_is_obj(v)) { size_t i, m; yyjson_val *k, *e; yyjson_obj_foreach(v, i, m, k, e) n += walk(e); }
    else if (yyjson_is_str(v)) n += (long)yyjson_get_len(v);
    else if (yyjson_is_num(v)) n += (long)yyjson_get_num(v);
    return n;
}

int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(len); fread(buf, 1, len, f); fclose(f);
    int reps = atoi(argv[2]);
    double best_parse = 1e9, best_walk = 1e9, best_write = 1e9; long nodes = 0; size_t outlen = 0;
    for (int r = 0; r < reps; r++) {
        double t0 = now();
        yyjson_doc *d = yyjson_read(buf, len, 0);
        double t1 = now();
        nodes = walk(yyjson_doc_get_root(d));
        double t2 = now();
        char *out = yyjson_write(d, 0, &outlen);
        double t3 = now();
        free(out);
        yyjson_doc_free(d);
        if (t1 - t0 < best_parse) best_parse = t1 - t0;
        if (t2 - t1 < best_walk) best_walk = t2 - t1;
        if (t3 - t2 < best_write) best_write = t3 - t2;
    }
    printf("bytes=%ld parse=%.0f walk=%.0f write=%.0f\n", len, len / best_parse / 1e6,
           len / (best_parse + best_walk) / 1e6, outlen / best_write / 1e6);
}
