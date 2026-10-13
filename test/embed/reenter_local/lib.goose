// Case 1 of docs/design/reentrancy.md: C calls inner() back while outer()
// is in an extern call, with outer's resizable's top cached in a C local.
// inner would start on the same stacks and allocate over buf; the guard
// stops it before it runs.
extern fn host_callback(n: i64);
var total: i64 = 0;

export fn inner(n: i64) -> i64 {
    var tmp: i64[>..] = [];
    for i in 0..n { tmp.push(1000 + i); }
    var s = 0;
    for v in tmp { s += v; }
    total += 1;
    return s;
}

export fn outer(n: i64) -> i64 {
    var buf: i64[>..] = [];
    for i in 0..n { buf.push(i); }
    host_callback(n);
    buf.push(100);
    var s = 0;
    for v in buf { s += v; }
    return s;
}

export fn get_total() -> i64 { total }
