// ELF64 little-endian files (docs/design/inspect.md §7): executables,
// shared objects and relocatable objects, for x86-64 and arm64. Fills what
// image.goose describes: the sections, the symbols, the entry point, the
// build ID as the UUID, and the debug sections, which an ELF file carries
// itself. A relocatable object's sections are all at address 0, so they
// are given addresses as a linker would lay them out, and the relocations
// of its debug sections are applied against those, which makes its line
// table's addresses and string offsets mean what they would linked.
namespace elf;
import std;
import binary;
import .image;

let SHT_SYMTAB: u32 = 2;
let SHT_NOTE: u32 = 7;
let SHT_NOBITS: u32 = 8;
let SHT_RELA: u32 = 4;
let SHF_ALLOC: u64 = 0x2;
let SHF_EXECINSTR: u64 = 0x4;
let SHF_COMPRESSED: u64 = 0x800;
let ET_REL: u16 = 1;
let EM_X86_64: u16 = 0x3e;
let EM_AARCH64: u16 = 0xb7;

// A section header as the file has it, and the address it is given.
struct Header { name: u32, kind: u32, flags: u64, addr: u64, offset: u64, size: u64,
                link: u32, info: u32, align: u64, entsize: u64 }
var headers: Header[>..] = [];
var machine: u16 = 0;

fn u16at(at: i64) -> u16 { let v, ok = binary::read_u16le(image::data, at); v }
fn u32at(at: i64) -> u32 { let v, ok = binary::read_u32le(image::data, at); v }
fn u64at(at: i64) -> u64 { let v, ok = binary::read_u64le(image::data, at); v }

// Reads the ELF file image::read read last. "" on success.
fn parse() -> u8[>..] {
    let base = image::base;
    let file = image::data[base..];
    if file.len < 64 { return "truncated ELF header"; }
    if file[4] != 2 { return "a 32-bit ELF file, which this does not read"; }
    if file[5] != 1 { return "a big-endian ELF file, which this does not read"; }
    let kind = u16at(base + 16);
    machine = u16at(base + 18);
    let entry = u64at(base + 24);
    let shoff = u64at(base + 40);
    let shentsize = u16at(base + 58);
    let shnum = u16at(base + 60);
    let shstrndx = u16at(base + 62);
    if machine == EM_AARCH64 { image::cpu = image::CPU_ARM64; }
    else if machine == EM_X86_64 { image::cpu = image::CPU_X86_64; }
    else { image::cpu = 0; }
    image::filetype = kind;
    image::format_name = "ELF";
    image::underscore = false;
    image::entry = entry;
    if shnum == 0 { return "no section headers (a stripped or unusual file)"; }
    if shentsize < 64 || !binary::range_ok(file, shoff as! i64, shnum as i64 * shentsize) {
        return "section headers run past the end of the file";
    }
    if shstrndx >= shnum { return "the section name table is not a section"; }
    for i in shnum as i64 {
        let at = base + shoff as! i64 + i * shentsize;
        headers.push(Header { name: u32at(at), kind: u32at(at + 4), flags: u64at(at + 8),
                              addr: u64at(at + 16), offset: u64at(at + 24), size: u64at(at + 32),
                              link: u32at(at + 40), info: u32at(at + 44), align: u64at(at + 48),
                              entsize: u64at(at + 56) });
    }
    for h, i in headers {
        if h.kind != SHT_NOBITS && h.kind != 0 &&
           !binary::range_ok(file, h.offset as! i64, h.size as! i64) {
            return str("section ", i, " runs past the end of the file");
        }
    }
    // A relocatable object's allocated sections, laid out one after another.
    if kind == ET_REL {
        var next: u64 = 0x1000;
        for &h in headers {
            guard h.flags & SHF_ALLOC != 0;
            let align = if h.align > 1 { h.align } else { 1 };
            next = (next + align - 1) / align * align;
            h.addr = next;
            next += h.size;
        }
    }
    let names = headers[shstrndx as i64];
    let strtab = image::data[(base + names.offset as! i64)..(base + (names.offset + names.size) as! i64)];
    for h, i in headers {
        let name, ok = binary::read_cstring(strtab, h.name);
        if !ok { return str("section ", i, "'s name is not in the name table"); }
        if starts_with(name, ".debug_") && h.kind != SHT_NOBITS {
            if h.flags & SHF_COMPRESSED != 0 {
                return str(name, " is compressed, which this does not read (objcopy --decompress-debug-sections)");
            }
            var dname: u8[..32] = [];
            dname.append(name[1..min(name.len, 33)]);
            image::debug_sections.push(image::DebugSection { name: dname,
                at: base + h.offset as! i64, size: h.size as! i64 });
        }
        if name == ".note.gnu.build-id" && h.kind == SHT_NOTE && h.size >= 16 + 16 {
            // namesz, descsz, type, "GNU\0", then the ID.
            let descsz = u32at(base + h.offset as! i64 + 4);
            let n = min(descsz as i64, 16);
            for k in n { image::uuid[k] = image::data[base + h.offset as! i64 + 16 + k]; }
        }
        guard h.flags & SHF_ALLOC != 0 && h.kind != 0;
        var sname: u8[..32] = [];
        sname.append(name[..min(name.len, 32)]);
        image::sections.push(image::Section {
            segment: [], name: sname, addr: h.addr, size: h.size,
            offset: if h.kind == SHT_NOBITS { 0 } else { base as u64 + h.offset },
            flags: (h.flags & 0xffffffff) as! u32,
            code: h.flags & SHF_EXECINSTR != 0 });
    }
    let serr = symbols();
    if serr.len > 0 { return serr; }
    if kind == ET_REL { return relocate_debug(); }
    ""
}

