// error: Job is a deferred type, whose only named value is Job.empty
deferred Job(now: i64);
fn show(now: i64) { print(now); }
fn main() { let j = Job(show); let k = Job.show; j(2); }
