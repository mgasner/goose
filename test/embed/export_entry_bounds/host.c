#include <stdio.h>
#include "lib.h"

int main(int argc, char **argv) {
    int32_t xs[1] = { 7 };
    sl_i32 dist = { xs, 1 };
    goose_init(argc, argv);
    printf("%d\n", (int)c_pick(dist, 0));
    fflush(stdout);
    printf("%d (should have aborted)\n", (int)c_pick(dist, 1));
    return 0;
}
