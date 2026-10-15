#!/usr/bin/env python3
"""The fork's json against upstream's (as ujson), with yyjson for scale.

Builds fork_bench.goose, ujson_bench.goose and the two conformance programs
with `goose -O2 --standalone` and clang -O2 (as bench/json/json_bench.py
does), and yyjson_cmp.c with the same clang; generates the kostya inputs;
checks correctness; then times every task on every input.

  python3 bench/json_compare/compare.py              # everything
  python3 bench/json_compare/compare.py --report-only

Timing: each process does one untimed warmup rep and then `reps` timed ones,
and prints every rep's time. A group (one task) runs `--rounds` rounds; in
each round, each input runs on each library in turn, the order rotating per
round, so drift hits all of them alike. A cell is the median of all its
reps. Before each group the 1-minute load average must fall under
--max-load (polled for up to --wait seconds); the load before and after is
recorded, and a group that started over the limit is marked noisy. Peak RSS
comes from a separate single-rep run of each cell, through wait4.
"""

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import toolchain as tc  # noqa: E402

GEN = ROOT / "bench" / "gen" / "json_compare"
CORPUS = ROOT / "bench" / "json" / "data"
DATA = HERE / "data"
SUITE = ROOT / "bench" / "json" / "third_party" / "JSONTestSuite"
YY = ROOT / "bench" / "json" / "third_party" / "yyjson.c"

KOSTYA = [("kostya_25k.json", 25000), ("kostya_524k.json", 524288)]
INPUTS = [CORPUS / "canada.json", CORPUS / "citm_catalog.json", CORPUS / "twitter.json"] + \
         [DATA / k for k, _ in KOSTYA]
KOSTYA_INPUTS = [DATA / k for k, _ in KOSTYA]

# task -> (libraries that can do it, inputs)
TASKS = {
    "parse": (["fork", "ujson", "yyjson"], INPUTS),
    "kostya_dom": (["fork", "ujson", "yyjson"], KOSTYA_INPUTS),
    "kostya_stream": (["fork", "ujson"], KOSTYA_INPUTS),
    "write": (["fork", "ujson", "yyjson"], INPUTS),
    "write_walk": (["fork"], INPUTS),
}

EXES = {}

