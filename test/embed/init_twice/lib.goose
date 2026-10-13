// A second goose_init does nothing: fn main() runs once.
var inits: i64 = 0;

export fn init_count() -> i64 { inits }

fn main() {
    inits += 1;
    print("main ran");
}
