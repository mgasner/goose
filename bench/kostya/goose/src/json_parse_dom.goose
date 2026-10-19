// Json::ParseDom: parses the generated text into a document tree on every
// run and averages the coordinates read back out of it.

namespace json_parse_dom;

import std;
import bench;
import helper;
import json;
import json_generate;

struct JsonParseDom { n: i64, result_val: u32, text: u8[>..] }

fn new_json_parse_dom() -> JsonParseDom {
    JsonParseDom { n: config_i64("Json::ParseDom", "coords"), result_val: 0, text: [] }
}

// coord[key] as a number; the text is ours, so anything else is a bug.
fn number_at(coord: json::Value, key: u8[:]) -> f64 {
    let v, ok = coord.get(key).try_float();
    if !ok { abort(str("no number at ", key)); }
    return v;
}

fn calc(s: JsonParseDom&, text: u8[:]) -> f64, f64, f64 {
    let doc = json::parse(text);
    guard doc.ok() else { abort(str("json: ", doc.error.message, " at byte ", doc.error.at)); }
    let coordinates = doc.root().get("coordinates");
    guard coordinates.is_array() else { abort("no coordinates array"); }
    // An array's entry keeps its element count.
    let len: f64 = coordinates.count();

    var x = 0.0;
    var y = 0.0;
    var z = 0.0;

    coordinates.each() { coord =>
        x += number_at(coord, "x");
        y += number_at(coord, "y");
        z += number_at(coord, "z");
    };

    return x / len, y / len, z / len;
}

fn prepare(s: JsonParseDom&) {
    var generator = json_generate::new_json_generate(s.n);
    json_generate::prepare(generator);
    json_generate::run(generator, 0);
    s.text = str(json_generate::get_result(generator));
}

fn run(s: JsonParseDom&, iteration_id: i64) {
    let x, y, z = s.calc(s.text);
    s.result_val += checksum_f64(x) + checksum_f64(y) + checksum_f64(z);
}

fn checksum(s: JsonParseDom&) -> u32 { s.result_val }
