// Numbers: integers and doubles to text and back.
//
// Writing a double gives the shortest decimal that reads back as the same
// double (Schubfach, as drachennest's schubfach_64 implements it), laid out
// as JavaScript's Number.prototype.toString does. Reading one is correctly
// rounded: Clinger's fast path, then Eisel-Lemire (fast_float), then exact
// decimal arithmetic for the few inputs those cannot decide (Go's strconv).

namespace json;

import std;

// --- integers out --------------------------------------------------------------

// Eight ASCII digits of v < 10^8 in one word, the most significant in
// lane 0 so that the word's bytes read in order: split into halves, the
// halves into pairs, the pairs into digits, every lane at once.
fn encode8(v: u64) -> u64 {
    let hi = v / 10000;
    var x = hi | ((v - hi * 10000) << 32);                       // 32-bit lanes: abcd, efgh
    let q2 = ((x * 10486) >> 20) & 0x0000007f0000007f;           // each lane / 100
    x = q2 | ((x - q2 * 100) << 16);                              // 16-bit lanes: ab cd ef gh
    let q1 = ((x * 103) >> 10) & 0x000f000f000f000f;             // each lane / 10
    x = q1 | ((x - q1 * 10) << 8);                                // bytes: a b c d e f g h
    return x + 0x3030303030303030;
}

const POW10_U64: u64[20] = [
    1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000,
    10000000000, 100000000000, 1000000000000, 10000000000000, 100000000000000,
    1000000000000000, 10000000000000000, 100000000000000000, 1000000000000000000,
    10000000000000000000,
];

// How many decimal digits v has.
fn decimal_len(v: u64) -> i64 {
    let t = ((64 - clz64(v | 1)) * 1233) >> 12;
    return t + 1 - (if v < POW10_U64[t] { 1 } else { 0 });
}

// The decimal digits of v as the last bytes of three words; returns how
// many there are. The text is bytes_of(words)[24 - n..].
fn digits_into(words: u64[3]&, v: u64) -> i64 {
    let n = decimal_len(v);
    let c = v % 100000000;
    words[2] = encode8(c);
    if n > 8 {
        let t = v / 100000000;
        words[1] = encode8(t % 100000000);
        if n > 16 { words[0] = encode8(t / 100000000); }
    }
    return n;
}

fn write_uint<A>(out: A&, v: u64) {
    if v < 10 { out.push(('0' + v) as u8); return; }
    var words: u64[3] = [0, 0, 0];
    let n = digits_into(words, v);
    out.append(bytes_of(words)[24 - n..]);
}

fn write_int<A>(out: A&, v: i64) {
    if v < 0 {
        out.push('-');
        write_uint(out, 0 - (v as! u64));
    } else {
        write_uint(out, v as u64);
    }
}

// --- doubles out ------------------------------------------------------------------

// g * cp for a 128-bit g = (ghi, glo): the three words of the product,
// high first.
fn mul192(ghi: u64, glo: u64, cp: u64) -> u64, u64, u64 {
    let xhi, xlo = mul128(glo, cp);
    let yhi, ylo = mul128(ghi, cp);
    let p1 = ylo + xhi;
    return yhi + (if p1 < xhi { 1 } else { 0 }), p1, xlo;
}

// g shifted left by s in [1, 63], as three words, high first.
fn shl192(ghi: u64, glo: u64, s: i64) -> u64, u64, u64 {
    return ghi >> (64 - s), (ghi << s) | (glo >> (64 - s)), glo << s;
}

