// Json: the mean of the coordinates in a large JSON document, from the
// standard library's parsed document, as serde_json's Value and RapidJSON's
// Document hand them over.

import std;
import os;
import json;

extern "goose_notify_start" fn notify_start(variant: const u8[:]);
extern "goose_notify_stop" fn notify_stop();

struct Coordinate { x: f64, y: f64, z: f64 }

fn format(out: u8[>..]&, c: Coordinate) {
    format(out, "Coordinate { x: ", c.x, ", y: ", c.y, ", z: ", c.z, " }");
}

// coord[key] as a number; the text is the benchmark's, so anything else is
// a bug.
fn number(coord: json::Value, key: u8[:]) -> f64 {
    let v, ok = coord.get(key).try_float();
    if !ok { abort(str("not a number: ", key)); }
    return v;
}

fn calc(text: const u8[:]) -> Coordinate {
    let doc = json::parse(text);
    guard doc.ok() else { abort(str("json: ", doc.error.message, " at byte ", doc.error.at)); }
    let coordinates = doc.root().get("coordinates");
    guard coordinates.is_array() else { abort("no coordinates"); }

    var len = 0;
    var x = 0.0;
    var y = 0.0;
    var z = 0.0;
    coordinates.each() { coord =>
        x += number(coord, "x");
        y += number(coord, "y");
        z += number(coord, "z");
        len++;
    };
    return Coordinate { x / len, y / len, z / len };
}

fn main() {
    let right = Coordinate { 2.0, 0.5, 0.25 };
    for v in ["{\"coordinates\":[{\"x\":2.0,\"y\":0.5,\"z\":0.25}]}",
              "{\"coordinates\":[{\"y\":0.5,\"x\":2.0,\"z\":0.25}]}"] {
        let left = calc(v);
        if left != right { abort(str(left, " != ", right)); }
    }

    var text: u8[>..] = [];
    read_file("/tmp/1.json", text);

    notify_start(" (DOM)");
    let results = calc(text);
    notify_stop();

    print(results);
}
