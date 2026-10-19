// An export's C wrapper passes whatever its C caller does, so the export
// enters with nothing its Goose call sites proved
// (optimizer/bce_export_entry.goose): every site here passes an index
// below the length, and C's call with one past it still aborts.
export "c_pick" fn pick(dist: i32[:], i: i64) -> i32 {
    return dist[i];
}

fn main() {
    var d: i32[>..] = [];
    d.push(7);
    print(pick(d, 0));
}
