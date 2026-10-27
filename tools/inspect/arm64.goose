// An AArch64 (arm64) instruction decoder for what clang emits for Goose's
// generated C (docs/design/inspect.md §4.3): the integer, load/store,
// branch and scalar floating-point classes, and the common vector ones,
// printed as LLVM prints them on Apple platforms (objdump -d), aliases
// included. An encoding outside what it knows prints as `.word`, and says
// so: an instruction is shown, never guessed.
namespace arm64;
import std;

// What one instruction decoded to: its text (mnemonic, a tab, operands),
// the address it names if any (a branch target, adrp's page, a literal),
// and whether the decoder knew it.
struct Decoded { target: u64, has_target: bool, known: bool }

fn bits(w: u32, lo: i64, n: i64) -> i64 { ((w as u64 >> lo) & ((1 as u64 << n) - 1)) as! i64 }
fn bit(w: u32, i: i64) -> bool { (w >> i) & 1 != 0 }
fn sext(v: i64, n: i64) -> i64 { if (v >> (n - 1)) & 1 != 0 { v - (1 << n) } else { v } }

let CONDS: const u8[:][16] = ["eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc",
                              "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"];
let SHIFTS: const u8[:][4] = ["lsl", "lsr", "asr", "ror"];
let EXTENDS: const u8[:][8] = ["uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth", "sxtw", "sxtx"];

// A general register: x/w by width, 31 being sp (where the encoding means
// the stack pointer) or the zero register.
fn reg(out: u8[>..]&, n: i64, wide: bool, sp: bool) {
    if n == 31 { out.append(if sp { if wide { "sp" } else { "wsp" } } else { if wide { "xzr" } else { "wzr" } }); }
    else { format(out, if wide { "x" } else { "w" }, n); }
}
fn imm(out: u8[>..]&, v: i64) {
    if v < 0 { out.append("#-0x"); format_uint(out, (-v) as! u64, 16, 0, '0'); }
    else { out.append("#0x"); format_uint(out, v as! u64, 16, 0, '0'); }
}
// The bitfield aliases' positions and widths are decimal.
fn dec(out: u8[>..]&, v: i64) { format(out, "#", v); }
fn uimm(out: u8[>..]&, v: u64) { out.append("#0x"); format_uint(out, v, 16, 0, '0'); }
fn addr(out: u8[>..]&, a: u64) { out.append("0x"); format_uint(out, a, 16, 0, '0'); }
fn sep(out: u8[>..]&) { out.append(", "); }
fn op(out: u8[>..]&, m: const u8[:]) { format(out, m, "\t"); }

fn unknown(w: u32, out: u8[>..]&) -> Decoded {
    out.append(".word\t0x");
    format_uint(out, w, 16, 8, '0');
    Decoded { target: 0, has_target: false, known: false }
}
fn done() -> Decoded { Decoded { target: 0, has_target: false, known: true } }
fn targets(a: u64) -> Decoded { Decoded { target: a, has_target: true, known: true } }

fn decode(w: u32, pc: u64, out: u8[>..]&) -> Decoded {
    let op0 = bits(w, 25, 4);
    if w >> 16 == 0 {
        // permanently undefined, what __builtin_trap leaves in a jump table's gaps
        op(out, "udf");
        imm(out, bits(w, 0, 16));
        return done();
    }
    if op0 & 0xe == 0x8 { return data_imm(w, pc, out); }
    if op0 & 0xe == 0xa { return branch(w, pc, out); }
    if op0 & 0x5 == 0x4 { return loadstore(w, pc, out); }
    if op0 & 0x7 == 0x5 { return data_reg(w, out); }
    if op0 & 0x7 == 0x7 { return simd_fp(w, out); }
    unknown(w, out)
}

// --- data processing, immediate ------------------------------------------

// The value of a logical immediate (DecodeBitMasks), false for a reserved one.
fn bitmask(n: i64, imms: i64, immr: i64, wide: bool) -> u64, bool {
    let combined = (n << 6) | (~imms & 0x3f);
    if combined == 0 { return 0, false; }
    var len = 6;
    while (combined >> len) & 1 == 0 { len--; }
    if len < 1 || (!wide && len > 5) { return 0, false; }
    let esize = 1 << len;
    let levels = esize - 1;
    let s = imms & levels;
    let r = immr & levels;
    if s == levels { return 0, false; }
    var welem: u64 = (1 as u64 << (s + 1)) - 1;
    // Rotate right by r within esize bits.
    let emask: u64 = if esize == 64 { ~(0 as u64) } else { (1 as u64 << esize) - 1 };
    if r > 0 { welem = ((welem >> r) | (welem << (esize - r))) & emask; }
    var v: u64 = 0;
    var i = 0;
    let size = if wide { 64 } else { 32 };
    while i < size { v |= welem << i; i += esize; }
    return v, true;
}

// Whether MOVZ or MOVN could make v, in which case LLVM prints an ORR's
// mov as the immediate it is, not as an alias.
fn move_wide_ok(v: u64, wide: bool) -> bool {
    let size = if wide { 64 } else { 32 };
    let mask: u64 = if wide { ~(0 as u64) } else { 0xffffffff };
    for k in 2 {
        let x = if k == 0 { v } else { ~v & mask };
        var s = 0;
        while s < size {
            if x & ~((0xffff as u64) << s) & mask == 0 { return true; }
            s += 16;
        }
    }
    false
}

fn data_imm(w: u32, pc: u64, out: u8[>..]&) -> Decoded {
    let wide = bit(w, 31);
    let rd = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    let kind = bits(w, 23, 3);
    if kind <= 1 {
        // adr, adrp
        let lo = bits(w, 29, 2);
        let hi = bits(w, 5, 19);
        let v = sext((hi << 2) | lo, 21);
        let page = bit(w, 31);
        let a = if page { (pc & ~(0xfff as u64)) + ((v << 12) as! u64) } else { pc + (v as! u64) };
        op(out, if page { "adrp" } else { "adr" });
        reg(out, rd, true, false);
        sep(out);
        addr(out, a);
        return targets(a);
    }
    if kind == 2 {
        // add/sub immediate
        let sub = bit(w, 30);
        let flags = bit(w, 29);
        let shift = bit(w, 22);
        let v = bits(w, 10, 12);
        if !sub && !flags && !shift && v == 0 && (rd == 31 || rn == 31) {
            op(out, "mov");
            reg(out, rd, wide, true);
            sep(out);
            reg(out, rn, wide, true);
            return done();
        }
        if flags && rd == 31 {
            op(out, if sub { "cmp" } else { "cmn" });
        } else {
            op(out, if sub { if flags { "subs" } else { "sub" } } else { if flags { "adds" } else { "add" } });
            reg(out, rd, wide, !flags);
            sep(out);
        }
        reg(out, rn, wide, true);
        sep(out);
        imm(out, v);
        if shift { out.append(", lsl #12"); out.append("\t; =0x"); format_uint(out, (v << 12) as! u64, 16, 0, '0'); }
        return done();
    }
    if kind == 4 {
        // and/orr/eor/ands immediate
        let opc = bits(w, 29, 2);
        if !wide && bit(w, 22) { return unknown(w, out); }
        let v, ok = bitmask(bits(w, 22, 1), bits(w, 10, 6), bits(w, 16, 6), wide);
        if !ok { return unknown(w, out); }
        if opc == 1 && rn == 31 && !move_wide_ok(v, wide) {
            // As a signed number at the width.
            op(out, "mov");
            reg(out, rd, wide, true);
            sep(out);
            imm(out, if wide { v as! i64 } else { (v as! u32) as! i32 });
            return done();
        }
        if opc == 3 && rd == 31 {
            op(out, "tst");
        } else {
            op(out, ["and", "orr", "eor", "ands"][opc]);
            reg(out, rd, wide, opc != 3);
            sep(out);
        }
        reg(out, rn, wide, false);
        sep(out);
        uimm(out, v);
        return done();
    }
    if kind == 5 {
        // movn/movz/movk
        let opc = bits(w, 29, 2);
        let hw = bits(w, 21, 2);
        let v16 = bits(w, 5, 16);
        if opc == 1 || (!wide && hw >= 2) { return unknown(w, out); }
        if opc == 3 {
            op(out, "movk");
            reg(out, rd, wide, false);
            sep(out);
            imm(out, v16);
            if hw > 0 { format(out, ", lsl #", hw * 16); }
            return done();
        }
        let shifted: u64 = (v16 as u64) << (hw * 16);
        // The mov alias, unless a zero with a shift, which only movz/movn says.
        if v16 == 0 && hw != 0 {
            op(out, if opc == 0 { "movn" } else { "movz" });
            reg(out, rd, wide, false);
            sep(out);
            imm(out, v16);
            format(out, ", lsl #", hw * 16);
            return done();
        }
        op(out, "mov");
        reg(out, rd, wide, false);
        sep(out);
        if opc == 2 {
            // Signed at the width, as LLVM prints it.
            let v: i64 = if wide { shifted as! i64 } else { (shifted as! u32) as! i32 };
            imm(out, v);
            format(out, "\t; =", v);
        } else {
            // movn: the complement, as a negative number at the width.
            let v: i64 = if wide { ~shifted as! i64 } else { (~(shifted as! u32)) as! i32 };
            imm(out, v);
            format(out, "\t; =", v);
        }
        return done();
    }
    if kind == 6 { return bitfield(w, out); }
    if kind == 7 {
        // extr, and ror for the same register twice
        let rm = bits(w, 16, 5);
        let lsb = bits(w, 10, 6);
        if bit(w, 22) != wide || bits(w, 29, 2) != 0 || bit(w, 21) || (!wide && lsb >= 32) { return unknown(w, out); }
        op(out, if rn == rm { "ror" } else { "extr" });
        reg(out, rd, wide, false);
        sep(out);
        reg(out, rn, wide, false);
        sep(out);
        if rn != rm { reg(out, rm, wide, false); sep(out); }
        imm(out, lsb);
        return done();
    }
    unknown(w, out)
}

