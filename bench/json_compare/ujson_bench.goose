// Upstream's json module (aardappel/goose fb996b3, copied unchanged to
// stdlib/ujson.goose with its namespace renamed to ujson) on one task:
//   ujson_bench <task> <file> <reps> [out]
// The same tasks and output as fork_bench.goose:
//   parse          ujson::parse to a Node tree (fresh doc and decoded buffers)
//   kostya_dom     ujson::parse, then the average x, y, z of root.coordinates
//                  (as bench/kostya/goose/src/json_parse_dom.goose does)
//   kostya_stream  a ujson::Reader summing x, y, z as it goes, skipping the
//                  rest (json_parse_mapping.goose, without its array)
//   write          a parsed tree written back compactly: the module has no
//                  tree writer, so this walks the tree calling format_*
//   read           the file only (baseline for peak RSS)
//   hash           not timed: a content hash of the document (common.goose)
//   roundtrip      not timed: write the document to [out]
import std;
import os;
import ujson;
import common;

recursive fn hash(h: common::Hash&, n: ujson::Node&) {
    match n.val {
        Null => { common::kind(h, 'z'); },
        Bool b => { common::kind(h, if b.v { 't' } else { 'f' }); },
        Int i => { let x: f64 = i.v; common::number(h, x); },
        Num x => { common::number(h, x.v); },
        Str t => { common::string(h, t.s); },
        Arr a => {
            common::container(h, 'a', a.count);
            ujson::each(n) { c => hash(h, c); };
        },
        Obj o => {
            common::container(h, 'o', o.count);
            ujson::each(n) { c => common::key(h, c.key); hash(h, c); };
        },
    }
}

recursive fn write(out: u8[>..]&, n: ujson::Node&) {
    match n.val {
        Null => { out.append("null"); },
        Bool b => { ujson::format_bool(out, b.v); },
        Int i => { ujson::format_int(out, i.v); },
        Num x => { ujson::format_number(out, x.v); },
        Str t => { ujson::format_string(out, t.s); },
        Arr => {
            out.push('[');
            var first = true;
            ujson::each(n) { c =>
                if !first { out.push(','); }
                first = false;
                write(out, c);
            };
            out.push(']');
        },
        Obj => {
            out.push('{');
            var first = true;
            ujson::each(n) { c =>
                if !first { out.push(','); }
                first = false;
                ujson::format_key(out, c.key);
                write(out, c);
            };
            out.push('}');
        },
    }
}

fn number_at(coord: ujson::Node&, key: u8[:]) -> f64 {
    let v, ok = ujson::as_f64(ujson::member(coord, key));
    if !ok { abort(str("no number at ", key)); }
    return v;
}

fn kostya_dom(text: u8[:]) -> f64, f64, f64 {
    var doc: ujson::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = ujson::parse(text, doc, decoded);
    guard root else { abort(err); }
    let coordinates = ujson::member(root, "coordinates");
    guard coordinates else { abort("no coordinates"); }
    var len = 0.0;
    match coordinates.val {
        Arr a => { len = a.count; },
        _ => { abort("coordinates is not an array"); },
    }
    var x = 0.0;
    var y = 0.0;
    var z = 0.0;
    ujson::each(coordinates) { coord =>
        x += number_at(coord, "x");
        y += number_at(coord, "y");
        z += number_at(coord, "z");
    };
    return x / len, y / len, z / len;
}

fn kostya_stream(text: u8[:]) -> f64, f64, f64 {
    var r = ujson::reader(text);
    var n = 0;
    var x = 0.0;
    var y = 0.0;
    var z = 0.0;
    ujson::each_member(r) { key =>
        if key == "coordinates" {
            ujson::each_element(r) {
                ujson::each_member(r) { k =>
                    if k == "x" { x += ujson::read_number(r); }
                    else if k == "y" { y += ujson::read_number(r); }
                    else if k == "z" { z += ujson::read_number(r); }
                    else { ujson::skip(r); }
                };
                n++;
            };
        } else { ujson::skip(r); }
    };
    if !ujson::finish(r) { abort(ujson::message(r)); }
    let len: f64 = n;
    return x / len, y / len, z / len;
}

// The write task: the tree is parsed once, untimed, and written per rep.
fn time_write(text: u8[:], reps: i64) {
    var doc: ujson::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = ujson::parse(text, doc, decoded);
    guard root else { abort(err); }
    var times: u8[>..] = [];
    var outlen = 0;
    for r in reps + 1 {
        let t0 = clock_ns();
        var out: u8[>..] = [];
        write(out, root);
        outlen = out.len;
        let t1 = clock_ns();
        if r > 0 {
            if times.len > 0 { times.push(','); }
            format(times, t1 - t0);
        }
    }
    print("ns=", times);
    print("bytes=", text.len, " outbytes=", outlen, " sink=0");
}

fn main() {
    let a = args();
    guard a.len >= 3 else { print("usage: ujson_bench task file reps [out]"); exit(2); }
    let task = a[1];
    var text: u8[>..] = [];
    guard read_file(a[2], text) else { print("cannot read ", a[2]); exit(2); }
    var reps = 1;
    if a.len > 3 { let r, ok = parse_int(a[3]); reps = r; }

    if task == "hash" {
        var doc: ujson::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, err = ujson::parse(text, doc, decoded);
        guard root else { print("reject: ", err); exit(1); }
        var h = common::Hash {};
        hash(h, root);
        common::report(h);
        return;
    }
    if task == "roundtrip" {
        var doc: ujson::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, err = ujson::parse(text, doc, decoded);
        guard root else { print("reject"); exit(1); }
        var out: u8[>..] = [];
        write(out, root);
        guard write_file(a[4], out) else { exit(1); }
        print("bytes=", out.len);
        return;
    }

    if task == "write" { time_write(text, reps); return; }

    var times: u8[>..] = [];
    var sink = 0.0;
    var outlen = 0;
    for r in reps + 1 {
        let t0 = clock_ns();
        if task == "parse" {
            var doc: ujson::Node[>..] = [];
            var decoded: u8[>..] = [];
            let root, err = ujson::parse(text, doc, decoded);
            guard root else { abort(err); }
            sink += doc.len;
        } else if task == "kostya_dom" {
            let x, y, z = kostya_dom(text);
            sink += x + y + z;
            if r == 0 { print("avg=", x, " ", y, " ", z); }
        } else if task == "kostya_stream" {
            let x, y, z = kostya_stream(text);
            sink += x + y + z;
            if r == 0 { print("avg=", x, " ", y, " ", z); }
        } else if task == "read" {
            sink += text.len;
        } else { print("unknown task ", task); exit(2); }
        let t1 = clock_ns();
        if r > 0 {
            if times.len > 0 { times.push(','); }
            format(times, t1 - t0);
        }
    }
    print("ns=", times);
    print("bytes=", text.len, " outbytes=", outlen, " sink=", sink);
}