// The shortest c * 10^k that reads back as the positive finite double
// with these bits; the closest one, then the even one, if several are.
fn shortest(bits: u64) -> u64, i64 {
    let ieee_m = bits & 0xfffffffffffff;
    let ieee_e = ((bits >> 52) & 0x7ff) as i64;
    var c = ieee_m;
    var q = -1074;
    if ieee_e != 0 {
        c = ieee_m | (1 << 52);
        q = ieee_e - 1075;
        // An integer below 2^53: the integer itself.
        if q <= 0 && q > -53 {
            let m = c >> -q;
            if m << -q == c { return m, 0; }
        }
    }
    let even = (c & 1) == 0;
    let closer = ieee_m == 0 && ieee_e > 1;
    let cb = 4 * c;
    // floor(log10(2^q)), or of 3/4 2^q when the lower neighbor is closer.
    let k = (q * 1262611 - (if closer { 524031 } else { 0 })) >> 22;
    // h = q + floor(log2(10^-k)) + 1
    let h = q + ((-k * 1741647) >> 19) + 1;
    let gi = -k + 292;
    let ghi = POW10_HI[gi];
    let glo = POW10_LO[gi];
    // vb rounded to odd from g * (cb << h). The neighbors' products differ
    // from it by g << (h + 1) above and g << (h + 1) or g << h below
    // (cbr = cb + 2, cbl = cb - 2 or cb - 1), so one multiply gives all
    // three exactly; each is its high word, made odd when the middle word
    // shows more below it.
    let p2, p1, p0 = mul192(ghi, glo, cb << h);
    let vb = p2 | (if p1 > 1 { 1 } else { 0 });
    let r2, r1, r0 = shl192(ghi, glo, h + 1);
    let u0 = p0 + r0;
    let ca: u64 = if u0 < p0 { 1 } else { 0 };
    let t1 = p1 + r1;
    let cb1: u64 = if t1 < p1 { 1 } else { 0 };
    let u1 = t1 + ca;
    let cb2: u64 = if u1 < t1 { 1 } else { 0 };
    let u2 = p2 + r2 + cb1 + cb2;
    let vbr = u2 | (if u1 > 1 { 1 } else { 0 });
    let l2, l1, l0 = shl192(ghi, glo, if closer { h } else { h + 1 });
    let w0 = p0 - l0;
    let ba: u64 = if p0 < l0 { 1 } else { 0 };
    let s1 = p1 - l1;
    let bb1: u64 = if p1 < l1 { 1 } else { 0 };
    let w1 = s1 - ba;
    let bb2: u64 = if s1 < ba { 1 } else { 0 };
    let w2 = p2 - l2 - bb1 - bb2;
    let vbl = w2 | (if w1 > 1 { 1 } else { 0 });
    let lower = vbl + (if even { 0 } else { 1 });
    let upper = vbr - (if even { 0 } else { 1 });
    let s = vb / 4;
    if s >= 10 {
        let sp = s / 10;
        let up_in = lower <= 40 * sp;
        let wp_in = 40 * sp + 40 <= upper;
        if up_in != wp_in { return sp + (if wp_in { 1 } else { 0 }), k + 1; }
    }
    let u_in = lower <= 4 * s;
    let w_in = 4 * s + 4 <= upper;
    if u_in != w_in { return s + (if w_in { 1 } else { 0 }), k; }
    let mid = 4 * s + 2;
    let up = vb > mid || (vb == mid && (s & 1) != 0);
    return s + (if up { 1 } else { 0 }), k;
}

// Writes a finite double as JavaScript does: plain notation for decimal
// exponents in [-7, 21), else d.ddde±x. NaN and the infinities, which
// JSON lacks, are written as null.
fn write_float<A>(out: A&, x: f64) {
    let bits = bits_of(x);
    if (bits >> 52) & 0x7ff == 0x7ff { out.append("null"); return; }
    if bits >> 63 != 0 { out.push('-'); }
    if bits << 1 == 0 { out.push('0'); return; }
    var c, k = shortest(bits);
    while c % 10 == 0 { c = c / 10; k += 1; }
    var words: u64[3] = [0, 0, 0];
    let n = digits_into(words, c);
    let digits = bytes_of(words)[24 - n..];
    let e = n + k;           // the value is 0.digits * 10^e
    if k >= 0 && e <= 21 {
        out.append(digits);
        for i in k { out.push('0'); }
    } else if e > 0 && e <= 21 {
        out.append(digits[..e]);
        out.push('.');
        out.append(digits[e..]);
    } else if e > -6 && e <= 0 {
        out.append("0.");
        for i in -e { out.push('0'); }
        out.append(digits);
    } else {
        out.push(digits[0]);
        if n > 1 { out.push('.'); out.append(digits[1..]); }
        out.push('e');
        let x10 = e - 1;
        if x10 < 0 { out.push('-'); } else { out.push('+'); }
        write_uint(out, abs(x10) as u64);
    }
}

// --- numbers in -------------------------------------------------------------------

// Whether the eight bytes of x are all ASCII digits.
fn eight_digits(x: u64) -> bool {
    return ((x & 0xf0f0f0f0f0f0f0f0) | (((x + 0x0606060606060606) & 0xf0f0f0f0f0f0f0f0) >> 4)) == 0x3333333333333333;
}

// The value of eight ASCII digits, lane 0 the most significant.
fn eight_value(x0: u64) -> u64 {
    var x = x0 - 0x3030303030303030;
    x = (x * 10) + (x >> 8);
    return ((((x & 0x000000ff000000ff) * 0x000f424000000064) + (((x >> 16) & 0x000000ff000000ff) * 0x0000271000000001)) >> 32) & 0xffffffff;
}

