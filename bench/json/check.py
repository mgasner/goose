#!/usr/bin/env python3
"""Correctness checks for the json module beyond the test fixture
(docs/design/json.md, sections 5 and 12).

1. Doubles: writes several million cases from Python's correctly rounded
   repr() and float() -- random bit patterns, subnormals and extremes,
   decimals of up to 40 digits at every exponent, and the exact midpoints
   between adjacent doubles, nudged by one unit in a late digit -- and
   checks json::write_float and json::parse_float on every one
   (numcheck.goose).
2. Round trip: parses each corpus file and writes it back compactly
   (roundtrip.goose), and compares the bytes with a Python serializer that
   writes doubles the way JavaScript does.

  python bench/json/check.py              # 200000 cases of each kind, seed 1
  python bench/json/check.py --n 1000000 --seed 7
"""

import argparse
import json
import random
import struct
import sys
from decimal import Decimal, getcontext
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import toolchain as tc

HERE = Path(__file__).resolve().parent
GEN = HERE.parent / "gen" / "json"
CORPUS = ["twitter.json", "citm_catalog.json", "canada.json"]

getcontext().prec = 1200


def bits(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def flt(b):
    return struct.unpack("<d", struct.pack("<Q", b))[0]


def js(x):
    """A double as JavaScript's Number.prototype.toString writes it."""
    if x == 0:
        return "-0" if str(x).startswith("-") else "0"
    s = repr(abs(x))
    m, e = (s.split("e")[0], int(s.split("e")[1])) if "e" in s else (s, 0)
    ip, fp = m.split(".") if "." in m else (m, "")
    if fp == "0":
        fp = ""
    digits = (ip + fp).lstrip("0")
    lead = len(ip + fp) - len(digits)
    n = len(ip) + e - lead              # the value is 0.digits * 10^n
    digits = digits.rstrip("0")
    k = len(digits)
    if k <= n <= 21:
        out = digits + "0" * (n - k)
    elif 0 < n <= 21:
        out = digits[:n] + "." + digits[n:]
    elif -6 < n <= 0:
        out = "0." + "0" * -n + digits
    else:
        out = digits[0] + ("." + digits[1:] if k > 1 else "") + "e" + ("-" if n - 1 < 0 else "+") + str(abs(n - 1))
    return ("-" if x < 0 else "") + out


def cases(n, seed):
    rnd = random.Random(seed)
    out = []
    for x in [0.0, -0.0, 5e-324, 1e-323, 2.2250738585072014e-308, 2.225073858507201e-308,
              1.7976931348623157e308, 1.0, 0.1, 0.2, 0.3, 1e21, 1e22, 1e23, 9007199254740992.0,
              9007199254740993.0, 1e-7, 1e-6, 123456789012345680000.0]:
        out.append(f"W {bits(x):016x} {js(x)}")
    for _ in range(n):
        r = rnd.random()
        if r < 0.5:
            b = rnd.getrandbits(64)
        elif r < 0.7:
            b = rnd.getrandbits(52) | (rnd.choice([0, 1, 2, 1022, 1023, 1024, 1075, 2046]) << 52)
        else:
            b = bits(round(rnd.uniform(-1000, 1000), rnd.randint(0, 6)))
        if (b >> 52) & 0x7ff == 0x7ff:
            continue
        x = flt(b)
        out.append(f"W {b:016x} {js(x)}")
        out.append(f"R {repr(x)} {b:016x}")
    for _ in range(n):
        r = rnd.random()
        if r < 0.4:
            nd = rnd.randint(1, 40)
            d = str(rnd.randint(1, 9)) + "".join(rnd.choice("0123456789") for _ in range(nd - 1))
            t = d[0] + ("." + d[1:] if nd > 1 else "") + "e" + str(rnd.randint(-340, 310))
        elif r < 0.8:
            # The exact midpoint between a double and the next one, as is,
            # or one unit past it in a late digit, or cut short.
            b = rnd.getrandbits(63) % (0x7ff << 52)
            mid = (Decimal(flt(b)) + Decimal(flt(b + 1))) / 2
            m, e = format(mid, "E").split("E")
            q = rnd.random()
            if q < 0.33:
                m = m + "0000000000001"
            elif q < 0.66:
                m = m.rstrip("0").rstrip(".")
            t = m + "e" + str(int(e))
        else:
            x = rnd.uniform(-1e6, 1e6)
            t = "%.*f" % (rnd.randint(0, 25), x)
            neg = t.startswith("-")
            t = t.lstrip("-").lstrip("0") or "0"
            if t.startswith("."):
                t = "0" + t
            if t.endswith("."):
                t += "0"
            t = ("-" if neg else "") + t
        x = float(t)
        out.append(f"R {t} {bits(x):016x}")
    return out


class Obj(list):
    """An object's members in order, duplicates kept."""


def reference(v, out):
    if v is None:
        out.append("null")
    elif v is True or v is False:
        out.append("true" if v else "false")
    elif isinstance(v, int):
        out.append(str(v))
    elif isinstance(v, float):
        out.append(js(v))
    elif isinstance(v, str):
        out.append(json.dumps(v, ensure_ascii=False))
    elif isinstance(v, list) and not isinstance(v, Obj):
        out.append("[")
        for i, x in enumerate(v):
            if i:
                out.append(",")
            reference(x, out)
        out.append("]")
    else:
        out.append("{")
        for i, (k, x) in enumerate(v):
            if i:
                out.append(",")
            out.append(json.dumps(k, ensure_ascii=False) + ":")
            reference(x, out)
        out.append("}")


def build(goose, cc, name):
    exe = GEN / f"{name}{tc.EXE_SUFFIX}"
    cfile = GEN / f"{name}.c"
    code, out, err = tc.run_capture([goose, "-O2", "--standalone", "-o", cfile, HERE / f"{name}.goose"])
    if code != 0:
        sys.exit(f"goose failed on {name}.goose:\n{out}{err}")
    ok, msg = cc.compile(cfile, exe, opt=2)
    if not ok:
        sys.exit(f"{cc.name} failed on {name}:\n{msg}")
    return exe


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", help="the goose compiler")
    ap.add_argument("--cc", help="C toolchain name (default: clang if present)")
    ap.add_argument("--n", type=int, default=200000, help="cases of each kind (default 200000)")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    tc.setup_console()
    goose = tc.find_goose(args.exe)
    ccs = tc.find_ccs()
    if not ccs:
        sys.exit("no C toolchain found")
    cc = ccs[args.cc or ("clang" if "clang" in ccs else next(iter(ccs)))]
    GEN.mkdir(parents=True, exist_ok=True)
    numcheck = build(goose, cc, "numcheck")
    roundtrip = build(goose, cc, "roundtrip")

    path = GEN / "num_cases.txt"
    tc.write_text(path, "\n".join(cases(args.n, args.seed)) + "\n")
    code, out, err = tc.run_capture([numcheck, path])
    print(out.strip())
    failed = code != 0

    for name in CORPUS:
        src = HERE / "data" / name
        got = GEN / f"{name}.out"
        code, out, err = tc.run_capture([roundtrip, src, got])
        parts = []
        reference(json.loads(src.read_text(encoding="utf-8"), object_pairs_hook=Obj), parts)
        same = code == 0 and got.read_bytes() == "".join(parts).encode("utf-8")
        print(f"{name}: written back {'identical to' if same else 'DIFFERENT from'} the reference")
        failed |= not same
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
