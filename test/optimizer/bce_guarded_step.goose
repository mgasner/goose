// A counter that also takes a larger, guarded step keeps its invariants
// (§10.5): `i + 2 <= n` holds before `i += 2`, so `i <= len` survives it,
// and every loop over the counter, before the step as well as after it,
// keeps its proof. The guard compares without wrapping only because `i` is
// already bounded, which is the invariant being inferred: it is assumed
// while each write is checked, and granted once every write preserves it.
import std;

// One cursor over a line, as a request parser steps over a CRLF.
fn crlf(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    while i < n {
        let c = s[i]; // bce:elide
        if c == 32 { break; }
        i++;
    }
    loop {
        if i + 2 > n { return -1; }
        if s[i] == 13 { i += 2; break; } // bce:elide
        i++;
    }
    return i;
}

// A second counter starting where the first stopped.
fn second(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    while i < n {
        let c = s[i]; // bce:elide
        if c == 32 { break; }
        i++;
    }
    var j = i;
    loop {
        if j + 2 > n { return -1; }
        if s[j] == 13 { j += 2; break; } // bce:elide
        j++;
    }
    return j;
}

// The other spellings of the same guard.
fn forms(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    var t = 0;
    loop {
        if n - i < 2 { break; }
        t += s[i]; // bce:elide
        i += 2;
    }
    var j = 0;
    loop {
        if j + 1 >= n { break; }
        t += s[j + 1]; // bce:elide
        j += 2;
    }
    var k = 0;
    loop {
        if k >= n - 1 { break; }
        t += s[k]; // bce:elide
        k += 2;
    }
    return t + i + j + k;
}

// A step of 3 behind a guard of 3, and a decrement by 2 behind its guard.
fn wide(s: const u8[:]) -> i64 {
    var i = 0;
    var t = 0;
    while i < s.len {
        t += s[i]; // bce:elide
        if i + 3 > s.len { break; }
        i += 3;
    }
    var k = s.len;
    while k > 0 {
        t += s[k - 1]; // bce:elide
        if k < 2 { break; }
        k -= 2;
    }
    return t;
}

// Negative: a guard one short of the step bounds the counter by n + 1 only.
fn short(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    loop {
        if i + 1 > n { return -1; }
        // `i <= len` is not an invariant here, so nothing bounds `i + 1`
        // against wrapping, and the guard proves nothing either.
        if s[i] == 13 { i += 2; break; } // bce:keep
        i++;
    }
    if i > n { return -2; }
    return s[i - 1]; // bce:keep
}

// Negative: an unguarded step can leave the counter past the end.
fn unguarded(s: const u8[:]) -> i64 {
    let n = s.len;
    var i = 0;
    while i < n {
        if s[i] == 13 { i += 2; } else { i++; } // bce:elide
    }
    let head = s[..i]; // bce:keep
    return head.len;
}

// Negative: a guard on a value nothing bounds may have wrapped.
recursive fn unbounded(s: const u8[:], k: i64) -> i64 {
    if k < 0 { return -1; }
    var i = k;
    if i + 2 > s.len { return -1; }
    return s[i]; // bce:keep
}

fn main() {
    let ks: i64[2] = [3, 4];
    let s = "GET / HTTP/1.1\r\nHost: x\r\n";
    print(crlf(s));
    print(second(s));
    print(forms(s));
    print(wide(s));
    print(short(s));
    print(short("ab"));
    print(unguarded("abc"));
    print(unbounded(s, ks[s.len % 2]));
}
