#include <stdio.h>
#include "lib.h"

void host_callback(void) {
    fflush(stdout);
    printf("callback: calling ping\n");
    printf("ping = %lld (should have aborted)\n", (long long)ping());
}

int main(int argc, char **argv) {
    goose_init(argc, argv);
    printf("goose_init returned (should have aborted)\n");
    return 0;
}
