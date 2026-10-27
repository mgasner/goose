// error: shrinks reusable pool pool
import std;
reusable[] var pool: u8[>..] = [];
struct Cache { bytes: u8[>..]& }
fn clear_cache(cache: Cache&) { cache.bytes.clear(); }
fn main() {
    var cache = Cache { bytes: pool };
    pool.alloc_slice(4);
    clear_cache(cache);
}