let NUM_INT = 0;      // fits i64; the bits are the i64's
let NUM_UINT = 1;     // above i64, fits u64
let NUM_FLOAT = 2;    // the bits are a double's
let NUM_BAD = -1;

// Reads the JSON number at s[at]. Returns its kind, its bits and the byte
// after it; NUM_BAD with the offending byte if the grammar is not met.
fn scan_number(s: const u8[:], at: i64) -> i64, u64, i64 {
    let n = s.len;
    var p = at;
    let neg = p < n && s[p] == '-';
    if neg { p += 1; }
    let first = p;
    var m: u64 = 0;
    if p < n && s[p] == '0' {
        p += 1;
    } else {
        while p + 8 <= n {
            let x = load8(s, p);
            if !eight_digits(x) { break; }
            m = m * 100000000 + eight_value(x);
            p += 8;
        }
        while p < n {
            let d = s[p] - '0';
            if d > 9 { break; }
            m = m * 10 + d;
            p += 1;
        }
        if p == first { return NUM_BAD, 0, p; }
    }
    let int_end = p;
    var float = false;
    var exp10: i64 = 0;
    var frac_digits = 0;
    if p < n && s[p] == '.' {
        float = true;
        p += 1;
        let fs = p;
        while p + 8 <= n {
            let x = load8(s, p);
            if !eight_digits(x) { break; }
            m = m * 100000000 + eight_value(x);
            p += 8;
        }
        while p < n {
            let d = s[p] - '0';
            if d > 9 { break; }
            m = m * 10 + d;
            p += 1;
        }
        frac_digits = p - fs;
        if frac_digits == 0 { return NUM_BAD, 0, p; }
        exp10 = -frac_digits;
    }
    if p < n && (s[p] | 0x20) == 'e' {
        float = true;
        p += 1;
        var eneg = false;
        if p < n && (s[p] == '-' || s[p] == '+') { eneg = s[p] == '-'; p += 1; }
        let es = p;
        var e: i64 = 0;
        while p < n {
            let d = s[p] - '0';
            if d > 9 { break; }
            if e < 100000000 { e = e * 10 + d; }
            p += 1;
        }
        if p == es { return NUM_BAD, 0, p; }
        exp10 += if eneg { -e } else { e };
    }
    let ndigits = (int_end - first) + frac_digits;
    if !float && ndigits <= 18 {
        let v = if neg { 0 - m } else { m };
        return NUM_INT, v, p;
    }
    if !float {
        // 19 or 20 digits: an integer if it fits, without wrapping.
        var v: u64 = 0;
        var fits = true;
        for i in first..int_end {
            let d = (s[i] - '0') as u64;
            if v > (0xffffffffffffffff - d) / 10 { fits = false; break; }
            v = v * 10 + d;
        }
        if fits && !neg && v <= 0x7fffffffffffffff { return NUM_INT, v, p; }
        if fits && !neg { return NUM_UINT, v, p; }
        if fits && neg && v <= 0x8000000000000000 { return NUM_INT, 0 - v, p; }
    }
    return NUM_FLOAT, float_bits(s, at, p, neg, m, exp10, ndigits, frac_digits), p;
}

// The bits of the double nearest the number s[from..to], which has been
// checked against the grammar: m holds its digits (mod 2^64) and the value
// is m * 10^exp10 when there are no more than 19 of them; frac_digits of
// them follow the point.
fn float_bits(s: const u8[:], from: i64, to: i64, neg: bool, m0: u64, exp0: i64, ndigits: i64,
              frac_digits: i64) -> u64 {
    let sign: u64 = if neg { 0x8000000000000000 } else { 0 };
    var m = m0;
    var exp10 = exp0;
    var many = false;
    if ndigits > 19 {
        // Leading zeros do not count; past 19 significant digits, keep the
        // first 19 and note that some were dropped.
        m = 0;
        var sig = 0;
        var adj: i64 = 0;
        var in_frac = false;
        var p = if s[from] == '-' { from + 1 } else { from };
        while p < to {
            let c = s[p];
            if c == '.' { in_frac = true; p += 1; continue; }
            if c == 'e' || c == 'E' { break; }
            let d = (c - '0') as u64;
            if sig < 19 {
                if sig > 0 || d != 0 { m = m * 10 + d; sig += 1; }
                if in_frac { adj -= 1; }
            } else {
                many = true;
                if !in_frac { adj += 1; }
            }
            p += 1;
        }
        exp10 = exp0 + frac_digits + adj;
    }
    if m == 0 { return sign; }
    // Clinger: both m and 10^|exp10| exact, so one rounding.
    if !many && exp10 >= -22 && exp10 <= 22 && m <= 9007199254740992 {
        var x = m as f64;
        if exp10 < 0 { x = x / POW10_F64[-exp10]; } else { x = x * POW10_F64[exp10]; }
        return bits_of(x) | sign;
    }
    let b1, ok1 = eisel_lemire(m, exp10);
    if ok1 {
        if !many { return b1 | sign; }
        // Dropped digits: m and m + 1 bracket the value.
        let b2, ok2 = eisel_lemire(m + 1, exp10);
        if ok2 && b1 == b2 { return b1 | sign; }
    }
    return slow_float_bits(s, from, to) | sign;
}

