// Invoking the empty call aborts, whichever way it was made: Job.empty,
// default<Job>(), or a missed qpoll.
deferred Job(now: i64) -> i64;
fn twice(k: i64, now: i64) -> i64 { k * now * 2 }

fn main() {
    let jobs: Job[4] = [Job(twice, 1), default<Job>(), Job.empty, Job(twice, 3)];
    for j in jobs { print(j == Job.empty); }
    print(jobs[0](5), " ", jobs[3](5));
    let missed, got = qpoll<Job>();
    print(got, " ", missed == Job.empty);
    print(missed(1));
    print("not reached");
}
