// error: recursive call cycle through again, stored as Job and invoked from inside its own call, which is not declared `recursive fn`
deferred Job(n: i64, me: Job) -> i64;
fn again(k: i64, n: i64, me: Job) -> i64 { if n <= 0 { return 0; } return me(n - k, me); }
fn main() { let j = Job(again, 1); print(j(3, j)); }
