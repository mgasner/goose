// error: calls into its recursive cycle while non-fixed-size local buf
// A nonfixed local in scope where a member calls back into its own type.
deferred Job(n: i64, me: Job) -> i64;
recursive fn again(k: i64, n: i64, me: Job) -> i64 {
    if n <= 0 { return 0; }
    var buf: u8[>..] = [];
    buf.push(1);
    return me(n - k, me) + buf.len;
}
fn main() { let j = Job(again, 1); print(j(3, j)); }
