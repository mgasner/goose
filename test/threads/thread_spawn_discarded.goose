// A spawn whose id is not used is still a spawn: the worker runs, and the
// message it sends is what main waits for.
struct Done { k: i64 }

thread_fn worker(k: i64) { qput(Done { k: k * 10 }); }

fn main() {
    thread_spawn(worker, 4);
    print("got ", qget<Done>().k);
}
