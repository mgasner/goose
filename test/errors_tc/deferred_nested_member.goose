// error: helper is not a top-level function, which is all Job can store
// A nested function's free variables live in a frame that will be gone.
deferred Job(now: i64);
fn main() {
    var n = 0;
    fn helper(now: i64) { n += now; }
    let j = Job(helper);
    j(1);
}
