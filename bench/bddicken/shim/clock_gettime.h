/* clock_gettime(CLOCK_MONOTONIC) for the reference C runner (lib/c/benchmark.c)
   on Windows, whose C library has no clock_gettime: compare.py builds the C
   versions with -include of this file. It also keeps the C library from
   defining the min and max macros, which levenshtein.c's own min collides
   with. */
#ifndef BDDICKEN_CLOCK_GETTIME_H
#define BDDICKEN_CLOCK_GETTIME_H
#ifdef _WIN32
#define _CRT_DECLARE_NONSTDC_NAMES 0
#include <stdint.h>
#include <time.h>

#define CLOCK_MONOTONIC 1

__declspec(dllimport) int __stdcall QueryPerformanceCounter(int64_t *count);
__declspec(dllimport) int __stdcall QueryPerformanceFrequency(int64_t *freq);

static int clock_gettime(int clock_id, struct timespec *ts) {
    (void)clock_id;
    int64_t count, freq;
    QueryPerformanceCounter(&count);
    QueryPerformanceFrequency(&freq);
    ts->tv_sec = (time_t)(count / freq);
    ts->tv_nsec = (long)((count % freq) * 1000000000 / freq);
    return 0;
}

#define strdup _strdup
#endif
#endif
