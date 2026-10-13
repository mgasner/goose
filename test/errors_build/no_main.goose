// error: program needs exactly one global fn main()
// A library's root file, which imports its parts and has no fn main(): a
// check accepts it, checking the functions no call reaches on their own, as
// it does in a program, while a build still needs the entry point.
namespace lib;
import .no_main.part;

fn sum_of(p: Pair) -> i64 { return p.a + p.b; }

fn record(p: Pair) -> bool {
    return guarded(sum_of(p));
}