SUMMARY = """## Summary

Medians in MB/s of input, at a 1-minute load of 3.5-4.3 for every group
(write and write_walk 2026-10-14 17:00-18:30; parse, kostya_dom and
kostya_stream rerun 19:30-20:10). Per-group load is in the sections below.

| Task | Input | fork | ujson | yyjson | fork / ujson speed |
|---|---|---|---|---|---|
| parse | canada | 1504 | 320 | 2304 | 4.70x |
| parse | citm_catalog | 4594 | 2496 | 5608 | 1.84x |
| parse | twitter | 2526 | 2155 | 5263 | 1.17x |
| parse | kostya 25k | 1491 | 1489 | 2229 | 1.00x |
| parse | kostya 524k | 1469 | 1468 | 2123 | 1.00x |
| kostya_dom | kostya 25k | 1256 | 1388 | 2079 | 0.90x |
| kostya_dom | kostya 524k | 1263 | 1356 | 1990 | 0.93x |
| kostya_stream | kostya 25k | 771 (cursor) | 1868 (Reader) | - | 0.41x |
| kostya_stream | kostya 524k | 769 (cursor) | 1875 (Reader) | - | 0.41x |
| write | canada | 983 | 81 | 2069 | 12.1x |
| write | citm_catalog | 6039 | 8344 | 18980 | 0.72x |
| write | twitter | 4182 | 3451 | 10024 | 1.21x |
| write | kostya 25k | 723 | 1599 | 2774 | 0.45x |
| write | kostya 524k | 717 | 1595 | 2781 | 0.45x |

**Reading**

* **Parse:** level on kostya (short numbers, short strings). The fork leads
  on the standard corpus: 1.2x twitter, 1.8x citm, 4.7x canada. canada's
  16-17 significant digit numbers take ujson off its 2^53 fast path onto its
  big-integer path; the fork uses Eisel-Lemire. Fork is 48-82% of yyjson,
  ujson 14-70%.
* **kostya_dom:** ujson 7-10% faster despite equal parse speed: field access
  on its linked tree is cheaper than the fork's `get`, which scans keys.
* **Streaming:** ujson's single-pass Reader is 2.4x the fork's cursor and
  faster than ujson's own DOM route. The fork's cursor indexes the whole text
  first, so on a read-everything task it is slower than the fork's own DOM.
  The fork has no single-pass pull reader.
* **Write:** ujson's shortest-digit search (try lengths, read back) is ~12x
  slower on canada's doubles (81 vs 983 MB/s). On 8-decimal values and
  strings, ujson's format_* walk is faster (2.2x kostya, 1.4x citm); the fork
  leads on twitter (1.2x). The fork's `write_walk` (same user walk through
  the fork's writer) is 7-14% slower than its built-in `w.value`, so the gap
  is in the writers, not the walk.
* **Memory:** the fork's tape is smaller: kostya 524k peak RSS 176 MB vs
  ujson 244 MB vs yyjson 225 MB (input 50 MB). ujson's Reader adds nothing
  over the input (50 MB); the fork's cursor index takes 128 MB.
* **Correctness:** identical documents on all five inputs (content hash),
  identical kostya averages to the last digit (yyjson too), and each
  library's output re-parses to an equal document in both. JSONTestSuite:
  both 95/95 y_ and 188/188 n_ in both modes; i_ accepted fork 11/35, ujson
  31/35. ujson accepts invalid UTF-8 and lone surrogates (implementation
  defined by the RFC), decoding a lone surrogate escape to three bytes that
  are not valid UTF-8.

**Noise.** The machine is shared and load ranged from 3 to 100 over two days.
A first full run on 2026-10-13 had every group start at a load of 24-100;
those results were discarded. In the second run, parse hit a spike to 25
(interquartile spread 87%) and the kostya groups started at 5-10, so those
three groups were rerun. The final parse group started at 4.1, just over the
strict 4.0 limit, and is marked noisy, but its spread is 3.9%, like the
others. Across final groups the median per-cell spread is 2-4%, max 8.7%.
Some groups and load waits took far longer by the clock than their work,
most likely because the machine slept; timings are per rep and in process,
so that time is not counted.

"""

