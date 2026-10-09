// A deferred call is flat: it crosses a queue as its bytes, and the worker
// runs the same member against its own copy of the globals.
deferred Job(x: i64) -> i64;

var scale: i64 = 1;

fn mul(k: i64, x: i64) -> i64 { k * x * scale }
fn add(k: i64, x: i64) -> i64 { k + x + scale }
fn stop_marker(x: i64) -> i64 { -1 }

struct Result { id: i64, v: i64 }

thread_fn worker(x: i64) {
    scale = 100;            // the worker's own copy
    var id = 0;
    loop {
        let j = qget<Job>();
        if j == Job(stop_marker) { break; }
        qput(Result { id: id, v: j(x) });
        id++;
    }
}

fn main() {
    scale = 2;
    let w = thread_spawn(worker, 3);
    qput(Job(mul, 5));
    qput(Job(add, 7));
    qput(Job(stop_marker));
    for i in 2 {
        let r = qget<Result>();
        print(r.id, ": ", r.v);
    }
    thread_wait(w);
    print("main's scale: ", scale, ", main runs mul: ", Job(mul, 5)(3));
}
