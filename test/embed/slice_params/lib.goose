// An export taking a slice, called from C: the wrapper takes the C struct
// and passes its words on. Moved from codegen/export.goose, whose own main
// can no longer call its export back through C (spec §7.11).
export "c_weigh" fn weigh(xs: const i64[:], w: i64) -> i64 {
    var t = 0;
    for x, i in xs { t += x * (i + w); }
    return t;
}
