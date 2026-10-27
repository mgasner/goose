// Inspects an executable goose build made (docs/design/inspect.md): its
// sections, its symbols as Goose names, and its bytes.
//
//   goose build tools/inspect/inspect.goose -o inspect
//   ./inspect sections prog
//   ./inspect syms prog
//   ./inspect hex prog main_g          (a symbol, C or Goose name)
//   ./inspect hex prog 0x100000f40 64  (an address, and a byte count)
//   ./inspect hex prog +0x4000         (a file offset)
//   ./inspect at prog 0x100000f40
//   ./inspect lines prog main          (the line table over a function)
//   ./inspect source prog sort.goose:42
//   ./inspect disasm prog main         (arm64; with the source, where there are lines)
//
// The line information is the DWARF dsymutil collects into prog.dSYM, which
// a build with debug information (goose build --debug) has beside it.
import std;
import os;
import binary;
import .macho;
import .dwarf;
import .arm64;

fn fail(msg: const u8[:]) {
    write_stderr(str("inspect: ", msg, "\n"));
    exit(1);
}

fn usage() {
    write_stderr("""
        usage: inspect sections <exe>
               inspect syms <exe>
               inspect hex <exe> <symbol | 0xaddress | +fileoffset> [bytes]
               inspect at <exe> <0xaddress>
               inspect lines <exe> <symbol>
               inspect source <exe> <file:line>
               inspect disasm <exe> <symbol | 0xaddress [bytes]>
               inspect decode <file of "address word" lines, in hex>

        """);
    exit(2);
}

// --- Goose names ---------------------------------------------------------

// What the compiler names a function (CodeGen::Sanitize and CollectSpecs):
// `name_g`, or `ns_name_g<ns length>` in a namespace, then `_<id>` where one
// name has several specializations and `_<n>` to keep it unique. Decoded
// as `ns::name`, with `#id` for a specialization; false for a name that is
// not a Goose one (the runtime's gs_ names, the C library's).
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

fn goose_name(c: const u8[:]) -> u8[>..], bool {
    var out: u8[>..] = [];
    var i = c.len - 2;
    while i > 0 {
        if c[i] == '_' && c[i + 1] == 'g' {
            // The rest: digits, then any number of _digits.
            var j = i + 2;
            var nslen = 0;
            while j < c.len && is_digit(c[j]) { nslen = nslen * 10 + (c[j] - '0'); j++; }
            let hasns = j > i + 2;
            var id = -1;
            var good = true;
            while good && j < c.len {
                if c[j] != '_' || j + 1 >= c.len || !is_digit(c[j + 1]) { good = false; break; }
                j++;
                var n = 0;
                while j < c.len && is_digit(c[j]) { n = n * 10 + (c[j] - '0'); j++; }
                if id < 0 { id = n; }
            }
            if good {
                let base = c[..i];
                if hasns {
                    if nslen <= 0 || nslen + 1 >= base.len || base[nslen] != '_' { return out, false; }
                    format(out, base[..nslen], "::", base[nslen + 1..]);
                } else {
                    out.append(base);
                }
                if id >= 0 { format(out, "#", id); }
                return out, true;
            }
        }
        i--;
    }
    return out, false;
}

// A Mach-O symbol is the C name with an underscore in front.
fn c_name(s: macho::Symbol) -> const u8[:] {
    let n = macho::symbol_name(s);
    if n.len > 0 && n[0] == '_' { n[1..] } else { n }
}

// --- functions -----------------------------------------------------------

// A function: a defined symbol in a code section, running to the next one
// or to its section's end.
struct Function { sym: i64, start: u64, end: u64 }
var functions: Function[>..] = [];

fn is_code(sect: i64) -> bool {
    sect >= 0 && (macho::sections[sect].flags & 0x80000000) != 0   // S_ATTR_PURE_INSTRUCTIONS
}

