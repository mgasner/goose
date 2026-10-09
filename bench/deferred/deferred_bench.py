#!/usr/bin/env python3
"""Deferred-call benchmarks (bench/deferred/README.md).

Two suites, each program timing itself in-process and printing a checksum or
its first response, which must agree across every implementation:

  calls    n stored calls of four kinds built into an array, then run
           `passes` times: Goose deferred calls, the same as a hand-written
           Goose enum (with and without the empty arm a deferred type has),
           C++ std::function / virtual / std::variant, Rust Box<dyn Fn> / enum.
  graphql  one GraphQL request whose fields need rows from a backend that
           charges per call: Goose's library naive, with the batch hook, and
           with deferred values (r.later); graphql-js naive and with
           DataLoader, installed from the pinned package.json into
           bench/gen/deferred/node.

  python bench/deferred/deferred_bench.py                 # everything
  python bench/deferred/deferred_bench.py --only calls    # or graphql
  python bench/deferred/deferred_bench.py --quick         # fewer, shorter runs
  python bench/deferred/deferred_bench.py --no-node       # no graphql-js rows
  python bench/deferred/deferred_bench.py --report-only   # re-render results.json
"""

import argparse
import json
import platform
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import toolchain as tc

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GEN = ROOT / "bench" / "gen" / "deferred"
NODEDIR = GEN / "node"

# name, kind, source, mode argument
CALLS = [
    ("Goose deferred calls", "goose", "calls_deferred.goose", None),
    ("Goose enum + case functions", "goose", "calls_enum.goose", None),
    ("Goose enum + an aborting empty arm", "goose", "calls_enum_empty.goose", None),
    ("C++ std::function", "cpp", "calls.cpp", "function"),
    ("C++ virtual + unique_ptr", "cpp", "calls.cpp", "virtual"),
    ("C++ std::variant + visit", "cpp", "calls.cpp", "variant"),
    ("Rust Box<dyn Fn>", "rust", "calls.rs", "boxed"),
    ("Rust enum + match", "rust", "calls.rs", "enum"),
]
# (n, passes): every size makes 10^8 calls.
CALL_SIZES = [(1_000, 100_000), (100_000, 1_000), (10_000_000, 10)]
QUICK_CALL_SIZES = [(1_000, 10_000), (100_000, 100), (1_000_000, 10)]

GRAPHQL = [
    ("Goose naive", "goose", "naive"),
    ("Goose batch hook", "goose", "batch"),
    ("Goose r.later (deferred values)", "goose", "later"),
    ("graphql-js naive", "node", "naive"),
    ("graphql-js + DataLoader", "node", "dataloader"),
]
BOOKS = [10, 100, 1000]
CALL_NS = [0, 20_000]


