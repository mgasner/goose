// error: keep cannot be stored as Job: its stored parameter s is u8[:], which is not flat (it holds a reference)
// A stored call keeps flat values only, so the type stays flat whatever members a program adds.
deferred Job(now: i64);
fn keep(s: u8[:], now: i64) { print(s, now); }
fn main() { let j = Job(keep, "abc"); j(2); }
