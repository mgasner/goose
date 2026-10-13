#include <stdio.h>
#include "lib.h"

int main(int argc, char **argv) {
    goose_init(argc, argv);
    goose_init(argc, argv);
    fflush(stdout);
    printf("init_count = %lld\n", (long long)init_count());
    return 0;
}
