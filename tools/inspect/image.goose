// What the inspector knows of an executable (docs/design/inspect.md §4.1),
// whatever its format: its sections, its symbols, its entry point, its
// debug sections; and the Mach-O 64-bit loader that fills it, from an
// executable and from a .dSYM's DWARF companion (elf.goose is the ELF one).
// Every read is checked, so a truncated or corrupt file is an error, never
// a fault. The files share one buffer, `data`: the executable from offset
// 0, its companion after it.
namespace image;
import std;
import binary;

let MH_MAGIC_64: u32 = 0xfeedfacf;
let LC_SYMTAB: u32 = 0x2;
let LC_SEGMENT_64: u32 = 0x19;
let LC_UUID: u32 = 0x1b;
let LC_FUNCTION_STARTS: u32 = 0x26;
let LC_MAIN: u32 = 0x80000028;

let CPU_ARM64: u32 = 0x0100000c;
let CPU_X86_64: u32 = 0x01000007;

// n_type: a stab (debugging entry, N_OSO and the like) has one of these bits.
let N_STAB: u8 = 0xe0;
let N_TYPE: u8 = 0x0e;
let N_SECT: u8 = 0x0e;
let N_EXT: u8 = 0x01;

struct Segment { name: u8[..16], vmaddr: u64, vmsize: u64, fileoff: u64, filesize: u64 }
struct Section {
    segment: u8[..16], name: u8[..32],  // no segment in an ELF file
    addr: u64, size: u64, offset: u64,  // offset 0: no bytes in the file (__bss)
    flags: u32,
    code: bool,                         // instructions: S_ATTR_PURE_INSTRUCTIONS, SHF_EXECINSTR
}
// A name is where it is in the file, so a symbol table costs no copies.
// `defined`: a symbol of the file's own code or data, not a debugging
// entry or an import.
struct Symbol { name_at: i64, name_len: i64, value: u64, kind: u8, sect: u8, desc: u16, defined: bool }

// A DWARF section, where it is in `data`, by its name without the format's
// prefix: debug_line for __debug_line and .debug_line.
struct DebugSection { name: u8[..32], at: i64, size: i64 }

var data: u8[>..] = [];
var segments: Segment[>..] = [];
var sections: Section[>..] = [];
var symbols: Symbol[>..] = [];
var function_starts: u64[>..] = [];
var cpu: u32 = 0;
var filetype: u32 = 0;
var entry: u64 = 0;            // The address main is at, 0 for none.
var uuid: u8[16] = [0; 16];
var format_name = "Mach-O";
var underscore = true;          // C names have a _ in front (Mach-O)
var debug_sections: DebugSection[>..] = [];
var debug_uuid: u8[16] = [0; 16];

// The file being read: where in data it starts, and whether it is the
// companion, of which only the DWARF is wanted.
var base = 0;
var debugging = false;

// A DWARF section's bytes by name (debug_line), empty where there is none.
fn debug_section(name: const u8[:]) -> const u8[:] {
    for d in debug_sections { if d.name == name { return data[d.at..d.at + d.size]; } }
    data[..0]
}

fn symbol_name(s: Symbol) -> const u8[:] { data[s.name_at..s.name_at + s.name_len] }
fn section_name(s: Section) -> u8[>..] { if s.segment.len == 0 { str(s.name) } else { str(s.segment, ",", s.name) } }
fn cpu_name() -> const u8[:] {
    if cpu == CPU_ARM64 { "arm64" } else if cpu == CPU_X86_64 { "x86_64" } else { "unknown" }
}

// The text-base address: what a file offset in __TEXT maps to.
fn text_base() -> u64 {
    for s in segments { if s.name == "__TEXT" { return s.vmaddr - s.fileoff; } }
    0
}

// Reads the file at path into data, from `base` on. "" on success.
fn read(path: const u8[:]) -> u8[>..] {
    base = data.len;
    if !read_file(path, data) { return str("cannot read ", path); }
    ""
}

// Whether the file just read is an ELF one, which elf::parse reads.
fn is_elf() -> bool {
    let file = data[base..];
    file.len >= 4 && file[0] == 0x7f && file[1] == 'E' && file[2] == 'L' && file[3] == 'F'
}

