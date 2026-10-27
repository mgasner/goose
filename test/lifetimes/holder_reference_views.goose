import std;

reusable[] var unrelated: u8[>..] = [];
struct Cache { bytes: u8[>..]& }

fn clear_cache(cache: Cache&) { cache.bytes.clear(); }
fn forward(cache: Cache&) { clear_cache(cache); }
fn main() {
    var bytes: u8[>..] = [];
    var cache = Cache { bytes: bytes };
    unrelated.alloc_slice(4);
    for i in 3 {
        bytes.append("cache data");
        forward(cache);
        assert(bytes.len == 0 && unrelated.len == 4);
    }
    var other: u8[>..] = [1, 2];
    var second = Cache { bytes: other };
    forward(second);
    assert(other.len == 0 && unrelated.len == 4);
    print("holder reference views");
}
