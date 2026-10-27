// error: cannot call make, which grows words: the element pushed into words is still under construction
struct Cache { words: u8[][>..]& }
fn make(cache: Cache&) -> u8[] {
    cache.words.push("nested");
    return "outer";
}
fn main() {
    var words: u8[][>..] = [];
    var cache = Cache { words: words };
    words.push(make(cache));
}
