/* The POSIX calls the C tests of kostya/benchmarks make, for building them
   on Windows (bench/kostya2/compare.py). Files open in binary mode, as they
   do on POSIX. */
#pragma once
#include <io.h>
#include <fcntl.h>
#include <process.h>
#define open(path, flags) _open(path, (flags) | _O_BINARY)
#define read _read
#define close _close
#define getpid _getpid
