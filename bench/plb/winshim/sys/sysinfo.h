/* get_nprocs, for the reference programs that size their thread pools by it. */
#pragma once
#include <windows.h>
static inline int get_nprocs(void) {
    DWORD_PTR proc, sys;
    GetProcessAffinityMask(GetCurrentProcess(), &proc, &sys);
    return __builtin_popcountll(proc);
}
