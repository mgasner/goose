// Case 2 of docs/design/reentrancy.md: BCE proves g[4] in bounds across the
// extern call, which §7.10 lets it assume leaves g alone; a callback into
// shrink() would clear g under it. The guard stops the callback.
extern fn host_callback(n: i64);
var g: i64[>..] = [];

export fn shrink(n: i64) -> i64 { g.clear(); return 0; }

export fn outer(n: i64) -> i64 {
    for i in 0..5 { g.push(i + 1); }
    host_callback(n);
    return g[4];
}
