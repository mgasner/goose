#include <stdio.h>
#include "lib.h"

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    printf("calling answer before goose_init\n");
    printf("answer = %lld (should have aborted)\n", (long long)answer());
    return 0;
}
