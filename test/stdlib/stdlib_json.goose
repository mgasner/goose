// The json module: the writer, number text both ways, the document parser
// and its accessors, errors with their positions, and the cursor.
import std;
import json;

fn show_float(x: f64) {
    var out: u8[>..] = [];
    json::write_float(out, x);
    print(out);
}

fn show_doc(text: const u8[:]) {
    let d = json::parse(text);
    if !d.ok() {
        print("error at ", d.error.at, ": ", d.error.message);
        return;
    }
    var out: u8[>..] = [];
    var w = json::writer(out);
    w.value(d.root());
    print(out);
}

fn main() {
    print("-- writer");
    var out: u8[>..] = [];
    var w = json::writer(out);
    w.object() {
        w.field("id", 7);
        w.field("name", "tab\there \"quoted\" back\\slash \x01");
        w.field("ratio", 0.1);
        w.field("ok", true);
        w.key("tags");
        w.array() { w.string("a"); w.string("é"); w.none(); w.uint(18446744073709551615); };
        w.key("empty");
        w.object() {};
        w.key("raw");
        w.raw("[1,2]");
    };
    print(out);
    var pretty: u8[>..] = [];
    var p = json::pretty_writer(pretty, 2);
    p.object() {
        p.field("a", 1);
        p.key("b");
        p.array() { p.int(-2); p.array() {}; p.object() { p.field("c", false); }; };
    };
    print(pretty);

    print("-- floats out");
    for x in [0.0, -0.0, 1.0, -1.5, 0.1, 0.30000000000000004, 123456789.125, 1e21, 1e20, 1.5e-7, 0.000001,
              5e-324, 1.7976931348623157e308, 2.2250738585072014e-308, 9007199254740993.0, 1.0 / 0.0, 0.0 / 0.0] {
        show_float(x);
    }

    print("-- numbers in");
    for t in ["0", "-0", "42", "-9223372036854775808", "9223372036854775807", "9223372036854775808",
              "18446744073709551616", "1.5", "1e400", "-1e-400", "2.4703282292062328e-324",
              "0.1000000000000000055511151231257827021181583404541015625",
              "1.00000000000000011102230246251565404236316680908203125",
              "123456789012345678901234567890e-10", "01", "1.", "-", ".5", "1e", "+1"] {
        let d = json::parse(t);
        let v = d.root();
        if !d.ok() { print(t, " -> error: ", d.error.message); continue; }
        let i, iok = v.try_int();
        let u, uok = v.try_uint();
        var f: u8[>..] = [];
        json::write_float(f, v.float());
        print(t, " -> kind ", v.kind(), " int ", i, " ", iok, " uint ", u, " ", uok, " float ", f);
    }

    print("-- documents");
    let text = """
        {"users": [{"name": "Ada", "age": 36, "langs": ["en", "fr"]},
                   {"name": "Al\u0061n", "age": 41.0, "nick": null}],
         "count": 2, "emoji": "\ud83d\ude00", "dup": 1, "dup": 2}
        """;
    let d = json::parse(text);
    print("ok ", d.ok(), ", ", d.ntape, " entries");
    let r = d.root();
    print("count ", r.get("count").int(), ", users ", r.get("users").count(), ", dup ", r.get("dup").int());
    r.get("users").each() { u =>
        print("  ", u.get("name").string(), " ", u.get("age").int(), " langs ", u.get("langs").count(),
              " nick null ", u.get("nick").is_null(), " missing ", u.get("missing").exists());
    };
    print("emoji bytes ", r.get("emoji").string().len, ", second user ", r.get("users").at(1).get("name").string());
    print("past the end ", r.get("users").at(5).exists(), ", wrong kind ", r.get("count").string().len, " ", r.get("count").get("x").exists());
    r.members() { k, v => print("  member ", k, " kind ", v.kind()); };
    show_doc(text);
    show_doc("  [ ]  ");
    show_doc("\"\\b\\f\\n\\r\\t\\/\\u0000\"");

    print("-- errors");
    for t in ["", "[1,]", "{\"a\" 1}", "{\"a\":1,}", "[1 2]", "[\"abc", "\"\\x\"", "\"\\ud800\"", "\"\t\"",
              "[1]x", "tru", "nul", "{1:2}", "\"\xff\"", "\"\xc0\xaf\"", "[[[]]", "\xef\xbb\xbf{}"] {
        show_doc(t);
    }
    json::max_depth = 3;
    show_doc("[[[1]]]");
    show_doc("[[[[1]]]]");
    json::max_depth = 1024;

    print("-- cursor");
    var c = json::cursor(text);
    let cr = c.root();
    print("ok ", c.ok(), ", count ", cr.get("count").int(), ", first name ", cr.get("users").at(0).get("name").string(),
          ", second ", cr.get("users").at(1).get("name").string(), ", age ", cr.get("users").at(1).get("age").float());
    print("raw ", cr.get("users").at(0).get("langs").raw(), " emoji bytes ", cr.get("emoji").string().len);
    cr.get("users").each() { u => print("  ", u.get("name").string(), " has ", u.count(), " members"); };
    for t in ["[1]]", "[][]", "{\"a\":1}}", "\"open", "[1]  "] {
        var e = json::cursor(t);
        print(t, " -> ", if e.ok() { "ok" } else { e.error.message });
    }
    var bad = json::cursor("[1, tru, 3]");
    print("bad literal kind ", bad.root().at(1).kind(), ", others ", bad.root().at(0).int(), " ", bad.root().at(2).int());
}