// sbfm/bfm/ubfm and their aliases: the shifts, the extends and the
// bitfield moves, as LLVM chooses among them.
fn bitfield(w: u32, out: u8[>..]&) -> Decoded {
    let wide = bit(w, 31);
    let opc = bits(w, 29, 2);
    let rd = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    let immr = bits(w, 16, 6);
    let imms = bits(w, 10, 6);
    let size = if wide { 64 } else { 32 };
    if bit(w, 22) != wide || opc == 3 || (!wide && (immr >= 32 || imms >= 32)) { return unknown(w, out); }
    fn two(out: u8[>..]&, m: const u8[:], rd: i64, rn: i64, wide: bool, rnwide: bool) {
        op(out, m);
        reg(out, rd, wide, false);
        sep(out);
        reg(out, rn, rnwide, false);
    }
    if opc == 0 {
        if imms == size - 1 { two(out, "asr", rd, rn, wide, wide); sep(out); dec(out, immr); return done(); }
        if immr == 0 && imms == 7 { two(out, "sxtb", rd, rn, wide, false); return done(); }
        if immr == 0 && imms == 15 { two(out, "sxth", rd, rn, wide, false); return done(); }
        if immr == 0 && imms == 31 && wide { two(out, "sxtw", rd, rn, wide, false); return done(); }
        if imms < immr {
            two(out, "sbfiz", rd, rn, wide, wide); sep(out); dec(out, size - immr); sep(out); dec(out, imms + 1);
            return done();
        }
        two(out, "sbfx", rd, rn, wide, wide); sep(out); dec(out, immr); sep(out); dec(out, imms - immr + 1);
        return done();
    }
    if opc == 2 {
        if imms != size - 1 && imms + 1 == immr {
            two(out, "lsl", rd, rn, wide, wide); sep(out); dec(out, size - 1 - imms); return done();
        }
        if imms == size - 1 { two(out, "lsr", rd, rn, wide, wide); sep(out); dec(out, immr); return done(); }
        if immr == 0 && imms == 7 && !wide { two(out, "uxtb", rd, rn, false, false); return done(); }
        if immr == 0 && imms == 15 && !wide { two(out, "uxth", rd, rn, false, false); return done(); }
        if imms < immr {
            two(out, "ubfiz", rd, rn, wide, wide); sep(out); dec(out, size - immr); sep(out); dec(out, imms + 1);
            return done();
        }
        two(out, "ubfx", rd, rn, wide, wide); sep(out); dec(out, immr); sep(out); dec(out, imms - immr + 1);
        return done();
    }
    // bfm
    if imms < immr {
        two(out, "bfi", rd, rn, wide, wide); sep(out); dec(out, size - immr); sep(out); dec(out, imms + 1);
        return done();
    }
    two(out, "bfxil", rd, rn, wide, wide); sep(out); dec(out, immr); sep(out); dec(out, imms - immr + 1);
    done()
}

// --- branches, exceptions and system --------------------------------------

fn branch(w: u32, pc: u64, out: u8[>..]&) -> Decoded {
    if bits(w, 26, 5) == 0x5 {
        // b, bl
        let a = pc + ((sext(bits(w, 0, 26), 26) << 2) as! u64);
        op(out, if bit(w, 31) { "bl" } else { "b" });
        addr(out, a);
        return targets(a);
    }
    if bits(w, 24, 8) == 0x54 && !bit(w, 4) {
        let a = pc + ((sext(bits(w, 5, 19), 19) << 2) as! u64);
        format(out, "b.", CONDS[bits(w, 0, 4)], "\t");
        addr(out, a);
        return targets(a);
    }
    if bits(w, 25, 6) == 0x1a {
        // cbz, cbnz
        let a = pc + ((sext(bits(w, 5, 19), 19) << 2) as! u64);
        op(out, if bit(w, 24) { "cbnz" } else { "cbz" });
        reg(out, bits(w, 0, 5), bit(w, 31), false);
        sep(out);
        addr(out, a);
        return targets(a);
    }
    if bits(w, 25, 6) == 0x1b {
        // tbz, tbnz
        let b = (bits(w, 31, 1) << 5) | bits(w, 19, 5);
        let a = pc + ((sext(bits(w, 5, 14), 14) << 2) as! u64);
        op(out, if bit(w, 24) { "tbnz" } else { "tbz" });
        reg(out, bits(w, 0, 5), b >= 32, false);
        sep(out);
        imm(out, b);
        sep(out);
        addr(out, a);
        return targets(a);
    }
    if bits(w, 25, 7) == 0x6b && bits(w, 16, 5) == 31 && bits(w, 10, 6) == 0 && bits(w, 0, 5) == 0 {
        let opc = bits(w, 21, 4);
        let rn = bits(w, 5, 5);
        if opc == 2 && rn == 30 { out.append("ret"); return done(); }
        if opc > 2 { return unknown(w, out); }
        op(out, ["br", "blr", "ret"][opc]);
        reg(out, rn, true, false);
        return done();
    }
    if bits(w, 24, 8) == 0xd4 && bits(w, 2, 3) == 0 {
        let opc = bits(w, 21, 3);
        let ll = bits(w, 0, 2);
        let v = bits(w, 5, 16);
        let name = if opc == 0 && ll == 1 { "svc" } else if opc == 1 && ll == 0 { "brk" }
                   else if opc == 2 && ll == 0 { "hlt" } else { "" };
        if name.len == 0 { return unknown(w, out); }
        op(out, name);
        imm(out, v);
        return done();
    }
    if w == 0xd503201f { out.append("nop"); return done(); }
    if bits(w, 12, 20) == 0xd5033 && bits(w, 0, 5) == 31 {
        // dmb, dsb, isb
        let crm = bits(w, 8, 4);
        let o = bits(w, 5, 3);
        let opts: const u8[:][16] = ["#0x0", "oshld", "oshst", "osh", "#0x4", "nshld", "nshst", "nsh",
                                     "#0x8", "ishld", "ishst", "ish", "#0xc", "ld", "st", "sy"];
        if o == 6 { out.append("isb"); return done(); }
        if o != 4 && o != 5 { return unknown(w, out); }
        op(out, if o == 5 { "dmb" } else { "dsb" });
        out.append(opts[crm]);
        return done();
    }
    unknown(w, out)
}

// --- loads and stores ----------------------------------------------------

// The register a load or store moves: a general one by its width, or a
// SIMD&FP one, b to q, by size and the high opc bit.
fn transfer_reg(out: u8[>..]&, n: i64, vec: bool, size: i64, opc: i64) {
    if vec {
        let s = if opc >= 2 && size == 0 { 4 } else { size };
        format(out, ["b", "h", "s", "d", "q"][s], n);
    } else {
        reg(out, n, size == 3 || (opc == 2 && size < 3), false);
    }
}

