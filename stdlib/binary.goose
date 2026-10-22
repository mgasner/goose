// Checked reads of external binary formats, independent of from_bytes' image
// format. Slices and names borrow the input; no read allocates or copies bytes.
namespace binary;
import std;

// Negative offsets/sizes wrap above every valid slice length. Check the
// offset before subtracting, so even extreme inputs cannot wrap the range.
fn range_ok(data: const u8[:], at: i64, size: i64) -> bool {
    let start = at as! u64;
    start <= data.len as u64 && (size as! u64) <= data.len as u64 - start
}

// Offset reads return zero/an empty slice and false on an invalid range.
fn read_bytes(data: const u8[:], at: i64, size: i64) -> const u8[:], bool {
    if !range_ok(data, at, size) { return data[..0], false; }
    return data[at..at + size], true;
}
fn read_u16le(data: const u8[:], at: i64) -> u16, bool {
    if !range_ok(data, at, 2) { return 0, false; }
    return data[at] | (data[at + 1] as u16 << 8), true;
}
fn read_i16le(data: const u8[:], at: i64) -> i16, bool {
    let value, ok = read_u16le(data, at);
    return value as! i16, ok;
}
fn read_u32le(data: const u8[:], at: i64) -> u32, bool {
    if !range_ok(data, at, 4) { return 0, false; }
    return data[at] | (data[at + 1] as u32 << 8) |
           (data[at + 2] as u32 << 16) | (data[at + 3] as u32 << 24), true;
}

fn read_u8(data: const u8[:], at: i64) -> u8, bool {
    if !range_ok(data, at, 1) { return 0, false; }
    return data[at], true;
}
fn read_i32le(data: const u8[:], at: i64) -> i32, bool {
    let value, ok = read_u32le(data, at);
    return value as! i32, ok;
}
fn read_u64le(data: const u8[:], at: i64) -> u64, bool {
    if !range_ok(data, at, 8) { return 0, false; }
    let lo, a = read_u32le(data, at);
    let hi, b = read_u32le(data, at + 4);
    return lo | (hi as u64 << 32), true;
}
fn read_i64le(data: const u8[:], at: i64) -> i64, bool {
    let value, ok = read_u64le(data, at);
    return value as! i64, ok;
}

// Big-endian, as network formats and some object files store them.
fn read_u16be(data: const u8[:], at: i64) -> u16, bool {
    if !range_ok(data, at, 2) { return 0, false; }
    return (data[at] as u16 << 8) | data[at + 1], true;
}
fn read_u32be(data: const u8[:], at: i64) -> u32, bool {
    if !range_ok(data, at, 4) { return 0, false; }
    return (data[at] as u32 << 24) | (data[at + 1] as u32 << 16) |
           (data[at + 2] as u32 << 8) | data[at + 3], true;
}
fn read_u64be(data: const u8[:], at: i64) -> u64, bool {
    if !range_ok(data, at, 8) { return 0, false; }
    let hi, a = read_u32be(data, at);
    let lo, b = read_u32be(data, at + 4);
    return (hi as u64 << 32) | lo, true;
}

// The bytes from at to the next NUL, which must be there: a string table's
// entry. The slice leaves the NUL out.
fn read_cstring(data: const u8[:], at: i64) -> const u8[:], bool {
    if !range_ok(data, at, 0) { return data[..0], false; }
    var end = at;
    while end < data.len && data[end] != 0 { end++; }
    if end == data.len { return data[..0], false; }
    return data[at..end], true;
}

// Validate the entire field, then trim at its first NUL (or keep the full
// width if none). These are bytes: no encoding or padding validation is done.
fn read_name(data: const u8[:], at: i64, width: i64) -> const u8[:], bool {
    let field, ok = read_bytes(data, at, width);
    if !ok { return field, false; }
    var size = 0;
    while size < field.len && field[size] != 0 { size++; }
    return field[..size], true;
}

// Every read returns its own success flag. Failures leave pos unchanged, so
// callers may try another read. A name consumes its entire field width.
struct Reader { data: const u8[:], pos: i64 }
fn reader(data: const u8[:]) -> Reader { Reader { data, 0 } }

