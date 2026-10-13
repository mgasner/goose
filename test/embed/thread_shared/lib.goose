// Case 3 of docs/design/reentrancy.md, a library without threads: its
// stacks and globals are process-wide, and a host thread would share them
// with the one that ran goose_init.
var total: i64 = 0;

export fn inner(n: i64) -> i64 {
    var tmp: i64[>..] = [];
    for i in 0..n { tmp.push(1000 + i); }
    var s = 0;
    for v in tmp { s += v; }
    total += 1;
    return s;
}

export fn get_total() -> i64 { total }
