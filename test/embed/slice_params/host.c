#include <stdio.h>
#include "lib.h"

int main(int argc, char **argv) {
    int64_t xs[4] = { 3, 1, 4, 1 };
    sl_i64 all = { xs, 4 }, mid = { xs + 1, 2 };
    goose_init(argc, argv);
    printf("%lld %lld\n", (long long)c_weigh(all, 1), (long long)c_weigh(mid, 0));
    return 0;
}
