// JSONTestSuite through upstream's json: `conf_ujson file...` prints
// "<file> <document> <stream>", each accept or reject. The document is
// ujson::parse; the stream is a ujson::Reader that skips the whole value
// (skip checks what it passes over) and then finish.
import std;
import os;
import ujson;

fn main() {
    let a = args();
    for k in 1..a.len {
        var text: u8[>..] = [];
        guard read_file(a[k], text) else { print(a[k], " unreadable"); continue; }
        var doc: ujson::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, err = ujson::parse(text, doc, decoded);
        var r = ujson::reader(text);
        ujson::skip(r);
        let sok = ujson::finish(r);
        print(a[k], if root { " accept" } else { " reject" }, if sok { " accept" } else { " reject" });
    }
}
