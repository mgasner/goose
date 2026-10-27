/* Forced into every reference C and C++ program on Windows: the POSIX names
   they use that the Windows C library spells differently. */
#pragma once
#define _USE_MATH_DEFINES
#include <math.h>
#include <malloc.h>
#include <stdlib.h>
static inline void *memalign(size_t align, size_t n) { return _aligned_malloc(n, align); }
