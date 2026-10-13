// error: expected a value of type bool, got i64
// A check of a file without fn main() still typechecks every function in it.
fn unused(x: i64) -> i64 {
    let y: bool = x;
    return y;
}
