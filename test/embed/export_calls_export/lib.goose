// An export calling another from Goose is an ordinary Goose call, not a
// re-entry, from another export and from fn main() under goose_init alike.
var calls: i64 = 0;

export fn square(n: i64) -> i64 {
    calls += 1;
    n * n
}

export fn sum_squares(n: i64) -> i64 {
    var s = 0;
    for i in 0..n { s += square(i); }
    s
}

export fn calls_made() -> i64 { calls }

fn main() { print("main: square(7) = ", square(7)); }
