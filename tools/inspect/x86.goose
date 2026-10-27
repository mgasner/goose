// x86-64 disassembly through Capstone (docs/design/inspect.md §4.3), bound
// from the shared library by name. The block is `extern?`: where Capstone
// is not installed, the inspector runs as it does without it, and x86-64
// code is shown as bytes. inspect.build says where each platform's package
// manager puts the library.
namespace x86;
import std;
import ffi;

extern? "capstone" {
    fn cs_version(major: i32&, minor: i32&) -> u32;
    fn cs_open(arch: i32, mode: i32, handle: u64&) -> i32;
    fn cs_option(handle: u64, kind: i32, value: u64) -> i32;
    fn cs_disasm(handle: u64, code: const u8&, size: u64, address: u64, count: u64, insns: u64&) -> u64;
    fn cs_free(insns: u64, count: u64);
}

let CS_ARCH_X86 = 3;
let CS_MODE_64 = 8;
let CS_OPT_SYNTAX = 1;
let CS_OPT_SYNTAX_ATT: u64 = 2;

// One instruction: where it is, how long, and its text in `texts`.
struct Insn { addr: u64, size: i64, text_at: i64, text_len: i64, known: bool }
var insns: Insn[>..] = [];
var texts: u8[>..] = [];

var handle: u64 = 0;
var ready = false;
// Capstone's cs_insn as this version lays it out: its size and where the
// mnemonic and the operands are (cs_version's major; 4 and 5 differ).
var insn_size = 0;
var mnemonic_at = 0;
var operands_at = 0;

fn text(i: Insn) -> const u8[:] { texts[i.text_at..i.text_at + i.text_len] }

// Opens Capstone for x86-64 in AT&T syntax, as objdump prints it. "" when
// it is ready, else why there is no x86-64 disassembly.
fn open() -> u8[>..] {
    if ready { return ""; }
    if !ffi::available("capstone") {
        var why: u8[>..] = [];
        ffi::unavailable("capstone", why);
        return str("x86-64 disassembly needs Capstone, which is not here: ", why);
    }
    var major: i32 = 0;
    var minor: i32 = 0;
    cs_version(major, minor);
    if major == 4 { insn_size = 240; mnemonic_at = 34; operands_at = 66; }
    else if major == 5 { insn_size = 248; mnemonic_at = 42; operands_at = 74; }
    else { return str("Capstone ", major, ".", minor, " lays out its instructions in a way this does not read (4 or 5)"); }
    if cs_open(CS_ARCH_X86, CS_MODE_64, handle) != 0 { return "Capstone would not open for x86-64"; }
    cs_option(handle, CS_OPT_SYNTAX, CS_OPT_SYNTAX_ATT);
    ready = true;
    ""
}

// A field of an instruction Capstone wrote: the C string at `at` in its
// bytes, at most `max` long.
fn field(raw: const u8[:], at: i64, max: i64) -> const u8[:] {
    var end = at;
    while end < at + max && end < raw.len && raw[end] != 0 { end++; }
    raw[at..end]
}

// Capstone's AT&T text in LLVM's conventions, as objdump prints it: its
// numbers in hex, a two's-complement 64-bit one as the negative number it
// is, and no spaces in a memory operand. A scale in one, (%rax,%rbx,4),
// stays decimal.
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }
fn is_hex(c: u8) -> bool { is_digit(c) || (c >= 'a' && c <= 'f') }

fn llvm_style(out: u8[>..]&, ops: const u8[:]) {
    var depth = 0;
    var i = 0;
    while i < ops.len {
        let c = ops[i];
        if c == '(' { depth++; }
        if c == ')' { depth--; }
        // A space after a comma inside a memory operand goes.
        if c == ' ' && depth > 0 && i > 0 && ops[i - 1] == ',' { i++; continue; }
        // A number: after $, or where an operand starts (a displacement or
        // an address), never inside parentheses or a register name.
        let starts = i == 0 || ops[i - 1] == '$' || ops[i - 1] == ' ' || ops[i - 1] == '*';
        let neg = c == '-' && i + 1 < ops.len && is_digit(ops[i + 1]);
        if depth == 0 && starts && (is_digit(c) || neg) {
            var j = if neg { i + 1 } else { i };
            var v: u64 = 0;
            var ok = true;
            if j + 1 < ops.len && ops[j] == '0' && ops[j + 1] == 'x' {
                j += 2;
                let from = j;
                while j < ops.len && is_hex(ops[j]) {
                    let d: u64 = if is_digit(ops[j]) { ops[j] - '0' } else { (ops[j] - 'a') as u64 + 10 };
                    if j - from >= 16 { ok = false; }
                    v = v << 4 | d;
                    j++;
                }
            } else {
                while j < ops.len && is_digit(ops[j]) {
                    let d: u64 = ops[j] - '0';
                    if v > (~(0 as u64) - d) / 10 { ok = false; }
                    v = v * 10 + d;
                    j++;
                }
            }
            if ok && (j == ops.len || !is_hex(ops[j])) {
                var negative = neg;
                if !neg && v >= (1 as u64 << 63) { negative = true; v = 0 - v; }
                if negative { out.push('-'); }
                out.append("0x");
                format_uint(out, v, 16, 0, '0');
                i = j;
                continue;
            }
        }
        out.push(c);
        i++;
    }
}