fn collect_functions() {
    for s, i in macho::symbols {
        guard macho::is_defined(s);
        let sect = macho::section_at(s.value);
        guard is_code(sect);
        functions.push(Function { sym: i, start: s.value, end: 0 });
    }
    sort(functions) { a, b => a.start < b.start };
    // Aliases share an address: keep the first, the ends are the next start.
    var kept: Function[>..] = [];
    for f in functions { if kept.len == 0 || kept[kept.len - 1].start != f.start { kept.push(f); } }
    functions.clear();
    for f, i in kept {
        let sect = macho::sections[macho::section_at(f.start)];
        var end = sect.addr + sect.size;
        if i + 1 < kept.len && kept[i + 1].start < end { end = kept[i + 1].start; }
        functions.push(Function { sym: f.sym, start: f.start, end: end });
    }
}

// The function an address is in, -1 for none.
fn function_at(addr: u64) -> i64 {
    var lo = 0;
    var hi = functions.len;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if functions[mid].start <= addr { lo = mid + 1; } else { hi = mid; }
    }
    let i = lo - 1;
    if i >= 0 && addr < functions[i].end { i } else { -1 }
}

fn describe(out: u8[>..]&, f: Function) {
    let name = c_name(macho::symbols[f.sym]);
    let g, isgoose = goose_name(name);
    if isgoose { format(out, g, "  (", name, ")"); }
    else if starts_with(name, "gs_") { format(out, name, "  [runtime]"); }
    else { out.append(name); }
}

// --- numbers -------------------------------------------------------------

fn hex(out: u8[>..]&, v: u64, width: i64 = 0) { format_uint(out, v, 16, width, '0'); }

fn parse_number(s: const u8[:]) -> u64, bool {
    if starts_with(s, "0x") {
        let v, ok = parse_uint_hex(s[2..]);
        return v, ok && s.len > 2;
    }
    let v, ok = parse_int(s);
    return v as! u64, ok && v >= 0;
}

fn parse_uint_hex(s: const u8[:]) -> u64, bool {
    var v: u64 = 0;
    if s.len == 0 || s.len > 16 { return 0, false; }
    for c in s {
        let d: u64 = if c >= '0' && c <= '9' { c - '0' }
                     else if c >= 'a' && c <= 'f' { (c - 'a') as u64 + 10 }
                     else if c >= 'A' && c <= 'F' { (c - 'A') as u64 + 10 }
                     else { return 0, false; };
        v = v << 4 | d;
    }
    return v, true;
}

// A symbol by its C name or its Goose name; -1 for none.
fn find_function(name: const u8[:]) -> i64 {
    for f, i in functions {
        let c = c_name(macho::symbols[f.sym]);
        if c == name { return i; }
        let g, isgoose = goose_name(c);
        if isgoose && g == name { return i; }
    }
    -1
}

// --- commands ------------------------------------------------------------

fn cmd_sections() {
    var out: u8[>..] = [];
    format(out, "Mach-O ", macho::cpu_name(), ", ", macho::segments.len, " segments, ",
           macho::sections.len, " sections\n");
    out.append("uuid ");
    for b in macho::uuid { hex(out, b, 2); }
    if macho::entry != 0 { out.append("  entry 0x"); hex(out, macho::entry); }
    out.append("\n\n");
    for s in macho::segments {
        format(out, "segment ", s.name, "  vm 0x");
        hex(out, s.vmaddr, 9);
        out.append("..0x");
        hex(out, s.vmaddr + s.vmsize, 9);
        format(out, "  file +0x");
        hex(out, s.fileoff);
        format(out, " size 0x");
        hex(out, s.filesize);
        out.append("\n");
        for t in macho::sections {
            guard t.segment == s.name;
            format(out, "  ", t.segment, ",", t.name);
            for k in max(0, 24 - t.segment.len - t.name.len) { out.push(' '); }
            out.append("0x");
            hex(out, t.addr, 9);
            format(out, "  size 0x");
            hex(out, t.size, 6);
            if t.offset != 0 { out.append("  file +0x"); hex(out, t.offset); }
            else { out.append("  (zero-fill)"); }
            out.append("\n");
        }
    }
    write_stdout(out);
}

