// A struct literal builds where its value stays: a local's in the local, a
// field's literal or default in the field, with no temporary copied over
// (§4.3), and a limited array in it writes its length alone, its free
// slots left uninitialized (§4.2; Appendix E zeroes them under MSVC).
// c-lacks: \(Request_g\)\{0\}
// c-lacks: ^\s+l64_Header_g t\d+;
// c-lacks: memset\(&[^;]*headers_g
// c-has: req_g\.headers_g\.len = 0;
// c-has: GS_UNWRITTEN\(&req_g\.headers_g\.e\[0\]
// c-has: GS_UNWRITTEN\(&fixed_g\.e\[2\]
// c-lacks: ^\s+l128_u8 t\d+;
// c-lacks: ^\s+l2048_u8 t\d+;
// c-has: \.kind_g\.len = 10;
import std;

struct Header { name: const u8[:], value: const u8[:] }
struct Framing { clen: i64 = -1, chunked: bool = false }
struct Request {
    method: const u8[:],
    minor: i64,
    headers: Header[..64],
    framing: Framing,
    tags: i64[..4] = [7],
    next: Request&?,
}

// A resizable struct (§3.4) builds its fixed fields where it stays too, a
// whole assignment's included, whose value may not name what it replaces.
struct Reply {
    status: i64 = 200,
    kind: u8[..128] = "text/plain",
    extra: u8[..2048] = [],
    body: u8[>..] = [],
}
fn answer(r: Reply&, k: i64) {
    r.status = k;
    r.extra.append("X: y");
    r.body.append("hi");
}

var made = 0;
fn tick() -> i64 { made++; return made; }
struct Counted { id: i64 = tick(), hs: i64[..8] }

fn fill(r: Request&, k: i64) {
    r.minor = k;
    for j in k { r.headers.push(Header { name: "n", value: "v" }); }
}

fn show(r: const Request&) {
    print(r.method.len, " ", r.minor, " ", r.headers.len, " ", r.framing.clen, " ",
          r.framing.chunked, " ", r.tags.len, " ", r.tags[0], " ", r.next == null);
}

fn main() {
    for i in 3 {
        var req = Request { .. };
        fill(req, i);
        show(req);
        let copy = req;
        show(copy);
    }
    var fixed: i64[..5] = [1, 2];
    fixed.push(3);
    let fc = fixed;
    print(fc.len, " ", fc[2]);
    // Assignment builds through a temporary still, since the literal may
    // read what it replaces.
    var r = Request { method: "GET", .. };
    fill(r, 2);
    r = Request { minor: r.minor + 1, .. };
    show(r);
    let a = Counted { .. };
    let b = Counted { hs: [1, 2], .. };
    print(a.id, " ", b.id, " ", a.hs.len, " ", b.hs.len, " ", made);
    var rep = Reply { .. };
    for k in 2 {
        rep = Reply { .. };
        answer(rep, k);
        print(rep.status, " ", rep.kind, " ", rep.extra, " ", rep.body);
    }
}
