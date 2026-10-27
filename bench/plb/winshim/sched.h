/* What the reference C and C++ programs use of Linux's sched.h, on Windows:
   every CPU of this process's affinity mask. */
#pragma once
#include <windows.h>
typedef struct { unsigned long long bits; } cpu_set_t;
#define CPU_ZERO(s) ((s)->bits = 0)
#define CPU_SET(i, s) ((s)->bits |= 1ull << (i))
#define CPU_ISSET(i, s) (((s)->bits >> (i)) & 1)
#define CPU_COUNT(s) __builtin_popcountll((s)->bits)
#define CPU_SETSIZE 64
static inline int sched_getaffinity(int pid, size_t n, cpu_set_t *s) {
    DWORD_PTR proc, sys;
    (void)pid; (void)n;
    GetProcessAffinityMask(GetCurrentProcess(), &proc, &sys);
    s->bits = proc;
    return 0;
}
