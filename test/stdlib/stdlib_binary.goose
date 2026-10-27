// runtime-debug: external bytes, hostile ranges, borrowed slices and cursor failures.
import binary;

fn main() {
    let data: u8[12] = [255, 255, 0, 128, 255, 255, 255, 255, 65, 0, 88, 89];
    let u, uok = binary::read_u16le(data, 0);
    let neg, nok = binary::read_i16le(data, 0);
    let low, lok = binary::read_i16le(data, 2);
    let big, bok = binary::read_u32le(data, 4);
    assert(uok && u == 65535 && nok && neg == -1 && lok && low == -32768);
    assert(bok && big == 4294967295);
    let unaligned, aok = binary::read_u32le(data, 1);
    assert(aok && unaligned == 4286578943);
    let positive, pok = binary::read_i16le([255, 127], 0);
    assert(pok && positive == 32767);
    let zero, zok = binary::read_i16le([0, 0], 0);
    assert(zok && zero == 0);
    for at in [-1, 11, 12, 9223372036854775807, -9223372036854775807 - 1] {
        let v, ok = binary::read_u16le(data, at);
        assert(!ok && v == 0);
    }
    for size in [-1, 13, 9223372036854775807] {
        let bytes, ok = binary::read_bytes(data, 1, size);
        assert(!ok && bytes.len == 0);
    }
    let end, eok = binary::read_bytes(data, data.len, 0);
    assert(eok && end.len == 0);
    let badend, beok = binary::read_bytes(data, data.len + 1, 0);
    assert(!beok && badend.len == 0);
    let short, sok = binary::read_u32le(data, 9);
    assert(!sok && short == 0);
    let short_signed, ssok = binary::read_i16le(data, 11);
    assert(!ssok && short_signed == 0);

    let name, name_ok = binary::read_name(data, 8, 4);
    assert(name_ok && name == "A");
    let full, full_ok = binary::read_name(data, 10, 2);
    assert(full_ok && full == "XY");
    let empty, empty_ok = binary::read_name(data, 9, 1);
    assert(empty_ok && empty.len == 0);
    let no_field, no_field_ok = binary::read_name(data, 8, 5);
    assert(!no_field_ok && no_field.len == 0); // Early NUL cannot hide truncation.
    let empty_field, efok = binary::read_name(data, data.len, 0);
    assert(efok && empty_field.len == 0);

    var r = binary::reader(data);
    let ru, ruok = binary::read_u16le(r);
    let ri, riok = binary::read_i16le(r);
    let rb, rbok = binary::read_u32le(r);
    let rn, rnok = binary::read_name(r, 4);
    assert(ruok && ru == 65535 && riok && ri == -32768);
    assert(rbok && rb == 4294967295 && rnok && rn == "A" && r.pos == 12);
    let endbytes, endok = binary::read_bytes(r, 0);
    assert(endok && endbytes.len == 0);
    let past, pastok = binary::read_u16le(r);
    assert(!pastok && past == 0 && r.pos == 12);
    assert(binary::skip(r, 0)); // No sticky failure.

    var parent = binary::reader(data);
    assert(binary::skip(parent, 4));
    var child, childok = binary::subreader(parent, 6);
    assert(childok && parent.pos == 10 && child.pos == 0);
    assert(binary::skip(child, 4));
    var nested, nestedok = binary::subreader(child, 2);
    let nestedname, nestednameok = binary::read_name(nested, 2);
    assert(nestedok && nestednameok && nestedname == "A");
    let outside, outsideok = binary::read_u32le(nested);
    assert(!outsideok && outside == 0 && nested.pos == 2);
    let parentname, parentnameok = binary::read_name(parent, 2);
    assert(parentnameok && parentname == "XY");
    var failed, failedok = binary::subreader(parent, 1);
    assert(!failedok && parent.pos == 12 && failed.data.len == 0 && failed.pos == 0);

    var truncated = binary::reader(data[..2]);
    let large, largeok = binary::read_u32le(truncated);
    assert(!largeok && large == 0 && truncated.pos == 0);
    let retry, retryok = binary::read_i16le(truncated);
    assert(retryok && retry == -1 && truncated.pos == 2);
    var invalid = binary::reader(data);
    assert(!binary::skip(invalid, -1) && invalid.pos == 0);
    let huge, hugeok = binary::read_bytes(invalid, 9223372036854775807);
    assert(!hugeok && huge.len == 0 && invalid.pos == 0);
    invalid.pos = -1;
    let before, beforeok = binary::read_i16le(invalid);
    assert(!beforeok && before == 0 && invalid.pos == -1);
    invalid.pos = 9223372036854775807;
    assert(!binary::skip(invalid, 0));
    var none = binary::reader(data[..0]);
    var empty_child, empty_childok = binary::subreader(none, 0);
    assert(empty_childok && empty_child.data.len == 0 && empty_child.pos == 0);
    var names = binary::reader(data[8..]);
    let badname, badnameok = binary::read_name(names, 5);
    assert(!badnameok && badname.len == 0 && names.pos == 0);
    let goodname, goodnameok = binary::read_name(names, 4);
    assert(goodnameok && goodname == "A" && names.pos == 4);

    // Returned data borrows the original storage, including through a child.
    var source: u8[4] = [65, 66, 67, 68];
    var borrowed = binary::reader(source);
    var borrowed_child, borrowedok = binary::subreader(borrowed, 4);
    let view, viewok = binary::read_name(borrowed_child, 4);
    source[0] = 90;
    assert(borrowedok && viewok && view == "ZBCD");
    // Wider and big-endian values, bytes, and C strings.
    let wide: u8[10] = [1, 2, 3, 4, 5, 6, 7, 128, 0, 0];
    let w64, w64ok = binary::read_u64le(wide, 0);
    assert(w64ok && w64 == 0x8007060504030201);
    let s64, s64ok = binary::read_i64le(wide, 0);
    assert(s64ok && s64 == -9221395093405892095);
    let b64, b64ok = binary::read_u64be(wide, 0);
    assert(b64ok && b64 == 0x0102030405060780);
    let b32, b32ok = binary::read_u32be(wide, 4);
    assert(b32ok && b32 == 0x05060780);
    let b16, b16ok = binary::read_u16be(wide, 6);
    assert(b16ok && b16 == 0x0780);
    let s32, s32ok = binary::read_i32le(data, 4);
    assert(s32ok && s32 == -1);
    let one, oneok = binary::read_u8(wide, 9);
    assert(oneok && one == 0);
    for at in [-1, 3, 9223372036854775807] {
        let v, ok = binary::read_u64le(wide, at);
        let w, wok = binary::read_u64be(wide, at);
        assert(!ok && v == 0 && !wok && w == 0);
    }
    let none8, none8ok = binary::read_u8(wide, 10);
    assert(!none8ok && none8 == 0);
    let strtab: u8[9] = [0, 109, 97, 105, 110, 0, 120, 121, 122];   // "", "main", then no NUL
    let first, firstok = binary::read_cstring(strtab, 1);
    let blank, blankok = binary::read_cstring(strtab, 0);
    let open, openok = binary::read_cstring(strtab, 6);
    let past, pastcok = binary::read_cstring(strtab, 10);
    assert(firstok && first == "main" && blankok && blank.len == 0);
    assert(!openok && open.len == 0 && !pastcok && past.len == 0); // Unterminated: refused.
    var sr = binary::reader(strtab);
    binary::skip(sr, 1);
    let sname, snameok = binary::read_cstring(sr);
    assert(snameok && sname == "main" && sr.pos == 6);
    let stail, stailok = binary::read_cstring(sr);
    assert(!stailok && stail.len == 0 && sr.pos == 6);
    var wr = binary::reader(wide);
    let wa, waok = binary::read_u64be(wr);
    let wb, wbok = binary::read_u16be(wr);
    let wc, wcok = binary::read_u8(wr);
    assert(waok && wa == 0x0102030405060780 && wbok && wb == 0 && wr.pos == 10 && !wcok && wc == 0);

    // LEB128: the examples DWARF gives, the 64-bit limits, and what is refused.
    let leb: u8[22] = [2, 127, 0x80, 1, 0xe5, 0x8e, 0x26, 0x7f, 0x80, 0x7f,
                       0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x80, 0x80];
    var lr = binary::reader(leb);
    let u1, u1ok = binary::read_uleb128(lr);
    let u2, u2ok = binary::read_uleb128(lr);
    let u3, u3ok = binary::read_uleb128(lr);
    let u4, u4ok = binary::read_uleb128(lr);
    assert(u1ok && u1 == 2 && u2ok && u2 == 127 && u3ok && u3 == 128 && u4ok && u4 == 624485);
    let n1, n1ok = binary::read_sleb128(lr);
    let n2, n2ok = binary::read_sleb128(lr);
    assert(n1ok && n1 == -1 && n2ok && n2 == -128 && lr.pos == 10);
    let umax, umaxok = binary::read_uleb128(lr);
    assert(umaxok && umax == 0xffffffffffffffff && lr.pos == 20);
    let unterminated, utok = binary::read_uleb128(lr);
    assert(!utok && unterminated == 0 && lr.pos == 20);
    lr.pos = 10;
    let smax, smaxok = binary::read_sleb128(lr);
    assert(!smaxok && smax == 0 && lr.pos == 10);   // Bits past the 64th.
    let sminbytes: u8[10] = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f];
    var minr = binary::reader(sminbytes);
    let smin, sminok = binary::read_sleb128(minr);
    assert(sminok && smin == -9223372036854775807 - 1 && minr.pos == 10);
    let toolong: u8[11] = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0];
    var longr = binary::reader(toolong);
    let tl, tlok = binary::read_uleb128(longr);
    let tls, tlsok = binary::read_sleb128(longr);
    assert(!tlok && tl == 0 && !tlsok && tls == 0 && longr.pos == 0);
    longr.pos = -1;
    let neg, negok = binary::read_uleb128(longr);
    assert(!negok && neg == 0);
    print("binary: checked offsets, names, cursors and subreaders passed");
}