// The opcode byte of an instruction: past its legacy and REX prefixes.
fn opcode(bytes: const u8[:]) -> i64 {
    var i = 0;
    while i < bytes.len && (bytes[i] == 0x66 || bytes[i] == 0x67 || bytes[i] == 0xf2 || bytes[i] == 0xf3 ||
                            bytes[i] == 0xf0 || bytes[i] == 0x2e || bytes[i] == 0x3e || bytes[i] == 0x26 ||
                            bytes[i] == 0x64 || bytes[i] == 0x65 || bytes[i] == 0x36) { i++; }
    if i < bytes.len && bytes[i] >= 0x40 && bytes[i] <= 0x4f { i++; }
    i
}

// Where LLVM's printer and Capstone's part ways beyond their numbers, made
// LLVM's: an ALU or mov immediate encoded in one byte is signed (`$-0x1`,
// where Capstone has `$0xff` or its sign extension); the shift-by-one opcodes
// (D0, D1) leave out their `$0x1`; cvtsi2sd and cvtsi2ss of a register
// leave out the size the register says; and an xchg of two registers
// names them the other way round. `text` is the mnemonic, a tab and the
// operands as llvm_style left them; the result goes to out.
fn llvm_quirks(out: u8[>..]&, text: const u8[:], bytes: const u8[:]) {
    let tab = find(text, "\t");
    if tab < 0 { out.append(text); return; }
    let mn = text[..tab];
    var ops = text[tab + 1..];
    let op = opcode(bytes);
    let opb: i64 = if op < bytes.len { bytes[op] } else { -1 };
    // cvtsi2sdq %rax, %xmm1 is cvtsi2sd %rax, %xmm1.
    if (starts_with(mn, "cvtsi2sd") || starts_with(mn, "cvtsi2ss")) && mn.len == 9 && ops.len > 0 && ops[0] == '%' {
        format(out, mn[..8], "\t", ops);
        return;
    }
    // shll $0x1, %eax is shll %eax, for D0 and D1 (C0 and C1 take an immediate).
    if (opb == 0xd0 || opb == 0xd1) && starts_with(ops, "$0x1, ") {
        format(out, mn, "\t", ops[6..]);
        return;
    }
    // xchgq %r8, %rbx is xchgq %rbx, %r8 for two registers (mod 11).
    if (opb == 0x86 || opb == 0x87) && op + 1 < bytes.len && bytes[op + 1] >= 0xc0 {
        let comma = find(ops, ", ");
        if comma > 0 && ops[0] == '%' { format(out, mn, "\t", ops[comma + 2..], ", ", ops[..comma]); return; }
    }
    // A one-byte immediate of the ALU and mov opcodes that take one (not an
    // 0F-escaped one's, a shuffle's selector) is signed: the last byte.
    let imm8 = opb == 0x80 || opb == 0x83 || opb == 0x6a || opb == 0x6b || opb == 0xc6 ||
               (opb >= 0xb0 && opb <= 0xb7) || opb == 0xa8 || opb == 0xf6 ||
               (opb < 0x40 && (opb & 7) == 4);
    if imm8 && starts_with(ops, "$0x") && bytes.len > 0 && bytes[bytes.len - 1] >= 0x80 {
        var end = 3;
        while end < ops.len && is_hex(ops[end]) { end++; }
        format(out, mn, "\t$-0x");
        format_uint(out, 0x100 - bytes[bytes.len - 1] as u64, 16, 0, '0');
        out.append(ops[end..]);
        return;
    }
    out.append(text);
}

// Decodes code, which is at addr, into insns: Capstone stops at a byte it
// cannot decode, which is shown as `.byte` and stepped over.
fn decode(code: const u8[:], addr: u64) {
    insns.clear();
    texts.clear();
    var pos = 0;
    while pos < code.len {
        var list: u64 = 0;
        let n = cs_disasm(handle, code[pos], (code.len - pos) as u64, addr + pos as u64, 0, list);
        for i in n as! i64 {
            let raw = ffi::bytes(list + (i * insn_size) as u64, insn_size);
            let size: i64 = raw[16] | (raw[17] as i64 << 8);
            let mnemonic = field(raw, mnemonic_at, 32);
            let operands = field(raw, operands_at, 160);
            var styled: u8[>..] = [];
            styled.append(mnemonic);
            if operands.len > 0 { styled.push('\t'); llvm_style(styled, operands); }
            let at = texts.len;
            llvm_quirks(texts, styled, code[pos..min(pos + size, code.len)]);
            insns.push(Insn { addr: addr + pos as u64, size: size, text_at: at, text_len: texts.len - at, known: true });
            pos += size;
        }
        if n > 0 { cs_free(list, n); }
        if pos < code.len {
            let at = texts.len;
            texts.append(".byte\t0x");
            format_uint(texts, code[pos], 16, 2, '0');
            insns.push(Insn { addr: addr + pos as u64, size: 1, text_at: at, text_len: texts.len - at, known: false });
            pos++;
        }
    }
}