// The mnemonic of a single-register load or store, by size, V and opc;
// "" for an encoding that is not one.
fn ls_name(size: i64, vec: bool, opc: i64, unscaled: bool) -> const u8[:] {
    let pre = if unscaled { "u" } else { "" };
    if vec {
        if opc == 0 || opc == 2 { return if unscaled { "stur" } else { "str" }; }
        return if unscaled { "ldur" } else { "ldr" };
    }
    let base = if opc == 0 { "st" } else if opc == 1 { "ld" } else { "ld" };
    let sign = opc >= 2;
    if size == 3 && opc == 2 { return "prfm"; }
    if size == 3 && opc == 3 { return ""; }
    if size == 2 && opc == 3 { return ""; }
    // Names: str/ldr, strb/ldrb/ldrsb, strh/ldrh/ldrsh, ldrsw.
    let suffix = ["b", "h", "", ""][size];
    if size == 2 && opc == 2 { return if unscaled { "ldursw" } else { "ldrsw" }; }
    let kind = if base == "st" { 0 } else if sign { 2 } else { 1 };
    if unscaled {
        return [["sturb", "ldurb", "ldursb"], ["sturh", "ldurh", "ldursh"],
                ["stur", "ldur", ""], ["stur", "ldur", ""]][size][kind];
    }
    return [["strb", "ldrb", "ldrsb"], ["strh", "ldrh", "ldrsh"],
            ["str", "ldr", ""], ["str", "ldr", ""]][size][kind];
}

// The scale of an unsigned offset: the access's size, 16 bytes for a q.
fn ls_scale(size: i64, vec: bool, opc: i64) -> i64 {
    if vec && opc >= 2 && size == 0 { 4 } else { size }
}

fn mem(out: u8[>..]&, rn: i64, off: i64) {
    out.append("[");
    reg(out, rn, true, true);
    if off != 0 { sep(out); imm(out, off); }
    out.append("]");
}

fn loadstore(w: u32, pc: u64, out: u8[>..]&) -> Decoded {
    let rt = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    let vec = bit(w, 26);
    let size = bits(w, 30, 2);
    if bits(w, 27, 3) == 0x7 && bits(w, 24, 2) == 1 {
        // unsigned offset
        let opc = bits(w, 22, 2);
        let name = ls_name(size, vec, opc, false);
        if name.len == 0 || (vec && size > 0 && opc >= 2) { return unknown(w, out); }
        let off = bits(w, 10, 12) << ls_scale(size, vec, opc);
        if name == "prfm" { return unknown(w, out); }
        op(out, name);
        transfer_reg(out, rt, vec, size, opc);
        sep(out);
        mem(out, rn, off);
        return done();
    }
    if bits(w, 27, 3) == 0x7 && bits(w, 24, 2) == 0 && !bit(w, 21) {
        // unscaled, post-index, pre-index (not the unprivileged forms)
        let opc = bits(w, 22, 2);
        let mode = bits(w, 10, 2);
        let off = sext(bits(w, 12, 9), 9);
        if mode == 2 { return unknown(w, out); }
        let name = ls_name(size, vec, opc, mode == 0);
        if name.len == 0 || name == "prfm" || (vec && size > 0 && opc >= 2) { return unknown(w, out); }
        op(out, name);
        transfer_reg(out, rt, vec, size, opc);
        sep(out);
        if mode == 0 { mem(out, rn, off); }
        else if mode == 1 { out.append("["); reg(out, rn, true, true); out.append("], "); imm(out, off); }
        else { out.append("["); reg(out, rn, true, true); sep(out); imm(out, off); out.append("]!"); }
        return done();
    }
    if bits(w, 27, 3) == 0x7 && bits(w, 24, 2) == 0 && bit(w, 21) && bits(w, 10, 2) == 2 {
        // register offset
        let opc = bits(w, 22, 2);
        let name = ls_name(size, vec, opc, false);
        if name.len == 0 || name == "prfm" || (vec && size > 0 && opc >= 2) { return unknown(w, out); }
        let rm = bits(w, 16, 5);
        let option = bits(w, 13, 3);
        let s = bit(w, 12);
        if option & 2 == 0 { return unknown(w, out); }
        op(out, name);
        transfer_reg(out, rt, vec, size, opc);
        out.append(", [");
        reg(out, rn, true, true);
        sep(out);
        reg(out, rm, option & 1 == 1, false);
        let amount = ls_scale(size, vec, opc);
        if option == 3 {
            if s { format(out, ", lsl #", amount); }
        } else {
            format(out, ", ", EXTENDS[option]);
            if s { format(out, " #", amount); }
        }
        out.append("]");
        return done();
    }
    if bits(w, 27, 3) == 0x7 && bits(w, 24, 2) == 0 && bit(w, 21) && bits(w, 10, 2) == 0 && !vec {
        // the atomic memory operations
        let a = bit(w, 23);
        let r = bit(w, 22);
        let o3 = bit(w, 15);
        let opc = bits(w, 12, 3);
        let rs = bits(w, 16, 5);
        if o3 && opc == 4 && a && !r && rs == 31 {
            // ldapr: a load-acquire, release-consistent
            format(out, "ldapr", ["b", "h", "", ""][size], "\t");
            reg(out, rt, size == 3, false);
            out.append(", [");
            reg(out, rn, true, true);
            out.append("]");
            return done();
        }
        let base = if o3 { if opc == 0 { "swp" } else { "" } }
                   else { ["ldadd", "ldclr", "ldeor", "ldset", "ldsmax", "ldsmin", "ldumax", "ldumin"][opc] };
        if base.len == 0 { return unknown(w, out); }
        let order = if a && r { "al" } else if a { "a" } else if r { "l" } else { "" };
        let sz = ["b", "h", "", ""][size];
        // A load whose result goes nowhere is the st- form.
        if rt == 31 && !a && !o3 {
            format(out, "st", base[2..], order, sz, "\t");
            reg(out, rs, size == 3, false);
        } else {
            format(out, base, order, sz, "\t");
            reg(out, rs, size == 3, false);
            sep(out);
            reg(out, rt, size == 3, false);
        }
        out.append(", [");
        reg(out, rn, true, true);
        out.append("]");
        return done();
    }
    if bits(w, 27, 3) == 0x5 {
        // pairs
        let opc = bits(w, 30, 2);
        let mode = bits(w, 23, 2);
        let load = bit(w, 22);
        let rt2 = bits(w, 10, 5);
        if opc == 3 || (opc == 1 && !vec && (!load || mode == 0)) { return unknown(w, out); }
        let scale = if vec { 2 + opc } else { 2 + (opc >> 1) };
        let off = sext(bits(w, 15, 7), 7) << scale;
        let name = if mode == 0 { if load { "ldnp" } else { "stnp" } }
                   else if opc == 1 && !vec { "ldpsw" }
                   else if load { "ldp" } else { "stp" };
        op(out, name);
        for k in 2 {
            let n = if k == 0 { rt } else { rt2 };
            if vec { format(out, ["s", "d", "q"][opc], n); }
            else { reg(out, n, opc >= 1, false); }
            sep(out);
        }
        out.append("[");
        reg(out, rn, true, true);
        if mode == 1 { out.append("], "); imm(out, off); }
        else if mode == 3 { sep(out); imm(out, off); out.append("]!"); }
        else { if off != 0 { sep(out); imm(out, off); } out.append("]"); }
        return done();
    }
    if bits(w, 27, 3) == 0x3 && bits(w, 24, 2) == 0 {
        // literal
        let opc = bits(w, 30, 2);
        let a = pc + ((sext(bits(w, 5, 19), 19) << 2) as! u64);
        if opc == 3 { return unknown(w, out); }
        op(out, if opc == 2 && !vec { "ldrsw" } else { "ldr" });
        if vec { format(out, ["s", "d", "q"][opc], rt); }
        else { reg(out, rt, opc >= 1, false); }
        sep(out);
        addr(out, a);
        return targets(a);
    }
    if !bit(w, 31) && bits(w, 24, 6) == 0x0c && vec {
        return structures(w, out);
    }
    if !bit(w, 31) && bits(w, 24, 6) == 0x0d && vec {
        return single_structure(w, out);
    }
    if bits(w, 24, 6) == 0x08 && !vec {
        // exclusive and acquire/release
        let o2 = bit(w, 23);
        let load = bit(w, 22);
        let o1 = bit(w, 21);
        let o0 = bit(w, 15);
        let rs = bits(w, 16, 5);
        let sz = ["b", "h", "", ""][size];
        let wide = size == 3;
        if o1 && o2 && bits(w, 10, 5) == 31 {
            // cas, casa, casl, casal
            let order = if load && o0 { "al" } else if load { "a" } else if o0 { "l" } else { "" };
            format(out, "cas", order, sz, "\t");
            reg(out, rs, wide, false); sep(out); reg(out, rt, wide, false);
            out.append(", [");
            reg(out, rn, true, true);
            out.append("]");
            return done();
        }
        if o1 { return unknown(w, out); }
        if o2 {
            // ldar/stlr (and the LO forms, which are not these)
            if !o0 { return unknown(w, out); }
            format(out, if load { "ldar" } else { "stlr" }, sz, "\t");
            reg(out, rt, wide, false);
        } else {
            let name = if load { if o0 { "ldaxr" } else { "ldxr" } } else { if o0 { "stlxr" } else { "stxr" } };
            format(out, name, sz, "\t");
            if !load { reg(out, rs, false, false); sep(out); }
            reg(out, rt, wide, false);
        }
        out.append(", [");
        reg(out, rn, true, true);
        out.append("]");
        return done();
    }
    unknown(w, out)
}

