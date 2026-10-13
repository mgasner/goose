#include <stdio.h>
#include "lib.h"

void host_callback(int64_t n) {
    printf("callback: calling inner(%lld)\n", (long long)n);
    printf("inner = %lld (should have aborted)\n", (long long)inner(n));
}

int main(int argc, char **argv) {
    goose_init(argc, argv);
    printf("outer(5) = %lld (should have aborted)\n", (long long)outer(5));
    return 0;
}
