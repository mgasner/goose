// A scheduler that stores the program's calls without knowing them: the
// deferred type is declared here, its members in the program importing it.
namespace sched;

deferred Task(now: i64) -> bool;

var pending: Task[>..<] = [];
var ran: i64 = 0;

fn after(t: Task) { pending.push(t); }

// Runs every pending task, in order; a task may schedule more, which run in
// the same call. Returns how many failed.
fn run_all(now: i64) -> i64 {
    var failed = 0;
    var i = 0;
    while i < pending.len {
        let t = pending[i];
        ran++;
        if !t(now) { failed++; }
        i++;
    }
    pending.clear();
    return failed;
}

// A member of the library's own.
fn noop(now: i64) -> bool { true }
fn idle() { after(Task(noop)); }