fn cmd_syms() {
    var out: u8[>..] = [];
    var goose = 0;
    var runtime = 0;
    for f in functions {
        let c = c_name(macho::symbols[f.sym]);
        let g, isgoose = goose_name(c);
        if isgoose { goose++; } else if starts_with(c, "gs_") { runtime++; }
    }
    format(out, functions.len, " functions: ", goose, " Goose, ", runtime, " runtime, ",
           functions.len - goose - runtime, " other");
    if macho::function_starts.len > 0 {
        format(out, "; the function starts table has ", macho::function_starts.len);
    }
    out.append("\n");
    for f in functions {
        out.append("0x");
        hex(out, f.start, 9);
        out.append(" ");
        format_uint(out, f.end - f.start, 10, 6, ' ');
        out.append("  ");
        describe(out, f);
        out.append("\n");
    }
    write_stdout(out);
}

fn cmd_hex(target: const u8[:], count_arg: const u8[:]) {
    var start: u64 = 0;
    var count: u64 = 256;
    if starts_with(target, "+") {
        let off, ok = parse_number(target[1..]);
        if !ok || off >= macho::data.len as u64 { fail(str("no file offset ", target)); }
        let addr, mapped = macho::address_of(off as! i64);
        if !mapped { fail(str("no section holds file offset ", target)); }
        start = addr;
    } else if starts_with(target, "0x") {
        let addr, ok = parse_number(target);
        if !ok { fail(str("not an address: ", target)); }
        start = addr;
    } else {
        let i = find_function(target);
        if i < 0 { fail(str("no function named ", target)); }
        start = functions[i].start;
        count = functions[i].end - start;
    }
    if count_arg.len > 0 {
        let n, ok = parse_number(count_arg);
        if !ok { fail(str("not a byte count: ", count_arg)); }
        count = n;
    }
    let sect = macho::section_at(start);
    if sect < 0 { fail("no section holds that address"); }
    let s = macho::sections[sect];
    if s.offset == 0 { fail(str(macho::section_name(s), " has no bytes in the file")); }
    let end = min(start + count, s.addr + s.size);
    var out: u8[>..] = [];
    format(out, macho::section_name(s), "\n");
    var fn_shown = -1;
    var row = start & ~(15 as u64);
    while row < end {
        // A function starting in this row gets a line of its own.
        for k in 16 {
            let a = row + k as u64;
            guard a >= start && a < end;
            let f = function_at(a);
            guard f >= 0 && f != fn_shown && (functions[f].start == a || a == start);
            fn_shown = f;
            out.append("                    ");
            describe(out, functions[f]);
            if functions[f].start != a { out.append(" +0x"); hex(out, a - functions[f].start); }
            out.append(":\n");
        }
        let off, ok = macho::file_offset(max(row, start));
        let rowoff = off - (max(row, start) - row) as! i64;
        out.append("0x");
        hex(out, row, 9);
        out.append("  +");
        hex(out, rowoff as! u64, 6);
        out.append("  ");
        for k in 16 {
            let a = row + k as u64;
            if a >= start && a < end { hex(out, macho::data[rowoff + k], 2); out.push(' '); }
            else { out.append("   "); }
            if k == 7 { out.push(' '); }
        }
        out.append(" |");
        for k in 16 {
            let a = row + k as u64;
            if a >= start && a < end {
                let c = macho::data[rowoff + k];
                out.push(if c >= 32 && c < 127 { c } else { '.' });
            } else {
                out.push(' ');
            }
        }
        out.append("|\n");
        row += 16;
    }
    write_stdout(out);
}

