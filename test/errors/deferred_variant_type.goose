// error: Job is a deferred type, whose calls have no variant names to write
deferred Job(now: i64);
fn show(x: Job.empty) {}
fn main() {}