fn read_bytes(r: Reader&, size: i64) -> const u8[:], bool {
    let data, ok = read_bytes(r.data, r.pos, size);
    if ok { r.pos += size; }
    return data, ok;
}
fn read_u16le(r: Reader&) -> u16, bool {
    let value, ok = read_u16le(r.data, r.pos);
    if ok { r.pos += 2; }
    return value, ok;
}
fn read_i16le(r: Reader&) -> i16, bool {
    let value, ok = read_u16le(r);
    return value as! i16, ok;
}
fn read_u32le(r: Reader&) -> u32, bool {
    let value, ok = read_u32le(r.data, r.pos);
    if ok { r.pos += 4; }
    return value, ok;
}
fn read_u8(r: Reader&) -> u8, bool {
    let value, ok = read_u8(r.data, r.pos);
    if ok { r.pos += 1; }
    return value, ok;
}
fn read_i32le(r: Reader&) -> i32, bool {
    let value, ok = read_u32le(r);
    return value as! i32, ok;
}
fn read_u64le(r: Reader&) -> u64, bool {
    let value, ok = read_u64le(r.data, r.pos);
    if ok { r.pos += 8; }
    return value, ok;
}
fn read_i64le(r: Reader&) -> i64, bool {
    let value, ok = read_u64le(r);
    return value as! i64, ok;
}
fn read_u16be(r: Reader&) -> u16, bool {
    let value, ok = read_u16be(r.data, r.pos);
    if ok { r.pos += 2; }
    return value, ok;
}
fn read_u32be(r: Reader&) -> u32, bool {
    let value, ok = read_u32be(r.data, r.pos);
    if ok { r.pos += 4; }
    return value, ok;
}
fn read_u64be(r: Reader&) -> u64, bool {
    let value, ok = read_u64be(r.data, r.pos);
    if ok { r.pos += 8; }
    return value, ok;
}
// Consumes the NUL as well.
fn read_cstring(r: Reader&) -> const u8[:], bool {
    let value, ok = read_cstring(r.data, r.pos);
    if ok { r.pos += value.len + 1; }
    return value, ok;
}

// LEB128, as DWARF and Mach-O's link-edit data use it: at most ten bytes,
// and no bits past the 64th, as std's parse_uleb has it, but the whole
// unsigned range, which parse_uleb's i64 lengths cannot hold.
fn read_uleb128(r: Reader&) -> u64, bool {
    if !range_ok(r.data, r.pos, 0) { return 0, false; }
    let s = r.data[r.pos..];
    var v: u64 = 0;
    var shift = 0;
    var i = 0;
    while i < s.len && i < 10 {
        let b = s[i];
        if shift == 63 && (b & 0x7e) != 0 { return 0, false; }
        v |= (b & 0x7f) as u64 << shift;
        i++;
        if b < 0x80 {
            r.pos += i;
            return v, true;
        }
        shift += 7;
    }
    return 0, false;
}
// A signed one's last byte carries the sign in its 0x40 bit; in a tenth
// byte only the sign remains, so it is 0x00 or 0x7f.
fn read_sleb128(r: Reader&) -> i64, bool {
    if !range_ok(r.data, r.pos, 0) { return 0, false; }
    let s = r.data[r.pos..];
    var v: u64 = 0;
    var shift = 0;
    var i = 0;
    while i < s.len && i < 10 {
        let b = s[i];
        if shift == 63 && b != 0 && b != 0x7f { return 0, false; }
        v |= (b & 0x7f) as u64 << shift;
        i++;
        shift += 7;
        if b < 0x80 {
            if shift < 64 && (b & 0x40) != 0 { v |= ~(0 as u64) << shift; }
            r.pos += i;
            return v as! i64, true;
        }
    }
    return 0, false;
}

fn read_name(r: Reader&, width: i64) -> const u8[:], bool {
    let name, ok = read_name(r.data, r.pos, width);
    if ok { r.pos += width; }
    return name, ok;
}
fn skip(r: Reader&, size: i64) -> bool {
    if !range_ok(r.data, r.pos, size) { return false; }
    r.pos += size;
    return true;
}

// Consumes size bytes from the parent; the child's position starts at zero.
// On failure, returns an empty reader and leaves the parent in place.
fn subreader(r: Reader&, size: i64) -> Reader, bool {
    let data, ok = read_bytes(r, size);
    return reader(data), ok;
}