fn cmd_at(target: const u8[:]) {
    let addr, ok = parse_number(target);
    if !ok { fail(str("not an address: ", target)); }
    var out: u8[>..] = [];
    out.append("0x");
    hex(out, addr);
    let sect = macho::section_at(addr);
    if sect < 0 {
        out.append(": in no section\n");
        write_stdout(out);
        return;
    }
    format(out, "  in ", macho::section_name(macho::sections[sect]));
    let off, mapped = macho::file_offset(addr);
    if mapped { out.append("  file +0x"); hex(out, off as! u64); }
    out.append("\n");
    let f = function_at(addr);
    if f >= 0 {
        out.append("  ");
        describe(out, functions[f]);
        out.append(" +0x");
        hex(out, addr - functions[f].start);
        out.append(" of 0x");
        hex(out, functions[f].end - functions[f].start);
        out.append("\n");
    }
    if have_lines {
        let r = dwarf::row_at(addr);
        if r >= 0 { out.append("  "); describe_row(out, dwarf::rows[r], true); out.append("\n"); }
    }
    write_stdout(out);
}

// --- line information ----------------------------------------------------

var have_lines = false;
var lines_note: u8[>..] = [];   // Why there are none, for the commands that need them.

fn basename(path: const u8[:]) -> const u8[:] {
    let i = rfind(path, "/");
    if i < 0 { path } else { path[i + 1..] }
}

// The executable's DWARF companion, where dsymutil puts it.
fn load_lines(exe: const u8[:]) {
    let companion = str(exe, ".dSYM/Contents/Resources/DWARF/", basename(exe));
    if !file_exists(companion) {
        lines_note = str("no line information: ", companion, " is not there (build with --debug)");
        return;
    }
    let err = macho::load_debug(companion);
    if err.len > 0 { lines_note = str("no line information: ", err); return; }
    let derr = dwarf::load();
    if derr.len > 0 { lines_note = str("no line information: ", companion, ": ", derr); return; }
    dwarf::index();
    have_lines = true;
}

fn need_lines() { if !have_lines { fail(lines_note); } }

// Source files, read once each, and where their lines start.
struct Source { path_at: i64, path_len: i64, text_at: i64, text_len: i64, lines_at: i64, nlines: i64 }
var sources: Source[>..] = [];
var source_paths: u8[>..] = [];
var source_text: u8[>..] = [];
var line_starts: i64[>..] = [];

fn source_index(path: const u8[:]) -> i64 {
    for s, i in sources { if source_paths[s.path_at..s.path_at + s.path_len] == path { return i; } }
    let path_at = source_paths.len;
    source_paths.append(path);
    let text_at = source_text.len;
    let lines_at = line_starts.len;
    if read_file(path, source_text) {
        line_starts.push(text_at);
        for i in text_at..source_text.len { if source_text[i] == '\n' { line_starts.push(i + 1); } }
    }
    sources.push(Source { path_at: path_at, path_len: path.len, text_at: text_at,
                          text_len: source_text.len - text_at, lines_at: lines_at,
                          nlines: line_starts.len - lines_at });
    sources.len - 1
}

// The text of a line of a file, trimmed; empty where the file cannot be read.
fn source_line(path: const u8[:], line: i64) -> const u8[:] {
    let si = source_index(path);
    let s = sources[si];
    if line < 1 || line > s.nlines { return source_text[..0]; }
    let start = line_starts[s.lines_at + line - 1];
    var end = s.text_at + s.text_len;
    if line < s.nlines { end = line_starts[s.lines_at + line] - 1; }
    trim(source_text[start..end])
}

// file:line:col of a row, and the line's text if the file is there.
fn describe_row(out: u8[>..]&, r: dwarf::Row, text: bool) {
    if r.file < 0 { out.append("?"); return; }
    let path = dwarf::file_path(dwarf::files[r.file as i64]);
    // Line 0 is code of no one line, which the C compiler made or merged.
    if r.line == 0 { format(out, basename(path), ": no line"); return; }
    format(out, basename(path), ":", r.line);
    // A Goose line's column is the generated C's, which #line cannot change.
    if r.col > 0 && !ends_with(path, ".goose") { format(out, ":", r.col); }
    if text && r.line > 0 {
        let t = source_line(path, r.line);
        if t.len > 0 { format(out, "    ", t); }
    }
}

