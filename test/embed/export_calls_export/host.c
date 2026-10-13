#include <stdio.h>
#include "lib.h"

int main(int argc, char **argv) {
    goose_init(argc, argv);
    fflush(stdout);
    printf("sum_squares(4) = %lld\n", (long long)sum_squares(4));
    printf("square(3) = %lld\n", (long long)square(3));
    printf("calls_made = %lld\n", (long long)calls_made());
    return 0;
}
