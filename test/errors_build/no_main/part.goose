// A part of the no_main.goose module, named by the root's import.
namespace lib;

struct Pair { a: i64, b: i64 }

var written: i64[>..];

// Leaves the guarded() call it runs under when n is negative.
fn emit(n: i64) {
    if n < 0 { return false from guarded; }
    written.push(n);
}

fn guarded(n: i64) -> bool {
    emit(n);
    return true;
}

// Reaches a `return ... from guarded` that no call of guarded encloses:
// nothing calls it, so the check leaves it for the calls that would.
fn emit_twice(n: i64) {
    emit(n);
    emit(n + 1);
}
