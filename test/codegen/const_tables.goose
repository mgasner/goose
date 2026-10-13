// A `let` global of a const type with a compile-time initializer is
// read-only static data (§1.2, §9.5), `const` in the C as well, so the C
// compiler may fold a lookup at a constant index and keep the table in a
// read-only section. Slices, references and loops over it still read it.
// c-has: ^static const a4_u8 TABLE_g = \{ \{ 1, 0, 7, 0 \} \};
// c-has: ^static const int64_t LIMIT_g = 5;
// c-has: ^static const Pt_g ORIGIN_g = 
// c-has: ^static const a3_u8 SMALL_g = 
// c-lacks: ^static a4_u8 TABLE_g
import std;

let TABLE: const u8[4] = [1, 0, 7, 0];
let LIMIT: const i64 = 5;
const SMALL: u8[3] = [9, 8, 7];
struct Pt { x: i64, y: i64 }
let ORIGIN: const Pt = Pt { x: 3, y: 4 };

fn total(s: const u8[:]) -> i64 {
    var t = 0;
    for c in s { t += c; }
    return t;
}
fn first(r: const u8[4]&) -> u8 { return r[0]; }
fn norm1(p: const Pt&) -> i64 { return p.x + p.y; }

fn main() {
    print(TABLE[2], " ", LIMIT, " ", ORIGIN.y);
    print(total(TABLE), " ", total(TABLE[1..]), " ", first(TABLE), " ", norm1(ORIGIN));
    var t = 0;
    for c, i in TABLE { t += c * i; }
    print(t, " ", SMALL[1], " ", total(SMALL));
}
