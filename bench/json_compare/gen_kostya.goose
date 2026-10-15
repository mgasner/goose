// The kostya coordinates input: `gen_kostya n out.json`. The text that
// LangArena's Json::Generate (bench/kostya/goose/src/json_generate.goose)
// writes, with its random number generator and the same writer calls
// (upstream's format_*, here ujson::): x, y, z rounded to 8 places, a
// "0.ddddddd nnnn" name and an opts map of {"1":[1,true]}.
//   {"coordinates":[{"x":..,"y":..,"z":..,"name":"..","opts":{"1":[1,true]}},..],"info":"some info"}
// The name's digits come from next_int rather than LangArena's format_fixed
// of next_float; they are 7 digits either way.
import std;
import os;
import math;
import ujson;
import common;

fn round_to_8(v: f64) -> f64 { round(v * 100000000.0) / 100000000.0 }

fn main() {
    let a = args();
    let n, ok = parse_int(a[1]);
    var out: u8[>..] = [];
    out.push('{');
    ujson::format_key(out, "coordinates");
    out.push('[');
    for i in n {
        let x = round_to_8(common::next_float(1.0));
        let y = round_to_8(common::next_float(1.0));
        let z = round_to_8(common::next_float(1.0));
        var name: u8[>..] = [];
        let d = common::next_int(10000000);
        format(name, "0.");
        var p = 1000000;
        while p > 1 && d < p { name.push('0'); p /= 10; }
        format(name, d, " ", common::next_int(10000));
        if i > 0 { out.push(','); }
        out.push('{');
        ujson::format_key(out, "x"); ujson::format_number(out, x); out.push(',');
        ujson::format_key(out, "y"); ujson::format_number(out, y); out.push(',');
        ujson::format_key(out, "z"); ujson::format_number(out, z); out.push(',');
        ujson::format_key(out, "name"); ujson::format_string(out, name); out.push(',');
        ujson::format_key(out, "opts");
        out.push('{');
        ujson::format_key(out, "1");
        out.push('[');
        ujson::format_int(out, 1);
        out.push(',');
        ujson::format_bool(out, true);
        out.append("]}}");
    }
    out.append("],");
    ujson::format_key(out, "info");
    ujson::format_string(out, "some info");
    out.push('}');
    guard write_file(a[2], out) else { exit(1); }
    print(n, " coordinates, ", out.len, " bytes");
}