fn cmd_lines(target: const u8[:]) {
    need_lines();
    let fi = find_function(target);
    if fi < 0 { fail(str("no function named ", target)); }
    let f = functions[fi];
    var out: u8[>..] = [];
    describe(out, f);
    out.append("\n");
    // The rows in the function's range, in address order, each up to the next.
    var shown_file = -1;
    var shown_line = -1;
    for oi in dwarf::order.len {
        let r = dwarf::rows[dwarf::order[oi]];
        guard r.addr >= f.start && r.addr < f.end && !r.end;
        guard r.file != shown_file || r.line != shown_line;
        shown_file = r.file;
        shown_line = r.line;
        out.append("  0x");
        hex(out, r.addr, 9);
        out.append("  ");
        describe_row(out, r, true);
        out.append("\n");
    }
    write_stdout(out);
}

// Every address range a source line compiled to, adjacent ones merged.
struct Range { start: u64, end: u64 }

fn cmd_source(target: const u8[:]) {
    need_lines();
    let colon = rfind(target, ":");
    if colon <= 0 { fail(str("not file:line: ", target)); }
    let want = target[..colon];
    let line, ok = parse_int(target[colon + 1..]);
    if !ok { fail(str("not a line number: ", target[colon + 1..])); }
    var ranges: Range[>..] = [];
    var path: u8[>..] = [];
    for oi in dwarf::order.len {
        let r = dwarf::rows[dwarf::order[oi]];
        guard !r.end && r.file >= 0 && r.line == line;
        let p = dwarf::file_path(dwarf::files[r.file as i64]);
        guard p == want || ends_with(p, str("/", want));
        // Up to the next row's address.
        let end = if oi + 1 < dwarf::order.len { dwarf::rows[dwarf::order[oi + 1]].addr } else { r.addr };
        guard end > r.addr;
        if path.len == 0 { path.append(p); }
        if ranges.len > 0 && ranges[ranges.len - 1].end == r.addr { ranges[ranges.len - 1].end = end; }
        else { ranges.push(Range { start: r.addr, end: end }); }
    }
    if ranges.len == 0 { fail(str("no code for ", target)); }
    var out: u8[>..] = [];
    format(out, basename(path), ":", line, "    ", source_line(path, line), "\n");
    for g in ranges {
        out.append("  0x");
        hex(out, g.start, 9);
        out.append("..0x");
        hex(out, g.end, 9);
        format(out, "  ", g.end - g.start, " bytes");
        let fn_i = function_at(g.start);
        if fn_i >= 0 { out.append("  "); describe(out, functions[fn_i]); }
        out.append("\n");
    }
    write_stdout(out);
}

// --- disassembly ---------------------------------------------------------

// `name+0x10` for an address in a function, the section otherwise.
fn symbolize(out: u8[>..]&, a: u64) {
    let f = function_at(a);
    if f >= 0 {
        let name = c_name(macho::symbols[functions[f].sym]);
        let g, isgoose = goose_name(name);
        out.append(if isgoose { g } else { name });
        if a != functions[f].start { out.append("+0x"); hex(out, a - functions[f].start); }
        return;
    }
    let s = macho::section_at(a);
    if s >= 0 {
        out.append(macho::section_name(macho::sections[s]));
        out.append("+0x");
        hex(out, a - macho::sections[s].addr);
    }
}

