// error: deferred type Job stores a variable-size value for expire
// One member storing a string makes the type usable in variable mode only.
deferred Job(now: i64);
fn resize(id: i64, now: i64) { print(id, now); }
fn expire(key: u8[], now: i64) { print(key, now); }
fn main() {
    var jobs: Job[>..<] = [];
    jobs.push(Job(resize, 1));
    let e: Job.. = Job(expire, "k");
    e(1);
}