// ld1-ld4/st1-st4 of whole registers: { v0, v1 }, as many as the opcode says.
fn structures(w: u32, out: u8[>..]&) -> Decoded {
    let q = bit(w, 30);
    let load = bit(w, 22);
    let post = bit(w, 23);
    let rm = bits(w, 16, 5);
    let opc = bits(w, 12, 4);
    let size = bits(w, 10, 2);
    let rt = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    if bit(w, 21) || (!post && rm != 0) { return unknown(w, out); }
    // opcode: registers and the structure's element count.
    let nregs = if opc == 7 { 1 } else if opc == 10 { 2 } else if opc == 6 { 3 } else if opc == 2 { 4 }
                else if opc == 8 { 2 } else if opc == 4 { 3 } else if opc == 0 { 4 } else { 0 };
    let elems = if opc == 8 { 2 } else if opc == 4 { 3 } else if opc == 0 { 4 } else { 1 };
    if nregs == 0 || (size == 3 && !q && elems > 1) { return unknown(w, out); }
    format(out, if load { "ld" } else { "st" }, elems, ".", arrangement(size, q), "\t{ ");
    for k in nregs {
        if k > 0 { sep(out); }
        vreg(out, (rt + k) % 32);
    }
    out.append(" }, [");
    reg(out, rn, true, true);
    out.append("]");
    if post {
        sep(out);
        if rm == 31 { format(out, "#", nregs * (if q { 16 } else { 8 })); } else { reg(out, rm, true, false); }
    }
    done()
}

// ld1/st1 of one element, and ld1r: { v0 }[1].
fn single_structure(w: u32, out: u8[>..]&) -> Decoded {
    let q = if bit(w, 30) { 1 } else { 0 };
    let load = bit(w, 22);
    let post = bit(w, 23);
    let r = bit(w, 21);
    let rm = bits(w, 16, 5);
    let opc = bits(w, 13, 3);
    let s = bits(w, 12, 1);
    let size = bits(w, 10, 2);
    let rt = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    if r || (!post && rm != 0) { return unknown(w, out); }
    var ename = "";
    var index = 0;
    var bytes = 0;
    if opc == 0 { ename = "b"; index = (q << 3) | (s << 2) | size; bytes = 1; }
    else if opc == 2 && size & 1 == 0 { ename = "h"; index = (q << 2) | (s << 1) | (size >> 1); bytes = 2; }
    else if opc == 4 && size == 0 { ename = "s"; index = (q << 1) | s; bytes = 4; }
    else if opc == 4 && size == 1 && s == 0 { ename = "d"; index = q; bytes = 8; }
    else if opc == 6 && load && s == 0 {
        format(out, "ld1r.", arrangement(size, q == 1), "\t{ ");
        vreg(out, rt);
        out.append(" }, [");
        reg(out, rn, true, true);
        out.append("]");
        if post { sep(out); if rm == 31 { format(out, "#", 1 << size); } else { reg(out, rm, true, false); } }
        return done();
    }
    else { return unknown(w, out); }
    format(out, if load { "ld1." } else { "st1." }, ename, "\t{ ");
    vreg(out, rt);
    format(out, " }[", index, "], [");
    reg(out, rn, true, true);
    out.append("]");
    if post { sep(out); if rm == 31 { format(out, "#", bytes); } else { reg(out, rm, true, false); } }
    done()
}

// --- data processing, register --------------------------------------------

fn data_reg(w: u32, out: u8[>..]&) -> Decoded {
    let wide = bit(w, 31);
    let rd = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    let rm = bits(w, 16, 5);
    let top = bits(w, 21, 8);
    if bits(w, 24, 5) == 0xa {
        // logical, shifted register
        let opc = bits(w, 29, 2);
        let n = bit(w, 21);
        let shift = bits(w, 22, 2);
        let amount = bits(w, 10, 6);
        if !wide && amount >= 32 { return unknown(w, out); }
        let names: const u8[:][8] = ["and", "bic", "orr", "orn", "eor", "eon", "ands", "bics"];
        let k = opc * 2 + (if n { 1 } else { 0 });
        if k == 2 && rn == 31 && shift == 0 && amount == 0 {
            op(out, "mov");
            reg(out, rd, wide, false);
            sep(out);
            reg(out, rm, wide, false);
            return done();
        }
        if (k == 3 && rn == 31) || (k == 6 && rd == 31) {
            op(out, if k == 3 { "mvn" } else { "tst" });
            reg(out, if k == 3 { rd } else { rn }, wide, false);
        } else {
            op(out, names[k]);
            reg(out, rd, wide, false);
            sep(out);
            reg(out, rn, wide, false);
        }
        sep(out);
        reg(out, rm, wide, false);
        if amount != 0 || shift != 0 { format(out, ", ", SHIFTS[shift], " #", amount); }
        return done();
    }
    if bits(w, 24, 5) == 0xb && !bit(w, 21) {
        // add/sub, shifted register
        let sub = bit(w, 30);
        let flags = bit(w, 29);
        let shift = bits(w, 22, 2);
        let amount = bits(w, 10, 6);
        if shift == 3 || (!wide && amount >= 32) { return unknown(w, out); }
        if flags && rd == 31 {
            op(out, if sub { "cmp" } else { "cmn" });
            reg(out, rn, wide, false);
        } else if sub && rn == 31 {
            op(out, if flags { "negs" } else { "neg" });
            reg(out, rd, wide, false);
        } else {
            op(out, if sub { if flags { "subs" } else { "sub" } } else { if flags { "adds" } else { "add" } });
            reg(out, rd, wide, false);
            sep(out);
            reg(out, rn, wide, false);
        }
        sep(out);
        reg(out, rm, wide, false);
        if amount != 0 || shift != 0 { format(out, ", ", SHIFTS[shift], " #", amount); }
        return done();
    }
    if bits(w, 24, 5) == 0xb && bit(w, 21) {
        // add/sub, extended register
        let sub = bit(w, 30);
        let flags = bit(w, 29);
        let option = bits(w, 13, 3);
        let amount = bits(w, 10, 3);
        if bits(w, 22, 2) != 0 || amount > 4 { return unknown(w, out); }
        if flags && rd == 31 {
            op(out, if sub { "cmp" } else { "cmn" });
            reg(out, rn, wide, true);
        } else {
            op(out, if sub { if flags { "subs" } else { "sub" } } else { if flags { "adds" } else { "add" } });
            reg(out, rd, wide, !flags);
            sep(out);
            reg(out, rn, wide, true);
        }
        sep(out);
        reg(out, rm, wide && option & 3 == 3, false);
        // With sp, the width's own extend is lsl, and none for no shift.
        // (A flag-setting form's 31 is the zero register, not sp.)
        let plain = (rn == 31 || (rd == 31 && !flags)) && option == (if wide { 3 } else { 2 });
        if plain {
            if amount != 0 { format(out, ", lsl #", amount); }
        } else {
            format(out, ", ", EXTENDS[option]);
            if amount != 0 { format(out, " #", amount); }
        }
        return done();
    }
    if top == 0xd0 {
        // adc/adcs/sbc/sbcs, ngc
        let sub = bit(w, 30);
        let flags = bit(w, 29);
        if bits(w, 10, 6) != 0 { return unknown(w, out); }
        if sub && rn == 31 {
            op(out, if flags { "ngcs" } else { "ngc" });
            reg(out, rd, wide, false);
        } else {
            op(out, if sub { if flags { "sbcs" } else { "sbc" } } else { if flags { "adcs" } else { "adc" } });
            reg(out, rd, wide, false);
            sep(out);
            reg(out, rn, wide, false);
        }
        sep(out);
        reg(out, rm, wide, false);
        return done();
    }
    if top == 0xd2 && bit(w, 29) && !bit(w, 10) && !bit(w, 4) {
        // ccmp/ccmn, register or immediate
        op(out, if bit(w, 30) { "ccmp" } else { "ccmn" });
        reg(out, rn, wide, false);
        sep(out);
        if bit(w, 11) { imm(out, rm); } else { reg(out, rm, wide, false); }
        sep(out);
        imm(out, bits(w, 0, 4));
        format(out, ", ", CONDS[bits(w, 12, 4)]);
        return done();
    }
    if top == 0xd4 && !bit(w, 29) && !bit(w, 11) {
        // csel/csinc/csinv/csneg and their aliases
        let k = bits(w, 30, 1) * 2 + bits(w, 10, 1);
        let cond = bits(w, 12, 4);
        let inv = CONDS[cond ^ 1];
        if k != 0 && cond < 14 && rn == rm {
            if rn == 31 && k != 3 {
                op(out, if k == 1 { "cset" } else { "csetm" });
                reg(out, rd, wide, false);
                format(out, ", ", inv);
                return done();
            }
            if rn != 31 || k == 3 {
                op(out, ["", "cinc", "cinv", "cneg"][k]);
                reg(out, rd, wide, false);
                sep(out);
                reg(out, rn, wide, false);
                format(out, ", ", inv);
                return done();
            }
        }
        op(out, ["csel", "csinc", "csinv", "csneg"][k]);
        reg(out, rd, wide, false);
        sep(out);
        reg(out, rn, wide, false);
        sep(out);
        reg(out, rm, wide, false);
        format(out, ", ", CONDS[cond]);
        return done();
    }
    if top == 0xd6 && !bit(w, 30) && !bit(w, 29) {
        // udiv/sdiv, and the variable shifts as their aliases
        let opc = bits(w, 10, 6);
        let name = if opc == 2 { "udiv" } else if opc == 3 { "sdiv" } else if opc == 8 { "lsl" }
                   else if opc == 9 { "lsr" } else if opc == 10 { "asr" } else if opc == 11 { "ror" } else { "" };
        if name.len == 0 { return unknown(w, out); }
        op(out, name);
        reg(out, rd, wide, false); sep(out); reg(out, rn, wide, false); sep(out); reg(out, rm, wide, false);
        return done();
    }
    if top == 0xd6 && bit(w, 30) && !bit(w, 29) && rm == 0 {
        // rbit/rev16/rev/clz/cls/rev32
        let opc = bits(w, 10, 6);
        let name = if opc == 0 { "rbit" } else if opc == 1 { "rev16" }
                   else if opc == 2 { if wide { "rev32" } else { "rev" } }
                   else if opc == 3 && wide { "rev" } else if opc == 4 { "clz" } else if opc == 5 { "cls" } else { "" };
        if name.len == 0 { return unknown(w, out); }
        op(out, name);
        reg(out, rd, wide, false); sep(out); reg(out, rn, wide, false);
        return done();
    }
    if bits(w, 24, 5) == 0x1b {
        // the three-source multiplies
        if bits(w, 29, 2) != 0 { return unknown(w, out); }
        let op31 = bits(w, 21, 3);
        let o0 = bit(w, 15);
        let ra = bits(w, 10, 5);
        if op31 == 0 {
            let alias = ra == 31;
            op(out, if o0 { if alias { "mneg" } else { "msub" } } else { if alias { "mul" } else { "madd" } });
            reg(out, rd, wide, false); sep(out); reg(out, rn, wide, false); sep(out); reg(out, rm, wide, false);
            if !alias { sep(out); reg(out, ra, wide, false); }
            return done();
        }
        if !wide { return unknown(w, out); }
        if op31 == 2 || op31 == 6 {
            if o0 || ra != 31 { return unknown(w, out); }
            op(out, if op31 == 2 { "smulh" } else { "umulh" });
            reg(out, rd, true, false); sep(out); reg(out, rn, true, false); sep(out); reg(out, rm, true, false);
            return done();
        }
        if op31 == 1 || op31 == 5 {
            let u = op31 == 5;
            let alias = ra == 31;
            let name = if alias { if o0 { if u { "umnegl" } else { "smnegl" } } else { if u { "umull" } else { "smull" } } }
                       else { if o0 { if u { "umsubl" } else { "smsubl" } } else { if u { "umaddl" } else { "smaddl" } } };
            op(out, name);
            reg(out, rd, true, false); sep(out); reg(out, rn, false, false); sep(out); reg(out, rm, false, false);
            if !alias { sep(out); reg(out, ra, true, false); }
            return done();
        }
        return unknown(w, out);
    }
    unknown(w, out)
}