// Reads the Mach-O executable read last. "" on success, otherwise what
// was wrong.
fn parse_macho() -> u8[>..] {
    debugging = false;
    parse_file()
}

// Reads the DWARF companion dsymutil wrote for the executable, which must
// carry its UUID. "" on success.
fn load_debug(path: const u8[:]) -> u8[>..] {
    debugging = true;
    if read(path).len > 0 { return str("cannot read ", path); }
    let err = parse_file();
    if err.len > 0 { return err; }
    if debug_uuid != uuid { return str(path, " is the debug information of another build"); }
    ""
}

fn parse_file() -> u8[>..] {
    let file = data[base..];
    let magic, ok = binary::read_u32le(file, 0);
    if !ok || magic != MH_MAGIC_64 {
        if ok && (magic == 0xcafebabe || magic == 0xbebafeca) {
            return "a universal (fat) binary: thin it first with lipo -thin";
        }
        return "not a 64-bit Mach-O or ELF file";
    }
    var h = binary::reader(file);
    binary::skip(h, 4);
    let cputype, a = binary::read_u32le(h);
    binary::skip(h, 4);                  // cpusubtype
    let ft, b = binary::read_u32le(h);
    let ncmds, c = binary::read_u32le(h);
    let sizeofcmds, d = binary::read_u32le(h);
    binary::skip(h, 8);                  // flags, reserved
    if !(a && b && c && d) { return "truncated Mach-O header"; }
    if !debugging {
        cpu = cputype;
        filetype = ft;
    }
    var cmds, cmds_ok = binary::subreader(h, sizeofcmds);
    if !cmds_ok { return "load commands run past the end of the file"; }
    for i in ncmds {
        let at = cmds.pos;
        let cmd, e = binary::read_u32le(cmds);
        let cmdsize, f = binary::read_u32le(cmds);
        if !(e && f) || cmdsize < 8 { return str("truncated load command ", i); }
        cmds.pos = at;
        var lc, lc_ok = binary::subreader(cmds, cmdsize);
        if !lc_ok { return str("load command ", i, " runs past the others"); }
        binary::skip(lc, 8);
        let err: u8[>..] = if cmd == LC_SEGMENT_64 { segment(lc) }
                  else if cmd == LC_UUID { uuid_cmd(lc) }
                  else if debugging { "" }
                  else if cmd == LC_SYMTAB { symtab(lc) }
                  else if cmd == LC_FUNCTION_STARTS { starts(lc) }
                  else if cmd == LC_MAIN { main_cmd(lc) }
                  else { "" };
        if err.len > 0 { return str("load command ", i, ": ", err); }
    }
    // An entry offset is from the start of the file, in __TEXT.
    if !debugging && entry != 0 { entry += text_base(); }
    ""
}

fn name16(r: binary::Reader&) -> u8[..16] {
    let bytes, ok = binary::read_name(r, 16);
    var name: u8[..16] = [];
    if ok { name.append(bytes); }
    name
}

fn segment(lc: binary::Reader&) -> u8[>..] {
    let name = name16(lc);
    let vmaddr, a = binary::read_u64le(lc);
    let vmsize, b = binary::read_u64le(lc);
    let fileoff, c = binary::read_u64le(lc);
    let filesize, d = binary::read_u64le(lc);
    binary::skip(lc, 8);                 // maxprot, initprot
    let nsects, e = binary::read_u32le(lc);
    binary::skip(lc, 4);                 // flags
    if !(a && b && c && d && e) { return "truncated segment"; }
    if !debugging { segments.push(Segment { name, vmaddr, vmsize, fileoff, filesize }); }
    for i in nsects {
        let sectname = name16(lc);
        let segname = name16(lc);
        let addr, f = binary::read_u64le(lc);
        let size, g = binary::read_u64le(lc);
        let offset, h = binary::read_u32le(lc);
        binary::skip(lc, 12);            // align, reloff, nreloc
        let flags, j = binary::read_u32le(lc);
        let skipped = binary::skip(lc, 12);   // reserved1..3
        if !(f && g && h && j && skipped) { return str("truncated section ", i); }
        // A zero-fill section has an offset but no bytes behind it.
        let zerofill = (flags & 0xff) == 0x1 || (flags & 0xff) == 0xc;
        if !zerofill && offset != 0 && !binary::range_ok(data, base + offset, size as! i64) {
            return str("section ", segname, ",", sectname, " runs past the end of the file");
        }
        if debugging {
            if segname == "__DWARF" && !zerofill && offset != 0 {
                var dname: u8[..32] = [];
                dname.append(if starts_with(sectname, "__") { sectname[2..] } else { sectname[..] });
                debug_sections.push(DebugSection { name: dname, at: base + offset,
                                                   size: size as! i64 });
            }
            continue;
        }
        var longname: u8[..32] = [];
        longname.append(sectname);
        sections.push(Section { segment: segname, name: longname, addr: addr, size: size,
                                offset: if zerofill { 0 } else { offset }, flags: flags,
                                code: (flags & 0x80000000) != 0 });
    }
    ""
}