NOTES = """## What each task runs

The programs are `fork_bench.goose` and `ujson_bench.goose` beside this file
(and `yyjson_cmp.c`); the tasks share names and output.

| Task | fork | ujson | yyjson |
|---|---|---|---|
| parse | `json::parse(text)`: a flat tape of 16-byte entries | `ujson::parse(text, doc, decoded)` into fresh buffers: a linked tree of `Node`s | `yyjson_read` + `yyjson_doc_free` |
| kostya_dom | parse, `root.get("coordinates").each() { c => x += c.get("x").float(); ... }` | parse, `member(root, "coordinates")`, `each(coords) { c => x += as_f64(member(c, "x")) ... }` (bench/kostya's json_parse_dom) | parse, `yyjson_obj_get` per field |
| kostya_stream | `json::cursor(text)` (an index of the whole text), then the same `get`/`each` on lazy values | `ujson::Reader`: `each_member`/`each_element`, `read_number` for x/y/z, `skip` for the rest, `finish` (bench/kostya's json_parse_mapping, summing instead of building an array) | none |
| write | `json::writer(out).value(doc.root())`, the module's document writer | no tree writer in the module: a recursive walk calling `format_string/format_key/format_number/format_int/format_bool` and pushing brackets and commas | `yyjson_write` (minified) |
| write_walk | the same walk as ujson's, through the fork's writer calls (`w.array() {..}`, `w.key`, `w.float`...), to separate library speed from the built-in tape walk | — | — |

Untimed, for correctness: `hash` (a content hash of the whole document,
`common.goose`) and `roundtrip` (write the parsed document to a file).

**API differences that affect comparability**

* The documents differ in kind. The fork's is a flat tape (a container's
  entry holds the index past its end); ujson's is a tree of 4-byte
  self-relative links (`next`, `first`), each node carrying its key. Both
  keep unescaped strings as views of the input. Neither parse is lazy.
* ujson has no document writer, so its `write` row is user code over
  `format_*`. The fork's `write_walk` row is the same user code over the
  fork's writer, for a like-for-like comparison of the writers.
* The streaming tasks are not the same kind of thing. ujson's Reader is a
  single forward pass that parses only what it is asked for and validates
  what it skips. The fork's cursor first builds a structural index of the
  whole text (simdjson-style stage 1) and then reads values on demand; it
  validates only what is read. The fork has no single-pass pull reader.
* Validation differs: the fork checks UTF-8 in strings and rejects lone
  surrogates; ujson checks neither (it decodes a lone surrogate escape to
  its three bytes). This shows in the `i_` results, not in `y_`/`n_`.
* Number output differs in layout only: the fork writes JavaScript's
  layout (`0.00000714`), ujson serde_json's (`7.14e-6`). Both are shortest
  round-trip and re-parse to the same doubles.
* ujson numbers: an integer that fits i64 is `Int`, others `Num`. The fork
  adds `K_UINT` for u64. The content hash compares every number as an f64.

"""


def sh(argv, **kw):
    r = subprocess.run([str(a) for a in argv], capture_output=True, text=True, errors="replace", **kw)
    if r.returncode != 0:
        sys.exit(f"failed: {' '.join(map(str, argv))}\n{r.stdout}{r.stderr}")
    return r.stdout


def build(goose, cc):
    GEN.mkdir(parents=True, exist_ok=True)
    for name in ["fork_bench", "ujson_bench", "conf_fork", "conf_ujson", "gen_kostya"]:
        cfile = GEN / f"{name}.c"
        exe = GEN / name
        sh([goose, "-O2", "--standalone", "-o", cfile, HERE / f"{name}.goose"])
        ok, msg = cc.compile(cfile, exe, opt=2, log=GEN / f"{name}.cc.log")
        if not ok:
            sys.exit(f"cc failed on {name}: {msg}")
        EXES[name] = exe
    exe = GEN / "yyjson_cmp"
    ok, msg = cc.compile([HERE / "yyjson_cmp.c", YY], exe, opt=2, warn="none", log=GEN / "yyjson.cc.log")
    if not ok:
        sys.exit(f"cc failed on yyjson: {msg}")
    EXES["yyjson"] = exe
    EXES["fork"] = EXES["fork_bench"]
    EXES["ujson"] = EXES["ujson_bench"]


def gen_inputs():
    DATA.mkdir(exist_ok=True)
    for name, n in KOSTYA:
        if not (DATA / name).exists():
            sh([EXES["gen_kostya"], n, DATA / name])


def kv(line):
    return dict(f.split("=", 1) for f in line.split())


def run_task(lib, task, path, reps):
    out = subprocess.run([str(EXES[lib]), task, str(path), str(reps)], capture_output=True,
                         text=True, errors="replace")
    if out.returncode != 0:
        sys.exit(f"{lib} {task} {path.name} failed: {out.stdout}{out.stderr}")
    lines = out.stdout.strip().splitlines()
    ns = [int(x) for x in lines[-2][3:].split(",")]
    return ns, kv(lines[-1])


