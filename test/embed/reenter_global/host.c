#include <stdio.h>
#include "lib.h"

void host_callback(int64_t n) {
    printf("callback: calling shrink\n");
    shrink(n);
}

int main(int argc, char **argv) {
    goose_init(argc, argv);
    printf("outer = %lld (should have aborted)\n", (long long)outer(0));
    return 0;
}
