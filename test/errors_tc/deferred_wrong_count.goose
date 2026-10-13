// error: show cannot be stored as Job: it takes 2 parameter(s), not the 2 stored argument(s) given plus the 1 Job is called with
deferred Job(now: i64);
fn show(x: i64, now: i64) { print(x, now); }
fn main() { let j = Job(show, 1, 2); j(2); }
