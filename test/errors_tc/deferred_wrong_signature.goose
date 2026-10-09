// error: show cannot be stored as Job: its parameter now is i32 where Job passes i64
deferred Job(now: i64);
fn show(x: i64, now: i32) { print(x, now); }
fn main() { let j = Job(show, 1); j(2); }