// The bits of the double nearest w * 10^q, or false where the 128-bit
// product cannot decide the rounding.
fn eisel_lemire(w0: u64, q: i64) -> u64, bool {
    if q < -342 { return 0, true; }
    if q > 308 { return 0x7ff0000000000000, true; }
    let lz = clz64(w0);
    let w = w0 << lz;
    let idx = q + 342;
    var hi, lo = mul128(w, POW5_HI[idx]);
    if hi & 0x1ff == 0x1ff {
        let h2, l2 = mul128(w, POW5_LO[idx]);
        lo = lo + h2;
        if h2 > lo { hi += 1; }
        if hi & 0x1ff == 0x1ff && lo == 0xffffffffffffffff && (q < -27 || q > 55) { return 0, false; }
    }
    let upper = (hi >> 63) as i64;
    let shift = upper + 9;
    var mant = hi >> shift;
    var p2 = (((152170 + 65536) * q) >> 16) + 63 + upper - lz + 1023;
    if p2 <= 0 {
        if -p2 + 1 >= 64 { return 0, true; }
        mant = mant >> (-p2 + 1);
        mant += mant & 1;
        mant = mant >> 1;
        p2 = if mant < (1 << 52) { 0 } else { 1 };
        return (p2 as u64 << 52) | (mant & 0xfffffffffffff), true;
    }
    // Exactly halfway between two doubles: round to even.
    if lo <= 1 && q >= -4 && q <= 23 && (mant & 3) == 1 && (mant << shift) == hi {
        mant = mant & ~1;
    }
    mant += mant & 1;
    mant = mant >> 1;
    if mant >= (2 << 52) {
        mant = 1 << 52;
        p2 += 1;
    }
    if p2 >= 0x7ff { return 0x7ff0000000000000, true; }
    return (p2 as u64 << 52) | (mant & 0xfffffffffffff), true;
}

// --- exact decimal fallback -------------------------------------------------------
//
// The number as up to 800 decimal digits and a decimal point, scaled by
// powers of two until it lies in [1/2, 1), then rounded (Go's strconv,
// decimal.go). Slow, and reached only by inputs that need it.

let DEC_MAX = 800;
var dec_d: u8[800];          // digit values, most significant first
var dec_nd: i64 = 0;
var dec_dp: i64 = 0;         // the value is 0.d[0..nd] * 10^dp
var dec_trunc = false;       // nonzero digits were dropped past DEC_MAX

fn dec_trim() {
    while dec_nd > 0 && dec_d[dec_nd - 1] == 0 { dec_nd -= 1; }
    if dec_nd == 0 { dec_dp = 0; }
}

fn dec_read(s: const u8[:], from: i64, to: i64) {
    dec_nd = 0;
    dec_dp = 0;
    dec_trunc = false;
    var seen_dot = false;
    var p = from;
    if s[p] == '-' { p += 1; }
    while p < to {
        let c = s[p];
        if c == '.' { seen_dot = true; dec_dp = dec_nd; p += 1; continue; }
        if c == 'e' || c == 'E' { break; }
        if c == '0' && dec_nd == 0 {
            if seen_dot { dec_dp -= 1; }
            p += 1;
            continue;
        }
        if dec_nd < DEC_MAX { dec_d[dec_nd] = c - '0'; dec_nd += 1; }
        else if c != '0' { dec_trunc = true; }
        p += 1;
    }
    if !seen_dot { dec_dp = dec_nd; }
    if p < to {
        p += 1;
        var eneg = false;
        if s[p] == '-' || s[p] == '+' { eneg = s[p] == '-'; p += 1; }
        var e: i64 = 0;
        while p < to { if e < 10000 { e = e * 10 + (s[p] - '0'); } p += 1; }
        dec_dp += if eneg { -e } else { e };
    }
    dec_trim();
}