// --- SIMD and floating point ---------------------------------------------

fn freg(out: u8[>..]&, n: i64, ftype: i64) { format(out, ["s", "d", "?", "h"][ftype], n); }
fn vreg(out: u8[>..]&, n: i64) { format(out, "v", n); }

// The arrangement of a vector by its size field and Q.
fn arrangement(size: i64, q: bool) -> const u8[:] {
    [["8b", "16b"], ["4h", "8h"], ["2s", "4s"], ["1d", "2d"]][size][if q { 1 } else { 0 }]
}

// VFPExpandImm, as a double.
fn fp_imm(imm8: i64) -> f64 {
    let b = (imm8 >> 6) & 1;
    let cd = (imm8 >> 4) & 3;
    let frac = imm8 & 15;
    var v = 1.0 + frac / 16.0;
    var e = if b == 1 { cd - 3 } else { cd + 1 };
    while e > 0 { v *= 2.0; e--; }
    while e < 0 { v /= 2.0; e++; }
    if (imm8 >> 7) & 1 == 1 { -v } else { v }
}

fn simd_fp(w: u32, out: u8[>..]&) -> Decoded {
    let rd = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    let rm = bits(w, 16, 5);
    if bits(w, 24, 5) == 0x1e && bit(w, 21) && !bit(w, 30) {
        let ftype = bits(w, 22, 2);
        if ftype == 2 || bit(w, 29) { return unknown(w, out); }
        let sf = bit(w, 31);
        if sf && bits(w, 10, 6) != 0 { return unknown(w, out); }
        if bits(w, 10, 6) == 0 {
            // conversions between general registers and floating point
            let rmode = bits(w, 19, 2);
            let opc = bits(w, 16, 3);
            let k = rmode * 8 + opc;
            let names: const u8[:][32] = ["fcvtns", "fcvtnu", "scvtf", "ucvtf", "fcvtas", "fcvtau", "fmov", "fmov",
                                          "fcvtps", "fcvtpu", "", "", "", "", "", "",
                                          "fcvtms", "fcvtmu", "", "", "", "", "", "",
                                          "fcvtzs", "fcvtzu", "", "", "", "", "", ""];
            let name = names[k];
            if name.len == 0 { return unknown(w, out); }
            // fmov moves bits: the registers are one width (a half either way).
            if name == "fmov" && ftype != 3 && sf != (ftype == 1) { return unknown(w, out); }
            op(out, name);
            // To floating point: scvtf, ucvtf and fmov from a general register.
            if opc == 2 || opc == 3 || opc == 7 {
                freg(out, rd, ftype); sep(out); reg(out, rn, sf, false);
            } else {
                reg(out, rd, sf, false); sep(out); freg(out, rn, ftype);
            }
            return done();
        }
        if bits(w, 10, 5) == 0x10 {
            // one source
            let opc = bits(w, 15, 6);
            if opc >= 4 && opc <= 7 {
                // fcvt to single, double or half
                let to = opc - 4;
                if to == 2 || to == ftype { return unknown(w, out); }
                op(out, "fcvt");
                freg(out, rd, to); sep(out); freg(out, rn, ftype);
                return done();
            }
            let names: const u8[:][16] = ["fmov", "fabs", "fneg", "fsqrt", "", "", "", "",
                                          "frintn", "frintp", "frintm", "frintz", "frinta", "", "frintx", "frinti"];
            if opc >= 16 || names[opc].len == 0 { return unknown(w, out); }
            op(out, names[opc]);
            freg(out, rd, ftype); sep(out); freg(out, rn, ftype);
            return done();
        }
        if bits(w, 10, 4) == 0x8 && bits(w, 0, 3) == 0 && bits(w, 14, 2) == 0 {
            // fcmp, fcmpe
            let opc2 = bits(w, 3, 2);
            op(out, if opc2 & 2 == 2 { "fcmpe" } else { "fcmp" });
            freg(out, rn, ftype);
            sep(out);
            if opc2 & 1 == 1 { out.append("#0.0"); } else { freg(out, rm, ftype); }
            return done();
        }
        if bits(w, 10, 3) == 0x4 && bits(w, 5, 5) == 0 {
            // fmov immediate
            op(out, "fmov");
            freg(out, rd, ftype);
            out.append(", #");
            format_flt(out, fp_imm(bits(w, 13, 8)), 8);
            return done();
        }
        if bits(w, 10, 2) == 2 {
            // two sources
            let opc = bits(w, 12, 4);
            let names: const u8[:][9] = ["fmul", "fdiv", "fadd", "fsub", "fmax", "fmin", "fmaxnm", "fminnm", "fnmul"];
            if opc > 8 { return unknown(w, out); }
            op(out, names[opc]);
            freg(out, rd, ftype); sep(out); freg(out, rn, ftype); sep(out); freg(out, rm, ftype);
            return done();
        }
        if bits(w, 10, 2) == 3 {
            op(out, "fcsel");
            freg(out, rd, ftype); sep(out); freg(out, rn, ftype); sep(out); freg(out, rm, ftype);
            format(out, ", ", CONDS[bits(w, 12, 4)]);
            return done();
        }
        if bits(w, 10, 2) == 1 {
            // fccmp, fccmpe
            op(out, if bit(w, 4) { "fccmpe" } else { "fccmp" });
            freg(out, rn, ftype); sep(out); freg(out, rm, ftype); sep(out);
            imm(out, bits(w, 0, 4));
            format(out, ", ", CONDS[bits(w, 12, 4)]);
            return done();
        }
        return unknown(w, out);
    }
    if bits(w, 24, 5) == 0x1e && !bit(w, 21) && !bit(w, 30) {
        // conversions to and from fixed point
        if bit(w, 29) { return unknown(w, out); }
        let ftype = bits(w, 22, 2);
        let sf = bit(w, 31);
        let rmode = bits(w, 19, 2);
        let opc = bits(w, 16, 3);
        let scale = bits(w, 10, 6);
        if ftype == 2 || (!sf && scale < 32) { return unknown(w, out); }
        let name = if rmode == 0 && opc == 2 { "scvtf" } else if rmode == 0 && opc == 3 { "ucvtf" }
                   else if rmode == 3 && opc == 0 { "fcvtzs" } else if rmode == 3 && opc == 1 { "fcvtzu" } else { "" };
        if name.len == 0 { return unknown(w, out); }
        op(out, name);
        if opc >= 2 { freg(out, rd, ftype); sep(out); reg(out, rn, sf, false); }
        else { reg(out, rd, sf, false); sep(out); freg(out, rn, ftype); }
        sep(out);
        imm(out, 64 - scale);
        return done();
    }
    if !bit(w, 31) && bit(w, 30) && bits(w, 24, 5) == 0x1e && bit(w, 21) && bit(w, 10) && bits(w, 22, 2) == 3 {
        // scalar three registers: the 64-bit compares and arithmetic
        let u = bit(w, 29);
        let opc = bits(w, 11, 5);
        let name = if opc == 6 { if u { "cmhi" } else { "cmgt" } } else if opc == 7 { if u { "cmhs" } else { "cmge" } }
                   else if opc == 16 { if u { "sub" } else { "add" } } else if opc == 17 { if u { "cmeq" } else { "cmtst" } }
                   else { "" };
        if name.len == 0 { return unknown(w, out); }
        op(out, name);
        format(out, "d", rd, ", d", rn, ", d", rm);
        return done();
    }
    if w & 0xfffffc00 == 0x5ef1b800 {
        // addp of a vector's two doublewords into a scalar
        format(out, "addp.2d\td", rd, ", v", rn);
        return done();
    }
    if bits(w, 24, 8) == 0x1f {
        // fmadd/fmsub/fnmadd/fnmsub
        let ftype = bits(w, 22, 2);
        if bits(w, 29, 3) != 0 { return unknown(w, out); }
        if ftype == 2 { return unknown(w, out); }
        let k = bits(w, 21, 1) * 2 + bits(w, 15, 1);
        op(out, ["fmadd", "fmsub", "fnmadd", "fnmsub"][k]);
        freg(out, rd, ftype); sep(out); freg(out, rn, ftype); sep(out); freg(out, rm, ftype); sep(out);
        freg(out, bits(w, 10, 5), ftype);
        return done();
    }
    if bits(w, 22, 10) == 0x338 && !bit(w, 15) || bits(w, 21, 11) == 0x671 && !bit(w, 15) {
        // eor3, bcax (SHA3): four registers
        format(out, if bit(w, 21) { "bcax.16b\t" } else { "eor3.16b\t" });
        vreg(out, rd); sep(out); vreg(out, rn); sep(out); vreg(out, rm); sep(out); vreg(out, bits(w, 10, 5));
        return done();
    }
    if bits(w, 21, 11) == 0x2f0 && bits(w, 10, 6) == 1 {
        // mov (dup, element to scalar)
        let imm5 = bits(w, 16, 5);
        if imm5 & 15 == 0 { return unknown(w, out); }
        var esize = 0;
        while (imm5 >> esize) & 1 == 0 { esize++; }
        format(out, "mov\t", ["b", "h", "s", "d"][esize], rd, ", v", rn, "[", imm5 >> (esize + 1), "]");
        return done();
    }
    if !bit(w, 31) && bit(w, 30) && bits(w, 24, 5) == 0x1e && bits(w, 17, 5) == 0x10 && bits(w, 10, 2) == 2 &&
       bits(w, 12, 5) == 29 && !bit(w, 23) {
        // scalar scvtf/ucvtf of an integer in a vector register
        let ft = bits(w, 22, 1);
        op(out, if bit(w, 29) { "ucvtf" } else { "scvtf" });
        freg(out, rd, ft); sep(out); freg(out, rn, ft);
        return done();
    }
    if !bit(w, 31) && bit(w, 30) && bits(w, 24, 5) == 0x1e && bits(w, 17, 5) == 0x10 && bits(w, 10, 2) == 2 &&
       bits(w, 12, 5) == 27 && bit(w, 23) {
        // scalar fcvtzs/fcvtzu, to an integer in a vector register
        let ft = bits(w, 22, 1);
        op(out, if bit(w, 29) { "fcvtzu" } else { "fcvtzs" });
        freg(out, rd, ft); sep(out); freg(out, rn, ft);
        return done();
    }
    if !bit(w, 31) && bit(w, 30) && bits(w, 24, 5) == 0x1e && bits(w, 17, 5) == 0x18 && bits(w, 10, 2) == 2 {
        // scalar pairwise: faddp, fmaxp, fminp, fmaxnmp, fminnmp
        let opc = bits(w, 12, 5);
        let u = bit(w, 29);
        let a = bit(w, 23);
        let sz = bits(w, 22, 1);
        let name = if !u { "" } else if opc == 13 && !a { "faddp" } else if opc == 15 { if a { "fminp" } else { "fmaxp" } }
                   else if opc == 12 { if a { "fminnmp" } else { "fmaxnmp" } } else { "" };
        if name.len == 0 { return unknown(w, out); }
        format(out, name, ".", if sz == 1 { "2d" } else { "2s" }, "\t", if sz == 1 { "d" } else { "s" }, rd, ", v", rn);
        return done();
    }
    if !bit(w, 31) && !bit(w, 10) && (bits(w, 24, 5) == 0x0f || (bit(w, 30) && bits(w, 24, 5) == 0x1f)) {
        // by element: a vector (01111, bit 30 Q) or a scalar (01 ... 11111)
        return by_element(w, out, bits(w, 24, 5) == 0x1f);
    }
    if bit(w, 31) { return unknown(w, out); }
    let q = bit(w, 30);
    let u = bit(w, 29);
    let size = bits(w, 22, 2);
    if bits(w, 24, 5) == 0xe && !bit(w, 21) && bits(w, 10, 2) == 2 && !bit(w, 15) {
        // permutes: uzp, trn, zip
        let opc = bits(w, 12, 3);
        let names: const u8[:][8] = ["", "uzp1", "trn1", "zip1", "", "uzp2", "trn2", "zip2"];
        if names[opc].len == 0 || u || (size == 3 && !q) { return unknown(w, out); }
        format(out, names[opc], ".", arrangement(size, q), "\t");
        vreg(out, rd); sep(out); vreg(out, rn); sep(out); vreg(out, rm);
        return done();
    }
    if bits(w, 24, 6) == 0xe && bits(w, 21, 3) == 0 && bits(w, 10, 2) == 0 && !bit(w, 15) {
        // tbl, tbx
        let len = bits(w, 13, 2);
        format(out, if bit(w, 12) { "tbx." } else { "tbl." }, arrangement(0, q), "\t");
        vreg(out, rd);
        out.append(", { ");
        for k in len + 1 { if k > 0 { sep(out); } vreg(out, (rn + k) % 32); }
        out.append(" }, ");
        vreg(out, rm);
        return done();
    }
    if bits(w, 24, 5) == 0xe && bit(w, 21) && bits(w, 10, 2) == 0 {
        // three registers of different widths: the widening arithmetic
        let opc = bits(w, 12, 4);
        let names_s: const u8[:][16] = ["saddl", "saddw", "ssubl", "ssubw", "addhn", "sabal", "subhn", "sabdl",
                                        "smlal", "", "smlsl", "", "smull", "", "pmull", ""];
        let names_u: const u8[:][16] = ["uaddl", "uaddw", "usubl", "usubw", "raddhn", "uabal", "rsubhn", "uabdl",
                                        "umlal", "", "umlsl", "", "umull", "", "", ""];
        let name = if u { names_u[opc] } else { names_s[opc] };
        if name.len == 0 || size == 3 || (name == "pmull" && size != 0) { return unknown(w, out); }
        let narrow = opc == 4 || opc == 6;
        format(out, name, if q { "2" } else { "" }, ".",
               if narrow { arrangement(size, q) } else { arrangement(size + 1, true) }, "\t");
        vreg(out, rd); sep(out); vreg(out, rn); sep(out); vreg(out, rm);
        return done();
    }
    if bits(w, 24, 5) == 0xe && bits(w, 17, 5) == 0x18 && bits(w, 10, 2) == 2 {
        // across the lanes: addv, saddlv/uaddlv, smaxv/umaxv, sminv/uminv
        let opc = bits(w, 12, 5);
        let name = if opc == 27 && !u { "addv" } else if opc == 3 { if u { "uaddlv" } else { "saddlv" } }
                   else if opc == 10 { if u { "umaxv" } else { "smaxv" } } else if opc == 26 { if u { "uminv" } else { "sminv" } }
                   else { "" };
        if name.len == 0 || size == 3 || (size == 2 && !q) { return unknown(w, out); }
        let dsize = if opc == 3 { size + 1 } else { size };
        format(out, name, ".", arrangement(size, q), "\t", ["b", "h", "s", "d"][dsize], rd, ", v", rn);
        return done();
    }
    if bits(w, 24, 5) == 0xe && bit(w, 21) && bit(w, 10) {
        // three registers of the same arrangement
        let opc = bits(w, 11, 5);
        if opc == 3 {
            // the bitwise ones, by size; orr of one register twice is mov
            let names: const u8[:][8] = ["and", "bic", "orr", "orn", "eor", "bsl", "bit", "bif"];
            let name = names[(if u { 4 } else { 0 }) + size];
            if name == "orr" && rn == rm {
                format(out, "mov.", arrangement(0, q), "\t");
                vreg(out, rd); sep(out); vreg(out, rn);
                return done();
            }
            format(out, name, ".", arrangement(0, q), "\t");
        } else if opc >= 24 {
            // floating point: size's high bit picks within the opcode, the low one the width
            let a = bit(w, 23);
            let k = opc - 24;
            let names_u0a0: const u8[:][8] = ["fmaxnm", "fmla", "fadd", "fmulx", "fcmeq", "", "fmax", "frecps"];
            let names_u0a1: const u8[:][8] = ["fminnm", "fmls", "fsub", "", "", "", "fmin", "frsqrts"];
            let names_u1a0: const u8[:][8] = ["fmaxnmp", "", "faddp", "fmul", "fcmge", "facge", "fmaxp", "fdiv"];
            let names_u1a1: const u8[:][8] = ["fminnmp", "", "fabd", "", "fcmgt", "facgt", "fminp", ""];
            let name = if u { if a { names_u1a1[k] } else { names_u1a0[k] } } else { if a { names_u0a1[k] } else { names_u0a0[k] } };
            let sz = size & 1;
            if name.len == 0 || (sz == 1 && !q) { return unknown(w, out); }
            format(out, name, ".", arrangement(2 + sz, q), "\t");
        } else {
            let names_u0: const u8[:][32] = ["shadd", "sqadd", "", "", "", "sqsub", "cmgt", "cmge",
                                             "sshl", "", "", "", "smax", "smin", "", "",
                                             "add", "cmtst", "mla", "mul", "smaxp", "sminp", "", "addp",
                                             "", "", "", "", "", "", "", ""];
            let names_u1: const u8[:][32] = ["uhadd", "uqadd", "", "", "", "uqsub", "cmhi", "cmhs",
                                             "ushl", "", "", "", "umax", "umin", "", "",
                                             "sub", "cmeq", "mls", "pmul", "umaxp", "uminp", "", "",
                                             "", "", "", "", "", "", "", ""];
            let name = if u { names_u1[opc] } else { names_u0[opc] };
            if name.len == 0 || (size == 3 && !q) { return unknown(w, out); }
            // 64-bit elements only for the adds, subtracts, compares and shifts.
            let has64 = opc == 1 || opc == 5 || opc == 6 || opc == 7 || opc == 8 || opc == 16 || opc == 17 || opc == 23;
            if size == 3 && !has64 { return unknown(w, out); }
            if (name == "pmul" && size != 0) || (opc == 23 && u) { return unknown(w, out); }
            format(out, name, ".", arrangement(size, q), "\t");
        }
        vreg(out, rd); sep(out); vreg(out, rn); sep(out); vreg(out, rm);
        return done();
    }
    if bits(w, 24, 6) == 0x2e && !bit(w, 21) && !bit(w, 15) && !bit(w, 10) && size == 0 && (q || !bit(w, 14)) {
        format(out, "ext.", arrangement(0, q), "\t");
        vreg(out, rd); sep(out); vreg(out, rn); sep(out); vreg(out, rm); sep(out);
        imm(out, bits(w, 11, 4));
        return done();
    }
    if bits(w, 24, 5) == 0xe && bits(w, 17, 5) == 0x10 && bits(w, 10, 2) == 2 {
        // two registers, miscellaneous
        let opc = bits(w, 12, 5);
        if size == 3 && !q { return unknown(w, out); }
        var name = "";
        if !u {
            name = if opc == 0 { "rev64" } else if opc == 1 { "rev16" } else if opc == 5 { "cnt" }
                   else if opc == 8 { "cmgt" } else if opc == 9 { "cmeq" } else if opc == 10 { "cmlt" }
                   else if opc == 11 { "abs" } else { "" };
        } else {
            name = if opc == 0 { "rev32" } else if opc == 5 && size == 0 { "mvn" }
                   else if opc == 8 { "cmge" } else if opc == 9 { "cmle" } else if opc == 11 { "neg" } else { "" };
        }
        if name.len == 0 && opc == 18 && !u && size < 3 {
            format(out, if q { "xtn2." } else { "xtn." }, arrangement(size, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn);
            return done();
        }
        if name.len == 0 && (opc == 29 || opc == 27) {
            // scvtf/ucvtf (size high bit clear), fcvtzs/fcvtzu (set)
            let a = size >= 2;
            let fname = if opc == 29 && !a { if u { "ucvtf" } else { "scvtf" } }
                        else if opc == 27 && a { if u { "fcvtzu" } else { "fcvtzs" } } else { "" };
            let sz = size & 1;
            if fname.len == 0 || (sz == 1 && !q) { return unknown(w, out); }
            format(out, fname, ".", arrangement(2 + sz, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn);
            return done();
        }
        if name.len == 0 {
            // fneg/fabs of a vector: size's high bit and the low one for the width
            if opc == 15 && size >= 2 {
                format(out, if u { "fneg." } else { "fabs." }, arrangement(size, q), "\t");
                vreg(out, rd); sep(out); vreg(out, rn);
                return done();
            }
            return unknown(w, out);
        }
        format(out, name, ".", arrangement(if name == "mvn" { 0 } else { size }, q), "\t");
        vreg(out, rd); sep(out); vreg(out, rn);
        if opc >= 8 && opc <= 10 { out.append(", #0"); }
        return done();
    }
    if bits(w, 19, 10) == 0x1e0 && bit(w, 10) && !bit(w, 11) {
        // movi/mvni/orr/bic, modified immediate: the cases clang uses
        let cmode = bits(w, 12, 4);
        let abc = bits(w, 16, 3);
        let defgh = bits(w, 5, 5);
        let imm8 = (abc << 5) | defgh;
        if u && cmode == 14 {
            // each bit a byte of 0x00 or 0xff
            if q { out.append("movi.2d\t"); vreg(out, rd); }
            else { format(out, "movi\td", rd); }
            out.append(", #");
            var v: u64 = 0;
            for k in 8 { if (imm8 >> k) & 1 == 1 { v |= (0xff as u64) << (k * 8); } }
            // printf's %#016llx: no 0x for zero, which then fills the width.
            if v == 0 { out.append("0000000000000000"); }
            else { out.append("0x"); format_uint(out, v, 16, 14, '0'); }
            return done();
        }
        if !u && cmode == 14 {
            format(out, "movi.", arrangement(0, q), "\t");
            vreg(out, rd); sep(out); imm(out, imm8);
            return done();
        }
        if cmode == 15 && !bit(w, 11) {
            // fmov of an immediate to every element
            if u && !q { return unknown(w, out); }
            format(out, "fmov.", if u { "2d" } else { arrangement(2, q) }, "\t");
            vreg(out, rd);
            out.append(", #");
            format_flt(out, fp_imm(imm8), 8);
            return done();
        }
        if cmode & 0x9 == 0x1 || cmode & 0xd == 0x9 {
            // orr/bic of a shifted immediate
            let half = cmode & 0x8 == 0x8;
            format(out, if u { "bic." } else { "orr." }, if half { arrangement(1, q) } else { arrangement(2, q) }, "\t");
            vreg(out, rd); sep(out); imm(out, imm8);
            let shift = if half { ((cmode >> 1) & 1) * 8 } else { ((cmode >> 1) & 3) * 8 };
            if shift != 0 { format(out, ", lsl #", shift); }
            return done();
        }
        if u && ((cmode & 0x9) == 0 || (cmode & 0xd) == 0x8) {
            let half = cmode & 0x8 == 0x8;
            format(out, "mvni.", if half { arrangement(1, q) } else { arrangement(2, q) }, "\t");
            vreg(out, rd); sep(out); imm(out, imm8);
            let shift = if half { ((cmode >> 1) & 1) * 8 } else { ((cmode >> 1) & 3) * 8 };
            if shift != 0 { format(out, ", lsl #", shift); }
            return done();
        }
        if !u && (cmode & 0x9) == 0 || !u && (cmode & 0xd) == 0x8 {
            let half = cmode & 0x8 == 0x8;
            format(out, "movi.", if half { arrangement(1, q) } else { arrangement(2, q) }, "\t");
            vreg(out, rd); sep(out); imm(out, imm8);
            let shift = if half { ((cmode >> 1) & 1) * 8 } else { ((cmode >> 1) & 3) * 8 };
            if shift != 0 { format(out, ", lsl #", shift); }
            return done();
        }
        return unknown(w, out);
    }
    if bits(w, 21, 8) == 0x70 && bit(w, 10) && !bit(w, 15) {
        // dup, ins, smov/umov: copies between elements and registers
        let imm5 = bits(w, 16, 5);
        let imm4 = bits(w, 11, 4);
        if imm5 & 15 == 0 { return unknown(w, out); }
        var esize = 0;
        while (imm5 >> esize) & 1 == 0 { esize++; }
        let index = imm5 >> (esize + 1);
        let ename = ["b", "h", "s", "d"][esize];
        if !u && imm4 == 1 {
            format(out, "dup.", arrangement(esize, q), "\t");
            vreg(out, rd); sep(out); reg(out, rn, esize == 3, false);
            return done();
        }
        if !u && imm4 == 0 {
            format(out, "dup.", arrangement(esize, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); format(out, "[", index, "]");
            return done();
        }
        if !u && imm4 == 3 && q {
            format(out, "mov.", ename, "\t");
            vreg(out, rd); format(out, "[", index, "]"); sep(out); reg(out, rn, esize == 3, false);
            return done();
        }
        if !u && (imm4 == 7 || imm4 == 5) {
            let unsigned = imm4 == 7;
            let wide = q;
            // umov: w for b/h/s, x for d; smov: w for b/h, x for b/h/s.
            if unsigned && (q != (esize == 3)) { return unknown(w, out); }
            if !unsigned && (esize == 3 || (!q && esize == 2)) { return unknown(w, out); }
            if unsigned && (esize >= 2) { format(out, "mov.", ename, "\t"); }
            else { format(out, if unsigned { "umov." } else { "smov." }, ename, "\t"); }
            reg(out, rd, wide, false); sep(out); vreg(out, rn); format(out, "[", index, "]");
            return done();
        }
        if u && q {
            let src = imm4 >> esize;
            format(out, "mov.", ename, "\t");
            vreg(out, rd); format(out, "[", index, "]"); sep(out); vreg(out, rn); format(out, "[", src, "]");
            return done();
        }
        return unknown(w, out);
    }
    if bits(w, 23, 6) == 0x1e && bit(w, 10) && bits(w, 19, 4) != 0 {
        // shifts by an immediate: shl, sshr/ushr, sshll/ushll and xtl
        let immh = bits(w, 19, 4);
        let immb = bits(w, 16, 3);
        let opc = bits(w, 11, 5);
        var esize = 3;
        while (immh >> esize) & 1 == 0 { esize--; }
        if esize == 3 && !q && opc != 0x14 { return unknown(w, out); }
        let ebits = 8 << esize;
        let shift = ((immh << 3) | immb) - ebits;
        if opc == 0x14 {
            // sshll/ushll: the wider arrangement, and 2 for the upper half
            if esize == 3 { return unknown(w, out); }
            format(out, if u { "ushll" } else { "sshll" }, if q { "2" } else { "" }, ".",
                   arrangement(esize + 1, true), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); sep(out); imm(out, shift);
            return done();
        }
        if opc == 0xa && !u {
            format(out, "shl.", arrangement(esize, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); sep(out); imm(out, shift);
            return done();
        }
        if opc == 2 || (u && opc == 8) {
            // usra/ssra accumulate; sri inserts
            let name = if opc == 8 { "sri." } else if u { "usra." } else { "ssra." };
            format(out, name, arrangement(esize, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); sep(out); imm(out, 2 * ebits - ((immh << 3) | immb));
            return done();
        }
        if u && opc == 0xa {
            format(out, "sli.", arrangement(esize, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); sep(out); imm(out, shift);
            return done();
        }
        if !u && opc == 0x10 {
            // shrn: to the narrower arrangement, 2 for the upper half
            if esize == 3 { return unknown(w, out); }
            format(out, if q { "shrn2." } else { "shrn." }, arrangement(esize, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); sep(out); imm(out, 2 * ebits - ((immh << 3) | immb));
            return done();
        }
        if opc == 0 {
            format(out, if u { "ushr." } else { "sshr." }, arrangement(esize, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); sep(out); imm(out, 2 * ebits - ((immh << 3) | immb));
            return done();
        }
        return unknown(w, out);
    }
    unknown(w, out)
}

// Multiplies by one element of a vector: fmul/fmla/fmls and mul/mla/mls,
// vector or scalar.
fn by_element(w: u32, out: u8[>..]&, scalar: bool) -> Decoded {
    let q = bit(w, 30);
    let u = bit(w, 29);
    let size = bits(w, 22, 2);
    let l = bits(w, 21, 1);
    let m = bits(w, 20, 1);
    let h = bits(w, 11, 1);
    let opc = bits(w, 12, 4);
    let rd = bits(w, 0, 5);
    let rn = bits(w, 5, 5);
    let fp = opc == 9 || opc == 1 || opc == 5;
    if fp {
        if u || size < 2 { return unknown(w, out); }
        let sz = size & 1;
        if sz == 1 && l == 1 { return unknown(w, out); }
        let index = if sz == 1 { h } else { (h << 1) | l };
        let rm = (m << 4) | bits(w, 16, 4);
        let name = if opc == 9 { "fmul" } else if opc == 1 { "fmla" } else { "fmls" };
        let e = if sz == 1 { "d" } else { "s" };
        if scalar {
            format(out, name, ".", e, "\t", e, rd, ", ", e, rn, ", v", rm, "[", index, "]");
        } else {
            if sz == 1 && !q { return unknown(w, out); }
            format(out, name, ".", arrangement(2 + sz, q), "\t");
            vreg(out, rd); sep(out); vreg(out, rn); format(out, ", v", rm, "[", index, "]");
        }
        return done();
    }
    if scalar || (opc != 8 && opc != 0 && opc != 4) || u && opc == 8 || size == 0 || size == 3 { return unknown(w, out); }
    let index = if size == 1 { (h << 2) | (l << 1) | m } else { (h << 1) | l };
    let rm = if size == 1 { bits(w, 16, 4) } else { (m << 4) | bits(w, 16, 4) };
    let name = if opc == 8 { "mul" } else if opc == 0 { "mla" } else { "mls" };
    if (opc == 0 || opc == 4) && !u { return unknown(w, out); }
    format(out, name, ".", arrangement(size, q), "\t");
    vreg(out, rd); sep(out); vreg(out, rn); format(out, ", v", rm, "[", index, "]");
    done()
}