def reps_for(kind, books, call_ns, quick):
    """Requests per timed run: about half a second of work each."""
    base = {10: 20_000, 100: 2_000, 1000: 200}[books]
    if call_ns:
        base = {10: 1_000, 100: 200, 1000: 20}[books]
    if kind == "node":
        base = max(5, base // 20)
    if quick:
        base = max(3, base // 10)
    return base


class Builder:
    def __init__(self):
        self.goose = tc.find_goose(None)
        ccs = tc.find_ccs()
        self.cc = ccs.get("clang") or next(iter(ccs.values()), None)
        self.rustc = tc.find_rustc()
        self.node = shutil.which("node")
        GEN.mkdir(parents=True, exist_ok=True)

    def goose_exe(self, src):
        c = GEN / (Path(src).stem + ".c")
        exe = GEN / (Path(src).stem + tc.EXE_SUFFIX)
        r = subprocess.run([str(self.goose), "--standalone", "-O2", "-o", str(c), str(HERE / "goose" / src)],
                           capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"goose failed on {src}:\n{r.stdout}{r.stderr}")
        ok, out = self.cc.compile(c, exe, opt=2)
        if not ok:
            sys.exit(f"C build failed for {src}:\n{out}")
        return [str(exe)]

    def cpp_exe(self, src):
        exe = GEN / (Path(src).stem + "_cpp" + tc.EXE_SUFFIX)
        ok, out = self.cc.compile(HERE / "baselines" / src, exe, opt=2, cpp=True, extra=("-std=c++17",))
        return [str(exe)] if ok else None

    def rust_exe(self, src):
        if not self.rustc:
            return None
        exe = GEN / (Path(src).stem + "_rs" + tc.EXE_SUFFIX)
        code, out, err = tc.run_capture([str(self.rustc), "-O", "-C", "codegen-units=1", "-o", str(exe),
                                         str(HERE / "baselines" / src)])
        return [str(exe)] if code == 0 else None

    def node_cmd(self):
        if not self.node:
            return None
        NODEDIR.mkdir(parents=True, exist_ok=True)
        for f in ("package.json", "graphql_loader.mjs"):
            shutil.copy(HERE / "baselines" / f, NODEDIR / f)
        if not (NODEDIR / "node_modules" / "dataloader").exists():
            npm = shutil.which("npm")
            r = subprocess.run([npm, "install", "--no-audit", "--no-fund"], cwd=NODEDIR,
                               capture_output=True, text=True)
            if r.returncode:
                print(f"npm install failed; no graphql-js rows:\n{r.stderr}")
                return None
        return [self.node, str(NODEDIR / "graphql_loader.mjs")]


def run(cmd, args):
    r = tc.run_measured(cmd[0], list(cmd[1:]) + [str(a) for a in args])
    if r.code != 0:
        raise RuntimeError(f"{' '.join(cmd)} {args} exited {r.code}: {r.err}")
    return r


def bench_calls(b, quick, reps):
    sizes = QUICK_CALL_SIZES if quick else CALL_SIZES
    built = {}
    rows = []
    for name, kind, src, mode in CALLS:
        key = (kind, src)
        if key not in built:
            built[key] = {"goose": b.goose_exe, "cpp": b.cpp_exe, "rust": b.rust_exe}[kind](src)
        cmd = built[key]
        if not cmd:
            print(f"  skip {name}: no toolchain")
            continue
        row = {"name": name, "kind": kind, "sizes": []}
        for n, passes in sizes:
            args = ([mode] if mode else []) + [n, passes]
            builds, runs, peak, check, size = [], [], 0, None, None
            for _ in range(reps):
                r = run(cmd, args)
                bns, rns, ck, nb = r.out.split()
                builds.append(int(bns))
                runs.append(int(rns))
                peak = max(peak, r.peak)
                check, size = ck, int(nb)
            row["sizes"].append({"n": n, "passes": passes, "build_ns_per": min(builds) / n,
                                 "run_ns_per": min(runs) / (n * passes),
                                 "bytes": size, "peak": peak, "checksum": check})
            print(f"  {name:38} n={n:>10,}  run {row['sizes'][-1]['run_ns_per']:6.2f} ns/call  "
                  f"build {row['sizes'][-1]['build_ns_per']:6.2f} ns/call  {size:>3} B  "
                  f"{peak / (1 << 20):8.1f} MB")
        rows.append(row)
    # Every implementation computes the same thing.
    for i in range(len(sizes)):
        cks = {r["sizes"][i]["checksum"] for r in rows}
        if len(cks) != 1:
            sys.exit(f"checksums differ at size {sizes[i]}: {cks}")
    return rows


def bench_graphql(b, quick, reps, use_node):
    goose = b.goose_exe("graphql_loader.goose")
    node = b.node_cmd() if use_node else None
    rows = []
    first = {}
    for name, kind, mode in GRAPHQL:
        cmd = goose if kind == "goose" else node
        if not cmd:
            print(f"  skip {name}: no node")
            continue
        row = {"name": name, "kind": kind, "points": []}
        for books in BOOKS:
            for call_ns in CALL_NS:
                n = reps_for(kind, books, call_ns, quick)
                times, calls = [], None
                for _ in range(reps):
                    r = run(cmd, [mode, books, call_ns, n])
                    lines = r.out.splitlines()
                    resp, stats = lines[0], lines[-1].split()
                    if first.setdefault(books, resp) != resp:
                        sys.exit(f"{name} gives a different response for {books} books")
                    times.append(int(stats[0]))
                    calls = int(stats[1])
                row["points"].append({"books": books, "call_ns": call_ns,
                                      "us": min(times) / 1000, "calls": calls})
                print(f"  {name:32} books={books:>5} call={call_ns // 1000:>3} us  "
                      f"{row['points'][-1]['us']:10.1f} us/request  {calls:>4} calls")
        rows.append(row)
    return rows


def fmt(v, places=2):
    return f"{v:,.{places}f}"


def report(res):
    out = []
    W = out.append
    W("# Deferred calls: benchmark results")
    W("")
    W("Generated by `bench/deferred/deferred_bench.py`; what each program does and why is in "
      f"[README.md](README.md). Times are the best of {res.get('reps', 5)} runs, measured in-process.")
    W("")
    W(f"Machine: {res['machine']}. C/C++: {res['cc']}. Rust: {res['rust']}. Node: {res['node']}. "
      f"Measured {res['date']}.")
    if "calls" in res:
        rows = res["calls"]
        sizes = rows[0]["sizes"]
        W("")
        W("## Stored calls")
        W("")
        W("Running: nanoseconds per call, each size making 10^8 calls. Kinds are random, so the "
          "small sizes repeat a pattern the branch predictor learns and the largest does not.")
        W("")
        W("| implementation | " + " | ".join(f"n = {s['n']:,}" for s in sizes) + " |")
        W("|---|" + "---:|" * len(sizes))
        for r in rows:
            W(f"| {r['name']} | " + " | ".join(fmt(s["run_ns_per"]) for s in r["sizes"]) + " |")
        W("")
        W(f"Building, bytes per stored call and peak memory at n = {sizes[-1]['n']:,}:")
        W("")
        W("| implementation | build ns/call | bytes/call | peak MB |")
        W("|---|---:|---:|---:|")
        for r in rows:
            s = r["sizes"][-1]
            W(f"| {r['name']} | {fmt(s['build_ns_per'])} | {s['bytes']} | {fmt(s['peak'] / (1 << 20), 1)} |")
    if "graphql" in res:
        rows = res["graphql"]
        W("")
        W("## GraphQL loading")
        W("")
        W("Microseconds per request for `{ books { title authorName authorCountry } }`, and backend "
          "calls per request. Each request is parsed, validated, executed and written as JSON. "
          "The backend costs nothing, or 20 µs per call.")
        pts = rows[0]["points"]
        for call_ns in sorted({p["call_ns"] for p in pts}):
            W("")
            W(f"Backend call: {call_ns // 1000} µs")
            W("")
            books = [p["books"] for p in pts if p["call_ns"] == call_ns]
            W("| implementation | " + " | ".join(f"{b:,} books" for b in books) + " | calls at "
              f"{books[-1]:,} |")
            W("|---|" + "---:|" * (len(books) + 1))
            for r in rows:
                ps = [p for p in r["points"] if p["call_ns"] == call_ns]
                W(f"| {r['name']} | " + " | ".join(fmt(p["us"], 1) for p in ps) +
                  f" | {ps[-1]['calls']} |")
    (HERE / "results.md").write_text("\n".join(out) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=("calls", "graphql"))
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--no-node", action="store_true")
    ap.add_argument("--reps", type=int, default=0)
    ap.add_argument("--report-only", action="store_true")
    args = ap.parse_args()
    jpath = HERE / "results.json"
    if args.report_only:
        report(json.loads(jpath.read_text()))
        return
    b = Builder()
    reps = args.reps or (3 if args.quick else 5)
    rustv = tc.run_capture([str(b.rustc), "--version"])[1].strip() if b.rustc else "none"
    nodev = tc.run_capture([b.node, "--version"])[1].strip() if b.node and not args.no_node else "none"
    res = {"machine": f"{platform.machine()} {platform.system()} {platform.release()}",
           "cc": b.cc.desc if b.cc else "none", "rust": rustv, "node": nodev,
           "date": datetime.now().strftime("%Y-%m-%d %H:%M"), "reps": reps}
    if args.only in (None, "calls"):
        print("stored calls")
        res["calls"] = bench_calls(b, args.quick, reps)
    if args.only in (None, "graphql"):
        print("graphql loading")
        res["graphql"] = bench_graphql(b, args.quick, reps, not args.no_node)
    if not args.quick:
        jpath.write_text(json.dumps(res, indent=1) + "\n")
    report(res)


if __name__ == "__main__":
    main()
