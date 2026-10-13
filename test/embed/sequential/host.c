#include <stdio.h>
#include "lib.h"

void host_note(int64_t n) { printf("  note: %lld element(s)\n", (long long)n); }

int main(int argc, char **argv) {
    int64_t len;
    const uint8_t *s;
    int i;
    goose_init(argc, argv);
    for (i = 1; i <= 3; i++) printf("add(%d) = %lld\n", i, (long long)add(i));
    printf("count = %lld\n", (long long)count());
    s = c_greeting(&len);
    printf("%.*s\n", (int)len, (const char *)s);
    reset();
    printf("after reset: add(4) = %lld\n", (long long)add(4));
    printf("count = %lld\n", (long long)count());
    return 0;
}
