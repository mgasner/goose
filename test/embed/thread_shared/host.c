#include <stdio.h>
#include "lib.h"
#include "host_thread.h"

static void other(void) {
    printf("thread: calling inner(3)\n");
    printf("thread: inner(3) = %lld (should have aborted)\n", (long long)inner(3));
}

int main(int argc, char **argv) {
    goose_init(argc, argv);
    printf("main: inner(3) = %lld, total = %lld\n", (long long)inner(3),
           (long long)get_total());
    fflush(stdout);
    run_on_host_thread(other);
    printf("main: total = %lld (should have aborted)\n", (long long)get_total());
    return 0;
}
