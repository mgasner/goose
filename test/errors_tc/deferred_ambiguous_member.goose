// error: more than one function show can be stored as Job with 1 stored argument(s)
deferred Job(now: i64);
fn show(x: i64, now: i64) { print(x, now); }
fn show(x: f64, now: i64) { print(x, now); }
fn main() { let j = Job(show, 1); j(2); }
