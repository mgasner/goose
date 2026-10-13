export fn hello_world() -> const u8[:] {
    return "Hello, world!"
}

export "c_add" fn add(a: i32, b: i32) -> i32 {
    return a + b;
}

// A slice parameter: the wrapper takes the C struct and passes its words on.
export "c_weigh" fn weigh(xs: const i64[:], w: i64) -> i64 {
    var t = 0;
    for x, i in xs { t += x * (i + w); }
    return t;
}

// Its C wrapper is called from a C host in embed/slice_params: called back
// from here, through its C symbol, it would re-enter Goose while main runs,
// which the export guards abort (spec §7.11).

fn main() {
    print(hello_world(), " ", add(20, 22));
    let xs: i64[4] = [3, 1, 4, 1];
    print(weigh(xs, 1), " ", weigh(xs[1..3], 0));
}
