// error: Job is a deferred type: call its value, or compare it with Job.empty, rather than match it
deferred Job(now: i64);
fn show(x: i64, now: i64) { print(x, now); }
fn main() {
    let j = Job(show, 1);
    match j { _ => print("any") }
}
