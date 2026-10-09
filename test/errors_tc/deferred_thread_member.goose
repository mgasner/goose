// error: worker cannot be stored as Job: a thread_fn cannot be stored
deferred Job(now: i64);
thread_fn worker(now: i64) { print(now); }
fn main() { let j = Job(worker); j(2); }