fn cmd_disasm(target: const u8[:], count_arg: const u8[:]) {
    if macho::cpu != macho::CPU_ARM64 { fail(str("disassembly is arm64 only; this is ", macho::cpu_name())); }
    var start: u64 = 0;
    var end: u64 = 0;
    if starts_with(target, "0x") {
        let a, ok = parse_number(target);
        if !ok { fail(str("not an address: ", target)); }
        start = a & ~(3 as u64);
        var n: u64 = 64;
        if count_arg.len > 0 {
            let c, cok = parse_number(count_arg);
            if !cok { fail(str("not a byte count: ", count_arg)); }
            n = c;
        }
        end = start + n;
    } else {
        let i = find_function(target);
        if i < 0 { fail(str("no function named ", target)); }
        start = functions[i].start;
        end = functions[i].end;
    }
    let sect = macho::section_at(start);
    if sect < 0 || !is_code(sect) { fail("no code at that address"); }
    let s = macho::sections[sect];
    end = min(end, s.addr + s.size);
    var out: u8[>..] = [];
    var known = 0;
    var total = 0;
    var last_file = -2;
    var last_line = -1;
    var a = start;
    while a + 4 <= end {
        if a == start || function_at(a) >= 0 && functions[function_at(a)].start == a {
            let f = function_at(a);
            if f >= 0 { out.append("\n"); describe(out, functions[f]); out.append(":\n"); }
        }
        if have_lines {
            let ri = dwarf::row_at(a);
            if ri >= 0 {
                let r = dwarf::rows[ri];
                if (r.file != last_file || r.line != last_line) && r.line != 0 {
                    out.append("    ; ");
                    describe_row(out, r, true);
                    out.append("\n");
                    last_file = r.file;
                    last_line = r.line;
                }
            }
        }
        let off, mapped = macho::file_offset(a);
        let word, ok = binary::read_u32le(macho::data, off);
        if !mapped || !ok { break; }
        out.append("  ");
        hex(out, a, 9);
        out.append("  ");
        hex(out, word, 8);
        out.append("  ");
        var text: u8[>..] = [];
        let d = arm64::decode(word, a, text);
        total++;
        if d.known { known++; }
        // The mnemonic padded to a column, as objdump has it.
        let tab = find(text, "\t");
        if tab >= 0 {
            out.append(text[..tab]);
            for k in max(1, 8 - tab) { out.push(' '); }
            out.append(text[tab + 1..]);
        } else {
            out.append(text);
        }
        if d.has_target { out.append(" <"); symbolize(out, d.target); out.append(">"); }
        out.append("\n");
        a += 4;
    }
    if known < total { format(out, "\n", total - known, " of ", total, " instructions not decoded (.word)\n"); }
    write_stdout(out);
}

// Decodes the arm64 words of a file of `address word` lines (hex), one
// per line: what the decoder makes of encodings with no executable around
// them, as the test suite checks it. What follows the word on a line, and
// a line starting with #, is left alone.
fn cmd_decode(path: const u8[:]) {
    var text: u8[>..] = [];
    if !read_file(path, text) { fail(str("cannot read ", path)); }
    var out: u8[>..] = [];
    var bad = false;
    each_split(text, '\n') { line =>
        let parts = words(line);
        if parts.len > 0 && parts[0].len > 0 && parts[0][0] == '#' {
        } else if parts.len >= 2 {
            let pc, pok = parse_uint_hex(parts[0]);
            let word, wok = parse_uint_hex(parts[1]);
            if !pok || !wok || word > 0xffffffff { bad = true; }
            else {
                format(out, parts[0], " ", parts[1], " ");
                arm64::decode(word as! u32, pc, out);
                out.append("\n");
            }
        } else if parts.len != 0 {
            bad = true;
        }
    };
    if bad { fail(str(path, ": not lines of a hex address and a hex word")); }
    write_stdout(out);
}

fn main() {
    let a = args();
    if a.len == 3 && a[1] == "decode" { cmd_decode(a[2]); return; }
    if a.len < 3 { usage(); }
    let cmd = a[1];
    let err = macho::load(a[2]);
    if err.len > 0 { fail(str(a[2], ": ", err)); }
    collect_functions();
    load_lines(a[2]);
    if cmd == "sections" { cmd_sections(); }
    else if cmd == "syms" { cmd_syms(); }
    else if cmd == "hex" && a.len >= 4 { cmd_hex(a[3], if a.len >= 5 { a[4] } else { "" }); }
    else if cmd == "at" && a.len >= 4 { cmd_at(a[3]); }
    else if cmd == "lines" && a.len >= 4 { cmd_lines(a[3]); }
    else if cmd == "source" && a.len >= 4 { cmd_source(a[3]); }
    else if cmd == "disasm" && a.len >= 4 { cmd_disasm(a[3], if a.len >= 5 { a[4] } else { "" }); }
    else { usage(); }
}
