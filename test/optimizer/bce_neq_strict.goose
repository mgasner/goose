// `i != n` bounds nothing alone, but with `i <= n` already proven it is
// `i < n` (§10.5): the scan-then-look-at-the-stopping-byte idiom needs no
// `>=` spelled in place of `==`.
import std;

fn stop(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    while i < n {
        let c = s[i]; // bce:elide
        if c == 32 { break; }
        i++;
    }
    if i == n { return -1; }
    return s[i]; // bce:elide
}

// The same with the operands swapped, and as a loop condition.
fn swapped(s: const u8[:]) -> i64 {
    var i = 0;
    while i < s.len && s[i] != 32 { i++; } // bce:elide
    if s.len == i { return -1; }
    return s[i]; // bce:elide
}
fn from_end(s: const u8[:]) -> i64 {
    var i = s.len;
    var t = 0;
    while i != 0 {
        i--;
        t += s[i]; // bce:elide
    }
    return t;
}

// Negative: nothing bounds k by the length, so `k != len` says nothing.
recursive fn unbounded(s: const u8[:], k: i64) -> i64 {
    if k < 0 || k == s.len { return -1; }
    return s[k]; // bce:keep
}

// Negative: `i <= n + 1` and `i != n` still allow `i == n + 1`.
fn off_by_one(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    while i < n {
        if s[i] == 13 { i += 2; } else { i++; } // bce:elide
    }
    if i == n { return -1; }
    return s[i - 1]; // bce:keep
}

fn main() {
    let s = "GET / HTTP/1.1";
    print(stop(s));
    print(stop("GET"));
    print(swapped(s));
    print(from_end("ab"));
    let ks: i64[2] = [1, 3];
    print(unbounded(s, ks[0]));
    print(off_by_one("ab"));
}
