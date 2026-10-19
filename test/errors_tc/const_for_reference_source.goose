// error: fields requires a concrete struct type
struct S { x: i64 }
fn main() { const for <N, A> in fields<S&> {} }
