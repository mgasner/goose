// goose_init runs fn main(): a callback from an extern main calls is a
// re-entry too.
extern fn host_callback();

export fn ping() -> i64 { 1 }

fn main() {
    print("main: calling the host");
    host_callback();
    print("main: back (should have aborted)");
}
