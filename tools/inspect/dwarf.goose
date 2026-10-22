// DWARF line tables (docs/design/inspect.md §4.1): every unit's line
// program in __debug_line, versions 2 to 5, 32- and 64-bit, run to the
// rows of address, file, line and column it describes. The sections come
// from the Mach-O companion (macho::debug_section); offsets into them are
// checked like every other read, so a corrupt table is an error.
namespace dwarf;
import std;
import binary;
import .macho;

// A file of a unit's table; its name is a slice of data, as its directory's
// and the unit's compilation directory, which a relative directory is under.
struct File { comp_at: i64, comp_len: i64, dir_at: i64, dir_len: i64, name_at: i64, name_len: i64 }
// One row of a line table: from addr on, until the next row (or the end of
// its sequence), the code is the line's.
struct Row { addr: u64, file: i32, line: i32, col: i32, stmt: bool, end: bool }

var files: File[>..] = [];
var rows: Row[>..] = [];

let DW_FORM_block: u64 = 0x09;
let DW_FORM_block1: u64 = 0x0a;
let DW_FORM_data1: u64 = 0x0b;
let DW_FORM_data2: u64 = 0x05;
let DW_FORM_data4: u64 = 0x06;
let DW_FORM_data8: u64 = 0x07;
let DW_FORM_data16: u64 = 0x1e;
let DW_FORM_string: u64 = 0x08;
let DW_FORM_strp: u64 = 0x0e;
let DW_FORM_udata: u64 = 0x0f;
let DW_FORM_line_strp: u64 = 0x1f;
let DW_FORM_strx: u64 = 0x1a;
let DW_LNCT_path: u64 = 1;
let DW_LNCT_directory_index: u64 = 2;

fn file_dir(f: File) -> const u8[:] { macho::data[f.dir_at..f.dir_at + f.dir_len] }
fn file_name(f: File) -> const u8[:] { macho::data[f.name_at..f.name_at + f.name_len] }

// The file's path as the table spells it: its name, under its directory
// where the name is relative.
fn file_path(f: File) -> u8[>..] {
    let name = file_name(f);
    let dir = file_dir(f);
    let comp = macho::data[f.comp_at..f.comp_at + f.comp_len];
    if name.len > 0 && name[0] == '/' { return str(name); }
    if dir.len == 0 { return if comp.len == 0 { str(name) } else { str(comp, "/", name) }; }
    if dir[0] == '/' || comp.len == 0 || dir == comp { return str(dir, "/", name); }
    str(comp, "/", dir, "/", name)
}

// A string a form gives: in the header itself, or an offset into
// __debug_str or __debug_line_str. Its position in data and its length;
// r_at is where r's bytes start in data.
fn read_string(r: binary::Reader&, form: u64, offset64: bool, r_at: i64) -> i64, i64, bool {
    if form == DW_FORM_string {
        let s, ok = binary::read_cstring(r);
        if !ok { return 0, 0, false; }
        return r_at + r.pos - s.len - 1, s.len, true;
    }
    if form == DW_FORM_strp || form == DW_FORM_line_strp {
        let off, ok = read_offset(r, offset64);
        if !ok { return 0, 0, false; }
        let name = if form == DW_FORM_strp { "__debug_str" } else { "__debug_line_str" };
        let strings = macho::debug_section(name);
        let s, sok = binary::read_cstring(strings, off as! i64);
        if !sok { return 0, 0, false; }
        return section_start(name) + off as! i64, s.len, true;
    }
    return 0, 0, false;
}

fn section_start(name: const u8[:]) -> i64 {
    for d in macho::debug_sections { if d.name == name { return d.at; } }
    0
}

fn read_offset(r: binary::Reader&, offset64: bool) -> u64, bool {
    if offset64 { let v, ok = binary::read_u64le(r); return v, ok; }
    let v, ok = binary::read_u32le(r);
    return v, ok;
}

// Skips a value of a form no entry here uses (a timestamp, a size, an MD5).
fn skip_form(r: binary::Reader&, form: u64, offset64: bool) -> bool {
    if form == DW_FORM_data1 { return binary::skip(r, 1); }
    if form == DW_FORM_data2 { return binary::skip(r, 2); }
    if form == DW_FORM_data4 { return binary::skip(r, 4); }
    if form == DW_FORM_data8 { return binary::skip(r, 8); }
    if form == DW_FORM_data16 { return binary::skip(r, 16); }
    if form == DW_FORM_udata || form == DW_FORM_strx {
        let v, ok = binary::read_uleb128(r);
        return ok;
    }
    if form == DW_FORM_strp || form == DW_FORM_line_strp {
        let v, ok = read_offset(r, offset64);
        return ok;
    }
    if form == DW_FORM_string {
        let s, ok = binary::read_cstring(r);
        return ok;
    }
    if form == DW_FORM_block || form == DW_FORM_block1 {
        var n: u64 = 0;
        var ok = false;
        if form == DW_FORM_block { n, ok = binary::read_uleb128(r); }
        else { let b, bok = binary::read_u8(r); n = b; ok = bok; }
        return ok && binary::skip(r, n as! i64);
    }
    false
}

