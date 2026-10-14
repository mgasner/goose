# TinyCC

The sources of the Tiny C Compiler that `cmake/libtcc.cmake` builds into the
compiler as its in-process C backend (`docs/design/jit_backend.md`), copied
from [TinyCC/tinycc](https://github.com/TinyCC/tinycc) at commit
`0fb54300b56512754221d80adda85ddb9815bceb` (2026-09-04, `release_0_9_26-2610`):
the `.c`, `.h` and `.def` files of the repository root, `include/`, `lib/`,
`win32/include/` and `win32/lib/`, with `VERSION`, `COPYING`, `RELICENSING`
and upstream's `README`. Its tests, examples, documentation and build scripts
are left out; the CMake file replaces its configure and makefile.

The backend is not optional: every Goose compiler is built with it.

License: LGPL 2.1 (`COPYING`), with the relicensing notes in `RELICENSING`.

Local changes:

- `arm64-gen.c`: use Apple's natural stack size and alignment for fixed
  floating-point arguments, including homogeneous float aggregates. This
  fixes a trailing float being passed at offset 16 instead of 12 after a
  spilled three-float struct. Variadic arguments retain eight-byte slots.
  `test/packages/pkg_float_abi.goose` checks calls into native C through the
  in-process backend as well as native builds.
- `arm64-gen.c`, Linux: `va_arg` once an argument did not fit in the
  registers left of its class. AAPCS64 then has every later argument of the
  class on the stack, but `gen_va_arg` (for a variadic argument) and
  `gfunc_prolog` (for a named one, through `va_start`) still let a later
  small one be read from a leftover register. This is
  https://github.com/mgasner/tinycc/commit/2fdc42ee597bc4aaf53f5b3ad1efee9c64d51db1,
  which has tests for TinyCC's `tests/abitest.c` and is not upstream yet.

To update, copy the same files from a newer TinyCC commit and record that
commit here. Preserve the local changes until they are included upstream.
