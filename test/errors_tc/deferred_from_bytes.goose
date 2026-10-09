// error: Job is a deferred type, whose stored calls an image cannot choose
deferred Job(now: i64);
fn show(x: i64, now: i64) { print(x, now); }
fn main() {
    let jobs: Job[>..] = [Job(show, 1)];
    let img = to_bytes(jobs);
    let back, ok = from_bytes<Job[>..]>(img[..]);
}
