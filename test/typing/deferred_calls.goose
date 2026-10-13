// Deferred calls (docs/design/deferred_calls.md): stored calls of open
// membership, invoked by tag dispatch.
import deferred_lib.sched;

// Fixed-size stored arguments only: usable in fixed mode.
deferred Tick(dt: i64) -> i64;
fn scaled(k: i64, dt: i64) -> i64 { k * dt }
fn offset(a: i32, b: i32, dt: i64) -> i64 { a + b + dt }
fn zero(dt: i64) -> i64 { 0 }

// One member stores a string: variable mode only.
deferred Job(now: i64) -> bool;
fn resize(img: i64, width: i32, now: i64) -> bool { print("resize ", img, " to ", width, " at ", now); true }
fn expire(key: u8[], now: i64) -> bool { print("expire ", key, " at ", now); now > 5 }

// Several results, and a nonfixed one built at the call's destination.
deferred Split(x: i64) -> i64, bool;
fn halve(bias: i64, x: i64) -> i64, bool { return x / 2 + bias, x % 2 == 0; }
deferred Render(n: i64) -> u8[>..];
fn stars(c: u8, n: i64) -> u8[>..] { var s: u8[>..] = []; for i in n { s.push(c); } return s; }

// Call-time references: a builder and a slice.
deferred Emit(out: u8[>..]&, xs: i64[:]);
fn emit_sum(label: u8, out: u8[>..]&, xs: i64[:]) {
    var t = 0;
    for x in xs { t += x; }
    format(out, label as i64, "=", t, " ");
}
fn emit_len(out: u8[>..]&, xs: i64[:]) { format(out, "len=", xs.len, " "); }

// A struct holding a stored call, invoked as a field.
struct Button { label: u8[..8], on_press: Tick }

// Members of the library's type.
fn log_tick(id: i64, now: i64) -> bool { print("task ", id, " at ", now); id != 2 }
fn chain(id: i64, now: i64) -> bool {
    print("task ", id, " schedules ", id + 10);
    sched::after(sched::Task(log_tick, id + 10));
    true
}

// A `return from` through an invocation lands outside it.
deferred Check(x: i64);
fn must_be_small(limit: i64, x: i64) { if x > limit { return false from validate; } }
fn validate(c: Check, x: i64) -> bool { c(x); return true; }

// A member that invokes its own type.
deferred Count(n: i64, via: Count) -> i64;
recursive fn countdown(step: i64, n: i64, via: Count) -> i64 {
    if n <= 0 { return 0; }
    return 1 + via(n - step, via);
}

fn make_tick(k: i64) -> Tick { Tick(scaled, k) }

// Through a reference parameter, by value, and through an alias.
fn run_ref(j: Job..&, now: i64) -> bool { j(now) }
fn run_val(j: Job.., now: i64) -> bool { j(now) }
type Clock = Tick;

fn main() {
    // Fixed mode: arrays that index, struct fields, a function's result.
    var ticks: Tick[>..<] = [];
    ticks.push(Tick(scaled, 3));
    ticks.push(Tick(offset, 1, 2));
    ticks.push(Tick(zero));
    ticks.push(Tick.empty);
    for k in ticks.len {
        let t = ticks[k];
        if t == Tick.empty { print(k, ": empty"); continue; }
        print(k, ": ", t, " -> ", ticks[k](10));
    }
    let b = Button { label: "ok", on_press: Tick(offset, 5, 5) };
    print(b.label, " ", b.on_press(1));
    print(make_tick(7)(6));
    print(Tick(scaled, 2) == Tick(scaled, 2), " ", Tick(scaled, 2) == Tick(scaled, 3),
          " ", Tick(scaled, 2) == Tick(zero));

    // Variable mode: iterated, invoked where it lies.
    var jobs: Job..[>..] = [];
    jobs.push(Job(resize, 17, 640));
    jobs.push(Job(expire, "session:42"));
    jobs.push(Job.empty);
    var t = 0;
    for j in jobs {
        print(j);
        if j == Job.empty { continue; }
        if !j(t) { print("job failed at ", t); }
        t += 10;
    }
    let one: Job.. = Job(expire, "x");
    print(one(1));
    print(run_ref(one, 2), " ", run_val(Job(resize, 3, 4), 5));
    let c: Clock = Clock(offset, 2, 3);
    print(c(4), " ", c == Tick(offset, 2, 3));

    let sp = Split(halve, 100);
    let h, even = sp(7);
    print(h, " ", even);
    let r = Render(stars, '*');
    var line: u8[>..] = [];
    line.append(r(5));
    print(line);

    var out: u8[>..] = [];
    let xs = [1, 2, 3];
    var emits: Emit[>..] = [];
    emits.push(Emit(emit_sum, 'a'));
    emits.push(Emit(emit_len));
    for e in emits { e(out, xs[..]); }
    print(out);

    sched::after(sched::Task(log_tick, 1));
    sched::after(sched::Task(log_tick, 2));
    sched::after(sched::Task(chain, 3));
    sched::idle();
    print("failed: ", sched::run_all(100), ", ran: ", sched::ran);

    print(validate(Check(must_be_small, 5), 3), " ", validate(Check(must_be_small, 5), 9));

    let c = Count(countdown, 2);
    print(c(9, c));
}
