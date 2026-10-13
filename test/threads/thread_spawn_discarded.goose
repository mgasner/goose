// A spawn whose id is thrown away still starts the worker, with or without
// arguments.
struct Done { n: i32 }
thread_fn worker() { qput(Done { n: 42 }); }
thread_fn worker_of(k: i32) { qput(Done { n: k * 10 }); }
fn main() {
    thread_spawn(worker);
    print(qget<Done>().n);
    thread_spawn(worker_of, 4);
    print(qget<Done>().n);
}
