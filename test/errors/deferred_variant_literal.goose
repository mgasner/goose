// error: Job is a deferred type, whose calls have no variant names to write
deferred Job(now: i64);
fn show(x: i64, now: i64) { print(x, now); }
fn main() { let j = Job(show, 1); let k = Job.show { 1 }; j(2); }
