# Calling Goose from C: reentrancy and threads

A program built with `--header` is a C library (spec §7.11). The host calls
`goose_init` once and then the exported functions. Two common host patterns
are broken today, silently: a C callback that calls back into Goose while a
Goose call is still running, and a call from a thread other than the one
that called `goose_init`. This plan makes both fail loudly first (phase 1),
then supports callbacks (phase 2) and many-threaded hosts (phase 3).

## What goes wrong today

Cases 1 to 3 were reproduced with `goose --standalone --header` and a
small C host on macOS (arm64); case 4 is read from the runtime source.
Appendix A has the sources.

### 1. A re-entered export overwrites the outer call's data

Every exported wrapper enters Goose at stack index 0:

```c
int64_t outer(int64_t gs_export_arg0) {
    ...
    return outer_g(gs_export_arg0, 0);    /* gs_sp = 0 */
}
```

`gs_sp` is the base of the caller's data stacks (Appendix C). A Goose
function keeps a stack's top in a C local while a resizable grows, and
writes it back to `GS(i)->top` only when it no longer needs it. Where a
resizable is pushed both before and after an `extern` call, the cached top
lives across the call. So when C calls an export from inside that `extern`:

* the inner call starts at `gs_sp = 0`, on the same stacks as the outer one;
* `GS(0)->top` still says the outer call's resizable is empty, so the inner
  call allocates over it.

`outer(5)` pushes 0..4 into a local `buf`, calls C, which calls `inner(5)`,
which pushes 1000..1004 into its own local; `outer` then pushes 100 and sums
`buf`. It returns **5110, not 110**. Nothing aborts.

### 2. Bounds proofs survive a callback that changes a global

§7.10 lets the compiler assume an `extern` call "does not mutate unrelated
Goose globals". A callback into an export can mutate any of them.

```goose
var g: i64[>..] = [];
export fn shrink(n: i64) -> i64 { g.clear(); return 0; }
export fn outer(n: i64) -> i64 {
    for i in 0..5 { g.push(i + 1); }
    host_callback(n);            // C calls shrink(): g is empty
    return g[4];                 // must abort
}
```

At `-O2`, BCE elides the check on `g[4]` (`elided 1/1`), and `outer`
returns 5 from cleared memory. This is the most serious case: a safety
check the program relies on is removed. The lifetime checker has the
same exposure: a slice of a global taken before such a call is still
trusted after it.

### 3. A call from another thread races or crashes

§7.11 says exported calls "must remain on" the thread that called
`goose_init`, but nothing enforces it, and what happens depends on whether
the library uses threads:

* **No `thread_spawn` anywhere** (`GS_NEED_THREADS` is 0): `GS_TLS` is
  empty, so the stack block (`gs_stks`), the globals pointer and the stacks
  of global resizables are process-wide statics. A second thread silently
  shares main's stacks and globals. That is a data race whenever calls
  overlap; in the repro, sequential calls from two threads see one
  `total` counter.
* **With threads:** that state is thread-local. A foreign thread passes
  the `goose_init` check (`gs_program_initialized` is a plain static), and
  then indexes a NULL `gs_stks`: **segfault** (exit 139).

### 4. Every runtime error ends the host

`gs_abort`, `gs_abort_msg` and `gs_panic` print and call `exit(1)`. For a
library that takes the host process with it, with no chance to log or
shut down. This is less a bug than a missing piece of the C boundary, but
it belongs with the rest.

## Phase 1: fail loudly

Make every case above a clear runtime error, without supporting any of
them yet. Self-contained, and closes the soundness hole in case 2.

* **Re-entry guard.** A thread-local `gs_export_depth`. Each exported
  wrapper increments it on entry and decrements it on return; entering
  with it already above 0 aborts:
  `goose runtime error: exported function inner re-entered from C while
  outer is running`. Naming both needs a thread-local "current export",
  which is one pointer store per call.
  Note that `goose_init` runs the Goose `fn main()`, which may itself call
  `extern` functions; a callback from there is the same re-entry and is
  caught the same way.
* **Thread guard.** `goose_init` records its thread (a thread-local flag
  set on the initializing thread is enough, and portable). Each wrapper
  checks it and aborts on any other thread: `goose runtime error: exported
  function inner called from a thread that did not call goose_init`.
  The guard variables are thread-local even when `GS_NEED_THREADS` is 0.
  So `GS_TLS` stays as it is, and the two guards use their own
  always-thread-local declaration. The runtime already has the
  `__thread` / `__declspec(thread)` selection; whether a library without
  threads then needs anything more at link time has to be checked.
* **Where.** The wrappers are emitted in codegen next to the existing
  `goose_init must be called` check; the guards go there. A
  `return ... from` or runtime abort never returns through the wrapper,
  and an abort ends the process anyway, so the decrement only has to be
  on the normal return path.
* **Cost.** Two thread-local reads, one compare-and-branch each, and an
  increment/decrement per exported call. No change to Goose-internal
  calls.
* **JIT.** `--jit` runs `fn main()` in-process and has no C host, but
  TinyCC must still compile the wrappers; check its `__thread` support
  in the JIT runtime path, or emit the guards only under `--header`.
* **Spec.** §7.11 says re-entry and foreign-thread calls abort, rather
  than that they "must" not happen.

**Tests.** There is no test today that links a C host against a
`--header` library (`test/codegen/export.goose` checks the generated C
only). Phase 1 adds one: `test/embed/<name>/lib.goose` plus `host.c` and
an expected output, built with `--standalone --header`, compiled with the
system C compiler, and run, at -O0 and -O2. Cases:

* the four repros of Appendix A, now aborting with their messages (an
  abort test expects the message on stderr and a nonzero exit);
* calls in sequence from the init thread, and an export calling another
  export *from Goose* (an ordinary Goose call, not re-entry), still work;
* `goose_init` called twice, and an export before `goose_init`, unchanged.

## Phase 2: support callbacks, opt in per extern

Callbacks are the reason hosts re-enter; phase 2 makes them work where
the program says they can happen.

* **Syntax.** An `extern` that may call back into Goose says so:
  `extern fn host_callback(n: i64) reenters;` (or an attribute; see open
  questions). An unmarked `extern` keeps today's assumption, enforced by
  phase 1's guard.
* **Stacks.** At a call to a marked extern, the caller writes back every
  cached stack top before the call and reloads them after, and stores
  the first stack index it does not use (`gs_sp` + its frame's count) in
  a thread-local `gs_reenter_sp`. A wrapper entered at depth > 0 starts
  at `gs_reenter_sp` instead of 0. The re-entered call is then an
  ordinary callee as far as the stacks are concerned.
* **Globals and BCE.** A marked call is treated as a call that may run
  any export: its effect summary is the union of the exports' summaries
  (which globals they write, grow or shrink). BCE facts and lifetime
  facts that depend on those globals end at the call, the same way the
  checker treats an ordinary call that may shrink an array. An export
  that writes no globals costs its callers nothing.
* **Guard.** Phase 1's depth guard still runs, but allows depth > 0 when
  the innermost Goose frame is at a marked call (a thread-local flag set
  around marked calls).
* **Cost** is on marked call sites only: the write-backs and reloads, and
  whatever facts the summary ends.

## Phase 3: hosts with many threads

* `goose_thread_init()` gives the calling host thread its own program
  instance: a stack block and a copy of main's globals, exactly as a
  `thread_fn` worker gets at spawn (§11.2), with the same rule that every
  global the exports reach must be flat. `goose_thread_exit()` releases
  it, as a worker's return does. Exports then work on any thread that has
  called `goose_thread_init`, and each thread's globals are its own.
* The typed queues already work across instances, so host threads can
  talk to each other, and to `thread_spawn` workers, through `qput`/`qget`.
* An optional `goose_set_abort_handler(void (*)(const char *msg))` lets a
  host log and shut down. The handler must not return into Goose; after
  it returns, the runtime exits as today.

## Open questions

1. **Re-entry today.** Some hosts may re-enter already and get away with
   it: a callback whose export uses no data stack and no global the outer
   call has cached is unaffected by cases 1 and 2. Phase 1 makes those
   abort. The alternative is to skip phase 1's re-entry guard and go
   straight to phase 2, at the cost of leaving case 2 open meanwhile.
2. **Syntax for phase 2.** A trailing keyword (`reenters`), an attribute,
   or marking the *export* (`export reentrant fn`) instead of the extern.
   Marking the extern is more precise: the caller is what needs to know.
3. **Abort handler and `longjmp`.** A handler that `longjmp`s out of
   Goose would leave the data stacks with stale tops. If wanted, the
   runtime could reset the calling thread's stacks before calling the
   handler, but that is not in this plan.

## Appendix A. Reproductions

Each is `lib.goose` + `host.c`, built with:

```
goose --standalone --header lib.h -O2 -o lib.c lib.goose
cc -O2 lib.c host.c -o host -lpthread -lm
```

**Case 1: re-entry overwrites a local resizable.**

```goose
extern fn host_callback(n: i64);
var total: i64 = 0;

export fn inner(n: i64) -> i64 {
    var tmp: i64[>..] = [];
    for i in 0..n { tmp.push(1000 + i); }
    var s = 0;
    for v in tmp { s += v; }
    total += 1;
    return s;
}

export fn outer(n: i64) -> i64 {
    var buf: i64[>..] = [];
    for i in 0..n { buf.push(i); }
    host_callback(n);
    buf.push(100);
    var s = 0;
    for v in buf { s += v; }
    return s;                    // 110; returns 5110
}

export fn get_total() -> i64 { total }
```

```c
#include <stdio.h>
#include <pthread.h>
#include "lib.h"
void host_callback(int64_t n) { printf("  inner(%lld) = %lld\n", (long long)n, (long long)inner(n)); }
static void *other(void *p) { (void)p; printf("thread: inner(3) = %lld, total = %lld\n",
                                               (long long)inner(3), (long long)get_total()); return 0; }
int main(int argc, char **argv) {
    goose_init(argc, argv);
    printf("outer(5) = %lld (expected 110)\n", (long long)outer(5));
    if (argc > 1) { pthread_t t; pthread_create(&t, 0, other, 0); pthread_join(t, 0); }
    printf("main: total = %lld\n", (long long)get_total());
    return 0;
}
```

**Case 3, shared state:** the same, run as `./host thread`. The thread
shares main's `total` (main prints 2).

**Case 3, crash:** the same library with a thread in it, e.g.

```goose
thread_fn noop() { }
export fn spawn_one() { thread_wait(thread_spawn(noop)); }
```

added, run as `./host thread`: segfault in the thread's `inner(3)`.

**Case 2: an elided bounds check.** The library in §2 above, with:

```c
#include <stdio.h>
#include "lib.h"
void host_callback(int64_t n) { shrink(n); }
int main(int argc, char **argv) {
    goose_init(argc, argv);
    printf("outer = %lld (should have aborted)\n", (long long)outer(0));
    return 0;
}
```

prints `outer = 5`.
