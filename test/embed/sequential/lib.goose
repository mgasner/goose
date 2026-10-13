// Calls in sequence from the thread that ran goose_init, with calls out to
// C that do not come back in, all work as before.
extern fn host_note(n: i64);
var total: i64 = 0;
var seen: i64[>..] = [];

export fn add(n: i64) -> i64 {
    var tmp: i64[>..] = [];
    for i in 0..n { tmp.push(i); }
    host_note(tmp.len);
    for v in tmp {
        total += v;
        seen.push(v);
    }
    return total;
}

export fn count() -> i64 { seen.len }

export "c_greeting" fn greeting() -> const u8[:] { "hello from goose" }

export fn reset() {
    total = 0;
    seen.clear();
}
