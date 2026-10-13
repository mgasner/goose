// error: show cannot be stored as Job: it must declare 1 result(s), as Job does
deferred Job(now: i64) -> bool;
fn show(x: i64, now: i64) { print(x, now); }
fn main() { let j = Job(show, 1); j(2); }