def peak_rss(lib, task, path):
    p = subprocess.Popen([str(EXES[lib]), task, str(path), "1"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    _, status, ru = os.wait4(p.pid, 0)
    p.returncode = 0
    if status != 0:
        sys.exit(f"{lib} {task} {path.name} failed (rss)")
    return ru.ru_maxrss  # bytes on macOS


def load1():
    return os.getloadavg()[0]


def wait_for_load(max_load, wait):
    t0 = time.time()
    while load1() >= max_load and time.time() - t0 < wait:
        time.sleep(15)
    return load1(), time.time() - t0


# --- correctness --------------------------------------------------------------

def correctness():
    res = {"hash": {}, "kostya": {}, "roundtrip": {}}
    for path in INPUTS:
        res["hash"][path.name] = {lib: sh([EXES[lib], "hash", path]).strip() for lib in ("fork", "ujson")}
    for path in KOSTYA_INPUTS:
        k = {}
        for lib in ("fork", "ujson"):
            for task in ("kostya_dom", "kostya_stream"):
                k[f"{lib} {task}"] = sh([EXES[lib], task, path, 1]).splitlines()[0][4:]
        r = subprocess.run([str(EXES["yyjson"]), "kostya_dom", str(path), "1"], capture_output=True, text=True)
        k["yyjson kostya_dom"] = r.stderr.strip()[4:]
        res["kostya"][path.name] = k
    rt = GEN / "rt"
    rt.mkdir(exist_ok=True)
    for path in INPUTS:
        orig = res["hash"][path.name]["fork"]
        row = {}
        outs = {}
        for writer in ("fork", "ujson"):
            out = rt / f"{writer}_{path.name}"
            sh([EXES[writer], "roundtrip", path, 1, out])
            outs[writer] = out.read_bytes()
            for reader in ("fork", "ujson"):
                h = sh([EXES[reader], "hash", out]).strip()
                row[f"{writer} -> {reader}"] = "equal" if h == orig else f"DIFFERENT ({h})"
            row[f"{writer} bytes"] = len(outs[writer])
        row["outputs identical"] = outs["fork"] == outs["ujson"]
        if not row["outputs identical"]:
            a, b = outs["fork"], outs["ujson"]
            i = next((j for j in range(min(len(a), len(b))) if a[j] != b[j]), min(len(a), len(b)))
            row["first difference"] = (a[max(0, i - 30):i + 30].decode("utf-8", "replace"),
                                       b[max(0, i - 30):i + 30].decode("utf-8", "replace"))
        res["roundtrip"][path.name] = row
    return res


def conformance():
    files = sorted(SUITE.glob("*.json"))
    res = {}
    for lib in ("fork", "ujson"):
        out = sh([EXES[f"conf_{lib}"], *files])
        rows = {}
        for line in out.splitlines():
            name, doc, stream = line.rsplit(" ", 2)
            rows[Path(name).name] = (doc, stream)
        r = {"y": [0, 0, 0], "n": [0, 0, 0], "i_accept": [0, 0], "i_total": 0, "wrong": [], "i": {}}
        for name, (doc, stream) in sorted(rows.items()):
            kind = name[:1]
            if kind == "y":
                r["y"][0] += doc == "accept"
                r["y"][1] += stream == "accept"
                r["y"][2] += 1
                if doc != "accept" or stream != "accept":
                    r["wrong"].append(f"{name}: document {doc}, stream {stream}")
            elif kind == "n":
                r["n"][0] += doc == "reject"
                r["n"][1] += stream == "reject"
                r["n"][2] += 1
                if doc != "reject" or stream != "reject":
                    r["wrong"].append(f"{name}: document {doc}, stream {stream}")
            else:
                r["i_accept"][0] += doc == "accept"
                r["i_accept"][1] += stream == "accept"
                r["i_total"] += 1
                r["i"][name] = (doc, stream)
        res[lib] = r
    return res


# --- timing -------------------------------------------------------------------

def reps_for(path):
    size = path.stat().st_size
    return 5 if size > 10_000_000 else 30


def time_all(args):
    groups = {}
    for task, (libs, inputs) in TASKS.items():
        if args.only and task not in args.only:
            continue
        before, waited = wait_for_load(args.max_load, args.wait)
        print(f"{task}: load {before:.1f} after waiting {waited:.0f}s", flush=True)
        samples = {(lib, p.name): [] for lib in libs for p in inputs}
        info = {}
        peak = before
        t0 = time.time()
        for rnd in range(args.rounds):
            for path in inputs:
                order = libs[rnd % len(libs):] + libs[:rnd % len(libs)]
                for lib in order:
                    ns, kvs = run_task(lib, task, path, reps_for(path))
                    samples[(lib, path.name)] += ns
                    info[(lib, path.name)] = kvs
                    peak = max(peak, load1())
        after = load1()
        cells = {}
        for (lib, name), ns in samples.items():
            ns = sorted(ns)
            med = statistics.median(ns)
            q = statistics.quantiles(ns, n=4)
            kvs = info[(lib, name)]
            nbytes = int(kvs["bytes"])
            cells[f"{lib}|{name}"] = {
                "median_ns": med, "min_ns": ns[0], "iqr_rel": (q[2] - q[0]) / med, "n": len(ns),
                "mbs": nbytes / med * 1e3, "bytes": nbytes, "outbytes": int(kvs.get("outbytes", 0)),
            }
        groups[task] = {"load_before": before, "waited_s": waited, "load_after": after,
                        "noisy": before >= args.max_load, "load_peak": peak, "seconds": time.time() - t0, "cells": cells}
        print(f"  done in {time.time() - t0:.0f}s, load after {after:.1f}", flush=True)
    return groups


def rss_all():
    out = {}
    for task, (libs, inputs) in list(TASKS.items()) + [("read", (["fork", "ujson", "yyjson"], INPUTS))]:
        for lib in libs:
            for path in inputs:
                out[f"{task}|{lib}|{path.name}"] = peak_rss(lib, task, path)
    return out


# --- report -------------------------------------------------------------------

def render(r):
    L = []
    a = L.append
    a("# The fork's json against upstream's")
    a("")
    a(f"Measured {r['date']} on {r['machine']}; {r['cc']}; Goose compiler from "
      f"`{r['goose_commit']}` (json-bench worktree). Generated by `bench/json_compare/compare.py`.")
    a("")
    a(f"* **fork** — the fork's `json` (`stdlib/json.goose` + `stdlib/json/`), last changed in {r['fork_commit']}.")
    a(f"* **ujson** — upstream's `json` from aardappel/goose {r['ujson_commit']} (the only commit "
      f"that touches `stdlib/json.goose` on origin/master {r['origin_master']}), copied to "
      "`stdlib/ujson.goose` with only its `namespace` line changed.")
    a("* **yyjson** — `bench/json/third_party/yyjson.c` (0.13), driven by `yyjson_cmp.c`, for scale.")
    a("")
    a("All three are compiled with the same clang at -O2; the Goose programs through "
      "`goose -O2 --standalone` and the generated C. Each cell is the median of every timed rep "
      f"over {r['rounds']} rounds (1 untimed warmup rep per process; 30 reps per process for inputs "
      "under 10 MB, 5 for kostya_524k). MB/s is input bytes per second for every task, "
      "including write (output sizes are listed separately).")
    a("")
    a(SUMMARY)
    a(NOTES)
    a("## Inputs")
    a("")
    a("| Input | Bytes | Values | Numbers | Strings |")
    a("|---|---|---|---|---|")
    for name, h in r["correctness"]["hash"].items():
        f = kv(h["fork"])
        size = r["sizes"][name]
        a(f"| {name} | {size:,} | {int(f['values']):,} | {int(f['numbers']):,} | {int(f['strings']):,} |")
    a("")
    a("kostya_*: LangArena's Json::Generate text (bench/kostya), from `gen_kostya.goose`: 25,000 "
      "coordinates is LangArena's Json::ParseMapping size; 524,288 is the original "
      "kostya/benchmarks size.")
    a("")
    for task, g in r["timing"].items():
        libs, inputs = TASKS[task]
        a(f"## {task}")
        a("")
        a(f"Load {g['load_before']:.1f} before (after waiting {g['waited_s']:.0f} s), "
          f"{g['load_after']:.1f} after, {g.get('load_peak', 0):.1f} at most during the group{' — **noisy: started above the load limit**' if g['noisy'] else ''}.")
        a("")
        head = "| Input | " + " | ".join(f"{lib} MB/s | {lib} ms" for lib in libs)
        if "fork" in libs and "ujson" in libs:
            head += " | fork / ujson"
        a(head + " |")
        a("|" + "---|" * (1 + 2 * len(libs) + (1 if "fork" in libs and "ujson" in libs else 0)))
        for p in inputs:
            row = f"| {p.name} |"
            for lib in libs:
                c = g["cells"][f"{lib}|{p.name}"]
                row += f" {c['mbs']:.0f} | {c['median_ns'] / 1e6:.3f} |"
            if "fork" in libs and "ujson" in libs:
                f, u = g["cells"][f"fork|{p.name}"], g["cells"][f"ujson|{p.name}"]
                row += f" {u['median_ns'] / f['median_ns']:.2f}x |"
            a(row)
        a("")
        spread = [c["iqr_rel"] for c in g["cells"].values()]
        a(f"Spread (interquartile range / median) per cell: median {statistics.median(spread):.1%}, "
          f"max {max(spread):.1%}.")
        if task.startswith("write"):
            a("")
            a("Output bytes: " + "; ".join(
                f"{p.name}: " + ", ".join(f"{lib} {g['cells'][f'{lib}|{p.name}']['outbytes']:,}" for lib in libs)
                for p in inputs) + ".")
        a("")
    a("## Peak RSS (MB)")
    a("")
    a("A separate run with one warmup and one timed rep; `read` is the program reading the "
      "file and doing nothing else.")
    a("")
    rs = r["rss"]
    a("| Input | Lib | read | parse | kostya_dom | kostya_stream | write |")
    a("|---|---|---|---|---|---|---|")
    for p in INPUTS:
        for lib in ("fork", "ujson", "yyjson"):
            cells = []
            for task in ("read", "parse", "kostya_dom", "kostya_stream", "write"):
                v = rs.get(f"{task}|{lib}|{p.name}")
                cells.append(f"{v / 1e6:.1f}" if v else "–")
            a(f"| {p.name} | {lib} | " + " | ".join(cells) + " |")
    a("")
    c = r["correctness"]
    a("## Correctness")
    a("")
    a("Content hash (`common.goose`: every value's kind, keys, string bytes, numbers' f64 bits and "
      "container counts, in text order) of each library's document:")
    a("")
    a("| Input | fork | ujson | Agree |")
    a("|---|---|---|---|")
    for name, h in c["hash"].items():
        a(f"| {name} | {h['fork']} | {h['ujson']} | {'yes' if h['fork'] == h['ujson'] else '**NO**'} |")
    a("")
    a("kostya averages (x, y, z):")
    a("")
    a("| Input | Program | Averages |")
    a("|---|---|---|")
    for name, k in c["kostya"].items():
        for prog, v in k.items():
            a(f"| {name} | {prog} | {v} |")
    a("")
    a("Round trip: each library writes its document, and both libraries re-parse and hash the "
      "output, compared with the original's hash.")
    a("")
    a("| Input | fork→fork | fork→ujson | ujson→fork | ujson→ujson | fork bytes | ujson bytes | Same text |")
    a("|---|---|---|---|---|---|---|---|")
    for name, row in c["roundtrip"].items():
        a(f"| {name} | {row['fork -> fork']} | {row['fork -> ujson']} | {row['ujson -> fork']} | "
          f"{row['ujson -> ujson']} | {row['fork bytes']:,} | {row['ujson bytes']:,} | "
          f"{'yes' if row['outputs identical'] else 'no'} |")
    for name, row in c["roundtrip"].items():
        if "first difference" in row:
            a("")
            a(f"First difference in {name}: fork `…{row['first difference'][0]}…`, "
              f"ujson `…{row['first difference'][1]}…`")
    a("")
    a("## JSONTestSuite")
    a("")
    a("Document: `json::parse` / `ujson::parse`. Stream: the fork's cursor with every value read; "
      "ujson's Reader with `skip` over the root and `finish`.")
    a("")
    a("| | fork document | fork stream | ujson document | ujson stream |")
    a("|---|---|---|---|---|")
    f, u = r["conformance"]["fork"], r["conformance"]["ujson"]
    a(f"| `y_` accepted | {f['y'][0]}/{f['y'][2]} | {f['y'][1]}/{f['y'][2]} | {u['y'][0]}/{u['y'][2]} | {u['y'][1]}/{u['y'][2]} |")
    a(f"| `n_` rejected | {f['n'][0]}/{f['n'][2]} | {f['n'][1]}/{f['n'][2]} | {u['n'][0]}/{u['n'][2]} | {u['n'][1]}/{u['n'][2]} |")
    a(f"| `i_` accepted | {f['i_accept'][0]}/{f['i_total']} | {f['i_accept'][1]}/{f['i_total']} | {u['i_accept'][0]}/{u['i_total']} | {u['i_accept'][1]}/{u['i_total']} |")
    a("")
    for lib in ("fork", "ujson"):
        w = r["conformance"][lib]["wrong"]
        a(f"{lib} disagrees with the suite on: " + (", ".join(f"`{x}`" for x in w) if w else "nothing") + ".")
        a("")
    a("`i_` results (document / stream):")
    a("")
    a("| File | fork | ujson |")
    a("|---|---|---|")
    for name in f["i"]:
        a(f"| {name} | {' / '.join(f['i'][name])} | {' / '.join(u['i'][name])} |")
    a("")
    return "\n".join(L)


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True).stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", help="the goose compiler")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--max-load", type=float, default=4.0)
    ap.add_argument("--wait", type=float, default=1200, help="seconds to wait for load per group")
    ap.add_argument("--only", nargs="*", help="time only these tasks")
    ap.add_argument("--report-only", action="store_true")
    args = ap.parse_args()
    rpath = HERE / "results.json"
    if args.report_only:
        r = json.loads(rpath.read_text())
        tc.write_text(HERE / "results.md", render(r))
        return 0
    goose = tc.find_goose(args.exe)
    cc = tc.find_ccs()["clang"]
    print(f"building with {cc.desc}...", flush=True)
    build(goose, cc)
    gen_inputs()
    print("correctness...", flush=True)
    corr = correctness()
    conf = conformance()
    cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    r = {
        "date": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "machine": f"{cpu}, {os.cpu_count()} cores, macOS {macos}",
        "cc": subprocess.run(["clang", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
        "goose_commit": git("rev-parse", "--short", "HEAD"),
        "fork_commit": git("log", "-1", "--format=%h", "HEAD", "--", "stdlib/json.goose", "stdlib/json"),
        "ujson_commit": git("log", "-1", "--format=%h", "origin/master", "--", "stdlib/json.goose"),
        "origin_master": git("rev-parse", "--short", "origin/master"),
        "rounds": args.rounds,
        "sizes": {p.name: p.stat().st_size for p in INPUTS},
        "correctness": corr,
        "conformance": conf,
    }
    print("timing...", flush=True)
    timing = time_all(args)
    if args.only and rpath.exists():
        # Rerun groups replace their own entries; the rest are kept.
        old = json.loads(rpath.read_text())["timing"]
        old.update(timing)
        timing = {t: old[t] for t in TASKS if t in old}
    r["timing"] = timing
    print("peak RSS...", flush=True)
    r["rss"] = rss_all()
    tc.write_text(rpath, json.dumps(r, indent=1) + "\n")
    tc.write_text(HERE / "results.md", render(r))
    print(f"wrote {HERE / 'results.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