// An unsigned value of a form: a directory index.
fn read_udata(r: binary::Reader&, form: u64) -> u64, bool {
    if form == DW_FORM_udata { let v, ok = binary::read_uleb128(r); return v, ok; }
    if form == DW_FORM_data1 { let v, ok = binary::read_u8(r); return v, ok; }
    if form == DW_FORM_data2 { let v, ok = binary::read_u16le(r); return v, ok; }
    if form == DW_FORM_data4 { let v, ok = binary::read_u32le(r); return v, ok; }
    if form == DW_FORM_data8 { let v, ok = binary::read_u64le(r); return v, ok; }
    return 0, false;
}

// Reads every unit of __debug_line. "" on success, else what was wrong.
fn load() -> u8[>..] {
    let line = macho::debug_section("__debug_line");
    let line_at = section_start("__debug_line");
    var r = binary::reader(line);
    var unit = 0;
    while r.pos < line.len {
        let err = load_unit(r, line_at);
        if err.len > 0 { return str("line table unit ", unit, ": ", err); }
        unit++;
    }
    ""
}

// The directory and file tables of a unit, as entries of `files` from
// `first` on; the unit's file n is files[first + n] (from 1 before
// version 5, when 0 meant the unit's own file).
struct Dir { at: i64, len: i64 }

