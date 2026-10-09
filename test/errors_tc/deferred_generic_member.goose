// error: show cannot be stored as Job: parameter x has no type, which makes the function generic
deferred Job(now: i64);
fn show(x, now: i64) { print(x, now); }
fn main() { let j = Job(show, 1); j(2); }
