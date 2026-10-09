// error: a deferred call stores a named function, not a block
deferred Job(now: i64);
fn main() { let j = Job() { now => print(now) }; j(1); }