fn load_unit(r: binary::Reader&, line_at: i64) -> u8[>..] {
    let len32, a = binary::read_u32le(r);
    if !a { return "truncated length"; }
    var offset64 = false;
    var length: u64 = len32;
    if len32 == 0xffffffff {
        offset64 = true;
        let len64, b = binary::read_u64le(r);
        if !b { return "truncated length"; }
        length = len64;
    }
    var u, uok = binary::subreader(r, length as! i64);
    if !uok { return "runs past the end of the section"; }
    let unit_at = line_at + r.pos - u.data.len;
    let version, c = binary::read_u16le(u);
    if !c || version < 2 || version > 5 { return str("version ", version, " is not one this reads"); }
    var address_size: u8 = 8;
    if version >= 5 {
        let asz, d = binary::read_u8(u);
        let ssz, e = binary::read_u8(u);
        if !(d && e) { return "truncated header"; }
        address_size = asz;
    }
    let header_length, f = read_offset(u, offset64);
    if !f { return "truncated header"; }
    let h_at = unit_at + u.pos;
    var h, hok = binary::subreader(u, header_length as! i64);
    if !hok { return "header runs past the unit"; }
    let min_inst, g = binary::read_u8(h);
    if version >= 4 { binary::skip(h, 1); }     // maximum_operations_per_instruction
    let default_stmt, i = binary::read_u8(h);
    let line_base_u, j = binary::read_u8(h);
    let line_range, k = binary::read_u8(h);
    let opcode_base, l = binary::read_u8(h);
    if !(g && i && j && k && l) || line_range == 0 || opcode_base == 0 { return "bad header"; }
    let line_base: i64 = line_base_u as! i8;
    var oplens: u8[256] = [0; 256];
    for n in 1..opcode_base as i64 {
        let len, ok = binary::read_u8(h);
        if !ok { return "truncated opcode lengths"; }
        oplens[n] = len;
    }

    let first = files.len;
    var dirs: Dir[>..] = [];
    if version >= 5 {
        // Entry formats, then the entries, for the directories and the files.
        for table in 2 {
            let nformats, m = binary::read_u8(h);
            if !m { return "truncated entry formats"; }
            var kinds: u64[..16] = [];
            var forms: u64[..16] = [];
            for n in nformats as i64 {
                let kind, o = binary::read_uleb128(h);
                let form, p = binary::read_uleb128(h);
                if !(o && p) || kinds.len == 16 { return "bad entry formats"; }
                kinds.push(kind);
                forms.push(form);
            }
            let count, q = binary::read_uleb128(h);
            if !q || count > 1000000 { return "bad entry count"; }
            for n in count as! i64 {
                var path_at = 0;
                var path_len = 0;
                var dir: u64 = 0;
                for kind, x in kinds {
                    if kind == DW_LNCT_path {
                        let at, len, ok = read_string(h, forms[x], offset64, h_at);
                        if !ok { return "bad path"; }
                        path_at = at;
                        path_len = len;
                    } else if kind == DW_LNCT_directory_index {
                        let v, ok = read_udata(h, forms[x]);
                        if !ok { return "bad directory index"; }
                        dir = v;
                    } else if !skip_form(h, forms[x], offset64) {
                        return str("an entry form this does not read: ", forms[x]);
                    }
                }
                if table == 0 { dirs.push(Dir { at: path_at, len: path_len }); }
                else {
                    if dir >= dirs.len as u64 { return "a file in no directory"; }
                    let d = dirs[dir as! i64];
                    files.push(File { comp_at: dirs[0].at, comp_len: dirs[0].len, dir_at: d.at,
                                      dir_len: d.len, name_at: path_at, name_len: path_len });
                }
            }
        }
    } else {
        // Version 2 to 4: the unit's directory is 0, the others are listed;
        // the files from 1 on. Entry 0 stands for the unit's own file, which
        // the header does not name, so it is the first listed.
        dirs.push(Dir { at: 0, len: 0 });
        loop {
            let s, ok = binary::read_cstring(h);
            if !ok { return "truncated directories"; }
            if s.len == 0 { break; }
            dirs.push(Dir { at: h_at + h.pos - s.len - 1, len: s.len });
        }
        files.push(File { comp_at: 0, comp_len: 0, dir_at: 0, dir_len: 0, name_at: 0, name_len: 0 });
        loop {
            let s, ok = binary::read_cstring(h);
            if !ok { return "truncated files"; }
            if s.len == 0 { break; }
            let name_at = h_at + h.pos - s.len - 1;
            let dir, d1 = binary::read_uleb128(h);
            let mtime, d2 = binary::read_uleb128(h);
            let size, d3 = binary::read_uleb128(h);
            if !(d1 && d2 && d3) || dir >= dirs.len as u64 { return "bad file entry"; }
            let d = dirs[dir as! i64];
            files.push(File { comp_at: 0, comp_len: 0, dir_at: d.at, dir_len: d.len,
                              name_at: name_at, name_len: s.len });
        }
    }
    let nfiles = files.len - first;

    // The program: the rest of the unit.
    var addr: u64 = 0;
    var file: i64 = 1;
    var lineno: i64 = 1;
    var col: i64 = 0;
    var stmt = default_stmt != 0;
    fn emit(end: bool) {
        // A file the table does not have is the table's error, not one to
        // index with.
        let fi = if file >= 0 && file < nfiles { first + file } else { -1 };
        rows.push(Row { addr: addr, file: fi as! i32, line: lineno as! i32, col: col as! i32,
                        stmt: stmt, end: end });
    }
    while u.pos < u.data.len {
        let op, ok = binary::read_u8(u);
        if !ok { return "truncated program"; }
        if op >= opcode_base {
            let adj: i64 = op - opcode_base;
            addr += ((adj / line_range) * min_inst) as! u64;
            lineno += line_base + adj % line_range;
            emit(false);
        } else if op == 0 {
            let len, lok = binary::read_uleb128(u);
            if !lok || len == 0 { return "bad extended opcode"; }
            var ext, eok = binary::subreader(u, len as! i64);
            let sub, sok = binary::read_u8(ext);
            if !(eok && sok) { return "truncated extended opcode"; }
            if sub == 1 {
                emit(true);
                addr = 0;
                file = 1;
                lineno = 1;
                col = 0;
                stmt = default_stmt != 0;
            } else if sub == 2 {
                if address_size == 8 { let v, vok = binary::read_u64le(ext); addr = v; if !vok { return "bad address"; } }
                else { let v, vok = binary::read_u32le(ext); addr = v; if !vok { return "bad address"; } }
            }
            // Others (define_file, set_discriminator) change nothing shown.
        } else if op == 1 {
            emit(false);
        } else if op == 2 {
            let v, vok = binary::read_uleb128(u);
            if !vok { return "truncated advance_pc"; }
            addr += v * min_inst;
        } else if op == 3 {
            let v, vok = binary::read_sleb128(u);
            if !vok { return "truncated advance_line"; }
            lineno += v;
        } else if op == 4 {
            let v, vok = binary::read_uleb128(u);
            if !vok { return "truncated set_file"; }
            file = v as! i64;
        } else if op == 5 {
            let v, vok = binary::read_uleb128(u);
            if !vok { return "truncated set_column"; }
            col = v as! i64;
        } else if op == 6 {
            stmt = !stmt;
        } else if op == 8 {
            addr += ((255 - opcode_base) / line_range) as u64 * min_inst;
        } else if op == 9 {
            let v, vok = binary::read_u16le(u);
            if !vok { return "truncated fixed_advance_pc"; }
            addr += v;
        } else {
            // basic_block, prologue_end, epilogue_begin, set_isa and those
            // this does not know: skip their arguments.
            for n in oplens[op] as i64 {
                let v, vok = binary::read_uleb128(u);
                if !vok { return "truncated opcode arguments"; }
            }
        }
    }
    ""
}

// The row whose range holds addr, -1 for none: rows sorted by address
// within each sequence, so the last row at or below addr whose sequence
// has not ended there.
var order: i64[>..] = [];

fn index() {
    for r, i in rows { order.push(i); }
    stable_sort(order) { a, b => rows[a].addr < rows[b].addr };
}

fn row_at(addr: u64) -> i64 {
    var lo = 0;
    var hi = order.len;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if rows[order[mid]].addr <= addr { lo = mid + 1; } else { hi = mid; }
    }
    // Several rows can start at one address; the last one before a later
    // address is the one in force, unless it ends a sequence.
    var i = lo - 1;
    while i >= 0 && rows[order[i]].end && rows[order[i]].addr == addr { i--; }
    if i < 0 || rows[order[i]].end { return -1; }
    order[i]
}