// The symbol table: functions and objects of the file's own sections.
fn symbols() -> u8[>..] {
    let base = image::base;
    for h in headers {
        guard h.kind == SHT_SYMTAB;
        if h.link >= headers.len { return "the symbol table's strings are not a section"; }
        let strs = headers[h.link as i64];
        let strtab = image::data[(base + strs.offset as! i64)..(base + (strs.offset + strs.size) as! i64)];
        let n = h.size / 24;
        for i in n as! i64 {
            let at = base + h.offset as! i64 + i * 24;
            let name_off = u32at(at);
            let info = image::data[at + 4];
            let shndx = u16at(at + 6);
            var value = u64at(at + 8);
            let name, ok = binary::read_cstring(strtab, name_off);
            if !ok { return str("symbol ", i, "'s name is not in the string table"); }
            let kind = info & 0xf;
            // Defined in a section of the file (not undefined, absolute or common),
            // and a function, an object or of no type; not a section or file symbol.
            let defined = shndx != 0 && shndx < 0xff00 && (kind == 0 || kind == 1 || kind == 2) && name.len > 0;
            if defined && image::filetype == ET_REL && shndx < headers.len {
                value += headers[shndx as i64].addr;
            }
            image::symbols.push(image::Symbol { name_at: base + strs.offset as! i64 + name_off,
                name_len: name.len, value: value, kind: info, sect: (shndx & 0xff) as! u8,
                desc: 0, defined: defined });
        }
    }
    ""
}

// Applies an object's relocations of its debug sections: the addresses
// its line table names, and the offsets into the string sections.
fn relocate_debug() -> u8[>..] {
    let base = image::base;
    var symtab = -1;
    for h, i in headers { if h.kind == SHT_SYMTAB { symtab = i; } }
    for h in headers {
        guard h.kind == SHT_RELA && h.info < headers.len && symtab >= 0;
        let target = headers[h.info as i64];
        // Only the debug sections' relocations: the code is shown as it is.
        guard target.flags & SHF_ALLOC == 0;
        let n = h.size / 24;
        for i in n as! i64 {
            let at = base + h.offset as! i64 + i * 24;
            let offset = u64at(at);
            let info = u64at(at + 8);
            let addend = u64at(at + 16);
            let sym = (info >> 32) as! i64;
            let kind = (info & 0xffffffff) as! u32;
            let st = headers[symtab];
            if sym * 24 + 24 > st.size as! i64 { return "a relocation names no symbol"; }
            let sat = base + st.offset as! i64 + sym * 24;
            let shndx = u16at(sat + 6);
            var s = u64at(sat + 8);
            if shndx != 0 && shndx < 0xff00 && shndx < headers.len { s += headers[shndx].addr; }
            let v = s + addend;
            let width = if (machine == EM_X86_64 && kind == 1) || (machine == EM_AARCH64 && kind == 257) { 8 }
                        else if (machine == EM_X86_64 && (kind == 10 || kind == 11)) ||
                                (machine == EM_AARCH64 && kind == 258) { 4 }
                        else { 0 };
            if width == 0 { return str("a debug relocation of a type this does not apply: ", kind); }
            if !binary::range_ok(image::data, base + target.offset as! i64 + offset as! i64, width) ||
               offset + width as u64 > target.size {
                return "a debug relocation outside its section";
            }
            let p = base + target.offset as! i64 + offset as! i64;
            for k in width { image::data[p + k] = ((v >> (8 * k)) & 0xff) as! u8; }
        }
    }
    ""
}