fn symtab(lc: binary::Reader&) -> u8[>..] {
    let symoff, a = binary::read_u32le(lc);
    let nsyms, b = binary::read_u32le(lc);
    let stroff, c = binary::read_u32le(lc);
    let strsize, d = binary::read_u32le(lc);
    if !(a && b && c && d) { return "truncated symbol table command"; }
    if !binary::range_ok(data, symoff, nsyms * 16) { return "symbols run past the end of the file"; }
    if !binary::range_ok(data, stroff, strsize) { return "strings run past the end of the file"; }
    let strings = data[stroff..stroff + strsize];
    var r = binary::reader(data);
    binary::skip(r, symoff);
    for i in nsyms {
        let strx, e = binary::read_u32le(r);
        let kind, f = binary::read_u8(r);
        let sect, g = binary::read_u8(r);
        let desc, h = binary::read_u16le(r);
        let value, j = binary::read_u64le(r);
        let name, k = binary::read_cstring(strings, strx);
        if !(e && f && g && h && j) { return str("truncated symbol ", i); }
        if !k { return str("symbol ", i, "'s name is not in the string table"); }
        let defined = (kind & N_STAB) == 0 && (kind & N_TYPE) == N_SECT;
        symbols.push(Symbol { name_at: stroff + strx, name_len: name.len, value: value,
                              kind: kind, sect: sect, desc: desc, defined: defined });
    }
    ""
}

// ULEB128 deltas from the start of __TEXT, ending in a zero.
fn starts(lc: binary::Reader&) -> u8[>..] {
    let dataoff, a = binary::read_u32le(lc);
    let datasize, b = binary::read_u32le(lc);
    if !(a && b) { return "truncated function starts command"; }
    if !binary::range_ok(data, dataoff, datasize) { return "function starts run past the end of the file"; }
    var r = binary::reader(data[dataoff..dataoff + datasize]);
    var addr = text_base();
    loop {
        let delta, ok = binary::read_uleb128(r);
        if !ok || delta == 0 { break; }
        addr += delta;
        function_starts.push(addr);
    }
    ""
}

fn uuid_cmd(lc: binary::Reader&) -> u8[>..] {
    let bytes, ok = binary::read_bytes(lc, 16);
    if !ok { return "truncated UUID"; }
    for b, i in bytes { if debugging { debug_uuid[i] = b; } else { uuid[i] = b; } }
    ""
}

fn main_cmd(lc: binary::Reader&) -> u8[>..] {
    let entryoff, ok = binary::read_u64le(lc);
    if !ok { return "truncated entry point"; }
    entry = entryoff;
    ""
}

// The section an address is in, -1 for none.
fn section_at(addr: u64) -> i64 {
    for s, i in sections { if addr >= s.addr && addr - s.addr < s.size { return i; } }
    -1
}

// Where the byte at addr is in the file, false where the file has none
// (zero-fill, or no section).
fn file_offset(addr: u64) -> i64, bool {
    let i = section_at(addr);
    if i < 0 || sections[i].offset == 0 { return 0, false; }
    return (sections[i].offset + (addr - sections[i].addr)) as! i64, true;
}

// The address of a file offset, false for one no section maps.
fn address_of(off: i64) -> u64, bool {
    for s in sections {
        if s.offset != 0 && off as! u64 >= s.offset && off as! u64 - s.offset < s.size {
            return s.addr + (off as! u64 - s.offset), true;
        }
    }
    return 0, false;
}

fn is_defined(s: Symbol) -> bool { s.defined }