fn dec_rshift(k: i64) {
    var r = 0;
    var w = 0;
    var n: u64 = 0;
    loop {
        if n >> k != 0 { break; }
        if r >= dec_nd {
            if n == 0 { dec_nd = 0; return; }
            while n >> k == 0 { n = n * 10; r += 1; }
            break;
        }
        n = n * 10 + dec_d[r];
        r += 1;
    }
    dec_dp -= r - 1;
    let mask: u64 = (1 << k) - 1;
    while r < dec_nd {
        let c = dec_d[r];
        let dig = n >> k;
        n = n & mask;
        dec_d[w] = dig as u8;
        w += 1;
        n = n * 10 + c;
        r += 1;
    }
    while n > 0 {
        let dig = n >> k;
        n = n & mask;
        if w < DEC_MAX { dec_d[w] = dig as u8; w += 1; } else if dig > 0 { dec_trunc = true; }
        n = n * 10;
    }
    dec_nd = w;
    dec_trim();
}

fn dec_lshift(k: i64) {
    var tmp = default<u8[830]>();
    var t = 0;
    var n: u64 = 0;
    var r = dec_nd - 1;
    while r >= 0 {
        n += (dec_d[r] as u64) << k;
        tmp[t] = (n % 10) as u8;
        t += 1;
        n = n / 10;
        r -= 1;
    }
    while n > 0 {
        tmp[t] = (n % 10) as u8;
        t += 1;
        n = n / 10;
    }
    let delta = t - dec_nd;
    let keep = min(t, DEC_MAX);
    for j in keep { dec_d[j] = tmp[t - 1 - j]; }
    for j in keep..t { if tmp[t - 1 - j] != 0 { dec_trunc = true; } }
    dec_nd = keep;
    dec_dp += delta;
    dec_trim();
}

fn dec_shift(k0: i64) {
    var k = k0;
    if dec_nd == 0 { return; }
    while k > 60 { dec_lshift(60); k -= 60; }
    while k < -60 { dec_rshift(60); k += 60; }
    if k > 0 { dec_lshift(k); } else if k < 0 { dec_rshift(-k); }
}

fn dec_round_up(nd: i64) -> bool {
    if dec_d[nd] == 5 && nd + 1 == dec_nd {
        if dec_trunc { return true; }
        return nd > 0 && dec_d[nd - 1] % 2 == 1;
    }
    return dec_d[nd] >= 5;
}

fn dec_rounded() -> u64 {
    if dec_dp > 20 { return 0xffffffffffffffff; }
    var n: u64 = 0;
    var i = 0;
    while i < dec_dp && i < dec_nd { n = n * 10 + dec_d[i]; i += 1; }
    while i < dec_dp { n = n * 10; i += 1; }
    if i < dec_nd && dec_round_up(dec_dp) { n += 1; }
    return n;
}

const POWTAB: i64[9] = [1, 3, 6, 9, 13, 16, 19, 23, 26];

// The bits of the positive double nearest the number s[from..to].
fn slow_float_bits(s: const u8[:], from: i64, to: i64) -> u64 {
    dec_read(s, from, to);
    if dec_nd == 0 { return 0; }
    if dec_dp > 310 { return 0x7ff0000000000000; }
    if dec_dp < -330 { return 0; }
    var exp = 0;
    while dec_dp > 0 {
        let n = if dec_dp >= 9 { 27 } else { POWTAB[dec_dp] };
        dec_shift(-n);
        exp += n;
    }
    while dec_dp < 0 || (dec_dp == 0 && dec_d[0] < 5) {
        let n = if -dec_dp >= 9 { 27 } else { POWTAB[-dec_dp] };
        dec_shift(n);
        exp -= n;
    }
    exp -= 1;
    if exp < -1022 {
        let n = -1022 - exp;
        dec_shift(-n);
        exp += n;
    }
    if exp + 1023 >= 0x7ff { return 0x7ff0000000000000; }
    dec_shift(53);
    var mant = dec_rounded();
    if mant == 2 << 52 {
        mant = mant >> 1;
        exp += 1;
        if exp + 1023 >= 0x7ff { return 0x7ff0000000000000; }
    }
    if mant & (1 << 52) == 0 { exp = -1023; }
    return (mant & 0xfffffffffffff) | ((((exp + 1023) as u64) & 0x7ff) << 52);
}

// --- the public readers ------------------------------------------------------------

// The double a whole string holds, in JSON's number grammar.
fn parse_float(s: const u8[:]) -> f64, bool {
    let kind, bits, end = scan_number(s, 0);
    if kind == NUM_BAD || end != s.len { return 0.0, false; }
    if kind == NUM_INT { return bits as! i64, true; }
    if kind == NUM_UINT { return bits, true; }
    return f64_of(bits), true;
}
