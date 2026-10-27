// The Goose standard library: `ffi` (docs/stdlib.md): reading memory a C
// library owns, handed back as a `u64` pointer by an extern bound from a
// shared library (spec §7.10, docs/reference.md §24). Each function copies
// into a builder the caller passes, so nothing foreign is ever a Goose
// value without a copy, and each trusts the pointer as every extern call
// trusts C: a wrong pointer or length is C's kind of error, not Goose's.
namespace ffi;

// The bytes at p up to its NUL, the NUL left out: a C string. Appends
// nothing and returns false for a null p.
extern fn cstr(p: u64, out: u8[>..]&) -> bool = "gs_ffi_cstr";
// The n bytes at p. Appends nothing and returns false for a null p.
extern fn bytes(p: u64, n: i64, out: u8[>..]&) -> bool = "gs_ffi_bytes";

// Whether the library an `extern? "lib" { ... }` block names was bound as
// the program started (§7.10): a block whose library may be missing leaves
// its functions unbound where it is, and calling one is a runtime error.
// False as well for a library nothing the program calls is bound from,
// which is never opened.
extern fn available(lib: const u8[:]) -> bool = "gs_ffi_available";
// Why a library is not bound: appends the reason and returns true where it
// is not, appends nothing and returns false where it is.
extern fn unavailable(lib: const u8[:], out: u8[>..]&) -> bool = "gs_ffi_unavailable";

// The fresh-string forms: empty for a null p.
fn cstr(p: u64) -> u8[>..] {
    var out: u8[>..] = [];
    cstr(p, out);
    return out;
}
fn bytes(p: u64, n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    bytes(p, n, out);
    return out;
}
