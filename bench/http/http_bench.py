#!/usr/bin/env python3
"""HTTP benchmarks: the request parser alone (suite P) and the server end to
end (suite S), each against standard C. The plan is bench/http/design.md.

    python bench/http/http_bench.py              # everything
    python bench/http/http_bench.py --only P     # the parse suite
    python bench/http/http_bench.py --only S3    # one sweep
    python bench/http/http_bench.py --quick      # 1 s runs, one per point
    python bench/http/http_bench.py --report-only

Writes bench/http/results.md and results.json; builds and logs go to
bench/gen/http/.
"""

import argparse
import json
import math
import os
import platform
import re
import resource
import shutil
import socket
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import toolchain as tc

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GEN = ROOT / "bench" / "gen" / "http"
PICO = HERE / "third_party" / "picohttpparser"
BREW = Path("/opt/homebrew")

PORTS = {"goose": 18080, "uv": 18081, "nginx": 18082}
SERVER_NAMES = {"goose": "Goose", "uv": "C: libuv + picohttpparser", "nginx": "nginx"}

# --- corpora (suite P) ------------------------------------------------------------------------

TECHEMPOWER = (
    "GET /plaintext HTTP/1.1\r\n"
    "Host: server\r\n"
    "User-Agent: Mozilla/5.0 (X11; Linux x86_64) Gecko/20130501 Firefox/30.0 "
    "AppleWebKit/600.00 Chrome/30.0.0000.0 Trident/10.0 Safari/600.00\r\n"
    "Cookie: uid=12345678901234567890; __utma=1.1234567890.1234567890.1234567890."
    "1234567890.12; wd=2560x1600\r\n"
    "Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;"
    "q=0.8,*/*;q=0.7\r\n"
    "Accept-Language: en-US,en;q=0.5\r\n"
    "Connection: keep-alive\r\n"
    "\r\n")

BROWSER = (
    "GET /articles/2026/10/the-fast-path?ref=home&utm_source=feed HTTP/1.1\r\n"
    "Host: www.example.com\r\n"
    "Connection: keep-alive\r\n"
    "sec-ch-ua: \"Chromium\";v=\"142\", \"Google Chrome\";v=\"142\", \"Not_A Brand\";v=\"99\"\r\n"
    "sec-ch-ua-mobile: ?0\r\n"
    "sec-ch-ua-platform: \"macOS\"\r\n"
    "Upgrade-Insecure-Requests: 1\r\n"
    "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36\r\n"
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,"
    "image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7\r\n"
    "Sec-Fetch-Site: same-origin\r\n"
    "Sec-Fetch-Mode: navigate\r\n"
    "Sec-Fetch-User: ?1\r\n"
    "Sec-Fetch-Dest: document\r\n"
    "Referer: https://www.example.com/\r\n"
    "Accept-Encoding: gzip, deflate, br, zstd\r\n"
    "Accept-Language: en-US,en;q=0.9\r\n"
    "Cookie: session=4f6c2a9e8b1d4e7fa3c5b2d1e0f9a8b7; theme=dark; _ga=GA1.1.123456789."
    "1760000000; prefs=eyJsYW5nIjoiZW4iLCJ0eiI6IkFtZXJpY2EvTmV3X1lvcmsifQ\r\n"
    "\r\n")


def corpora():
    """(id, label, x, bytes, mode): mode is seq, fresh or prefix."""
    out = [
        ("P1", "tiny", None, "GET / HTTP/1.1\r\nHost: a\r\n\r\n", "seq"),
        ("P2", "wrk", None, "GET /plaintext HTTP/1.1\r\nHost: 127.0.0.1:18080\r\n\r\n", "seq"),
        ("P3", "techempower", None, TECHEMPOWER, "seq"),
        ("P4", "browser", None, BROWSER, "seq"),
    ]
    for n in (1, 4, 16, 32):
        hs = "".join(f"X-Header-{k:02d}: v{k:015d}\r\n" for k in range(n - 1))
        out.append(("P5", f"headers-{n}", n, f"GET /h HTTP/1.1\r\nHost: a\r\n{hs}\r\n", "seq"))
    for n in (16, 256, 1024, 4096):
        out.append(("P6", f"value-{n}", n,
                    f"GET /v HTTP/1.1\r\nHost: a\r\nX-Value: {'v' * n}\r\n\r\n", "seq"))
    body = "b" * 1024
    out.append(("P7", "post-cl", None,
                f"POST /echo HTTP/1.1\r\nHost: a\r\nContent-Length: {len(body)}\r\n\r\n{body}",
                "seq"))
    chunks = "".join(f"100\r\n{'c' * 256}\r\n" for _ in range(4))
    out.append(("P8", "post-chunked", None,
                f"POST /echo HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n"
                f"{chunks}0\r\n\r\n", "fresh"))
    out.append(("P9", "pipelined", None, TECHEMPOWER * 16, "seq"))
    out.append(("P10", "partial", None, TECHEMPOWER, "prefix"))
    return out


# --- building ---------------------------------------------------------------------------------

def run(argv, **kw):
    return subprocess.run([str(a) for a in argv], capture_output=True, text=True,
                          errors="replace", **kw)


def build(goose, cc):
    GEN.mkdir(parents=True, exist_ok=True)
    exes, errors = {}, []

    def goose_exe(name, src, flags=()):
        cfile = GEN / f"{name}.c"
        r = run([goose, "-O2", *flags, "--standalone", "-o", cfile, src])
        tc.write_text(GEN / f"{name}.goose.log", r.stdout + r.stderr)
        if r.returncode != 0:
            errors.append(f"goose {src.name}: see {name}.goose.log")
            return None
        exe = GEN / name
        ok, _ = cc.compile(cfile, exe, opt=2, warn="none", log=GEN / f"{name}.cc.log")
        if not ok:
            errors.append(f"{cc.name} {name}: see {name}.cc.log")
        return exe if ok else None

    exes["parse_goose"] = goose_exe("parse_goose", HERE / "parse" / "parse.goose")
    exes["parse_goose_nobce"] = goose_exe("parse_goose_nobce", HERE / "parse" / "parse.goose",
                                          ["--no-bce"])
    exe = GEN / "parse_pico"
    ok, _ = cc.compile([HERE / "parse" / "parse_pico.c", PICO / "picohttpparser.c"], exe, opt=2,
                       extra=[f"-I{PICO}"], log=GEN / "parse_pico.cc.log")
    exes["parse_pico"] = exe if ok else None
    exes["goose"] = goose_exe("server_goose", HERE / "servers" / "server.goose")
    uvinc = BREW / "include"
    exe = GEN / "server_uv"
    ok, _ = cc.compile([HERE / "servers" / "uv_server.c", PICO / "picohttpparser.c"], exe, opt=2,
                       extra=[f"-I{PICO}", f"-I{uvinc}"],
                       libs=[f"-L{BREW / 'lib'}", "-luv"], log=GEN / "server_uv.cc.log")
    exes["uv"] = exe if ok else None
    if not ok:
        errors.append("uv_server: see server_uv.cc.log (is libuv installed?)")
    exes["nginx"] = shutil.which("nginx")
    return exes, errors


# --- suite P ----------------------------------------------------------------------------------

BATCH_RE = re.compile(r"^batch units=(\d+) ns=(\d+)$")


def parse_run(exe, corpus, mode, target_ns, batches):
    r = run([exe, corpus, mode, target_ns, batches])
    if r.returncode != 0:
        return {"error": (r.stdout + r.stderr)[-300:]}
    check = re.search(r"^check (-?\d+) units (\d+)$", r.stdout, re.M)
    per = [int(m.group(2)) / int(m.group(1))
           for m in (BATCH_RE.match(l) for l in r.stdout.splitlines()) if m]
    if not per or not check:
        return {"error": r.stdout[-300:]}
    per.sort()
    return {"ns": statistics.median(per), "p10": per[len(per) // 10],
            "p90": per[(len(per) * 9) // 10], "check": int(check.group(1)),
            "units": int(check.group(2))}


def suite_p(exes, args):
    out = []
    cdir = GEN / "corpus"
    cdir.mkdir(parents=True, exist_ok=True)
    target = 50_000_000 if args.quick else 200_000_000
    batches = 3 if args.quick else 7
    for cid, label, x, text, mode in corpora():
        if args.only and args.only not in ("P", cid):
            continue
        path = cdir / f"{label}.req"
        data = text.encode()
        path.write_bytes(data)
        row = {"id": cid, "label": label, "x": x, "bytes": len(data), "mode": mode}
        for key, exe in (("goose", exes["parse_goose"]), ("nobce", exes["parse_goose_nobce"]),
                         ("pico", exes["parse_pico"])):
            row[key] = parse_run(exe, path, mode, target, batches) if exe else {"error": "not built"}
        g, p = row["goose"], row["pico"]
        if "check" in g and "check" in p and (g["check"], g["units"]) != (p["check"], p["units"]):
            row["mismatch"] = f"goose {g['check']}/{g['units']} vs pico {p['check']}/{p['units']}"
        print(f"  {cid:4} {label:14} goose {fmt_ns(g.get('ns'))}  no-bce "
              f"{fmt_ns(row['nobce'].get('ns'))}  pico {fmt_ns(p.get('ns'))}"
              + (f"  MISMATCH {row['mismatch']}" if "mismatch" in row else ""), flush=True)
        out.append(row)
    return out


# --- suite S ----------------------------------------------------------------------------------

WRK_LUA = r"""
-- Requests for the serving suite: `depth` copies of one request per write,
-- `nheaders` extra headers of about 40 bytes, and a body of `body` bytes.
local depth, nheaders, bodylen, method, path = 1, 0, 0, "GET", nil
init = function(args)
  depth = tonumber(args[1]) or 1
  nheaders = tonumber(args[2]) or 0
  bodylen = tonumber(args[3]) or 0
  local headers = {}
  for i = 1, nheaders do
    headers[string.format("X-Extra-Header-%02d", i)] = string.rep("v", 20)
  end
  local body = nil
  if bodylen > 0 then
    body = string.rep("b", bodylen)
    method = "POST"
  end
  local one = wrk.format(method, nil, headers, body)
  req = string.rep(one, depth)
end
request = function() return req end
done = function(summary, latency, requests)
  local e = summary.errors
  io.write(string.format(
    "RESULT {\"requests\": %d, \"duration_us\": %d, \"bytes\": %d, " ..
    "\"connect\": %d, \"read\": %d, \"write\": %d, \"status\": %d, \"timeout\": %d, " ..
    "\"p50\": %d, \"p90\": %d, \"p99\": %d, \"p999\": %d}\n",
    summary.requests, summary.duration, summary.bytes, e.connect, e.read, e.write,
    e.status, e.timeout, latency:percentile(50), latency:percentile(90),
    latency:percentile(99), latency:percentile(99.9)))
end
"""


def wait_port(port, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.02)
    return False


def cpu_seconds(pid):
    """CPU time of pid and its children (nginx's workers)."""
    r = run(["ps", "-A", "-o", "pid=,ppid=,time="])
    total = 0.0
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) != 3 or (int(parts[0]) != pid and int(parts[1]) != pid):
            continue
        t = parts[2]
        days = 0
        if "-" in t:
            d, t = t.split("-")
            days = int(d)
        fields = [float(f) for f in t.split(":")]
        secs = 0.0
        for f in fields:
            secs = secs * 60 + f
        total += secs + days * 86400
    return total


class Server:
    def __init__(self, kind, exe, workers):
        self.kind, self.exe, self.workers = kind, exe, workers
        self.port = PORTS[kind]
        self.proc = None

    def __enter__(self):
        log = open(GEN / f"server_{self.kind}.log", "w")
        if self.kind == "nginx":
            d = GEN / "nginx"
            (d / "www" / "bytes").mkdir(parents=True, exist_ok=True)
            for n in SIZES:
                (d / "www" / "bytes" / str(n)).write_bytes(b"x" * n)
            conf = (HERE / "servers" / "nginx.conf").read_text().format(
                workers=self.workers, port=self.port, dir=d,
                reuseport=" reuseport" if sys.platform.startswith("linux") else "")
            (d / "nginx.conf").write_text(conf)
            argv = [self.exe, "-p", d, "-c", "nginx.conf"]
        else:
            argv = [self.exe, self.port, self.workers]
        self.proc = subprocess.Popen([str(a) for a in argv], stdout=log, stderr=subprocess.STDOUT)
        if not wait_port(self.port):
            self.__exit__(None, None, None)
            raise RuntimeError(f"{self.kind} did not start; see server_{self.kind}.log")
        return self

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        time.sleep(0.2)


def wrk(path, conns, threads, duration, depth=1, nheaders=0, body=0, port=18080):
    lua = GEN / "bench.lua"
    lua.write_text(WRK_LUA)
    argv = ["wrk", f"-t{min(threads, conns)}", f"-c{conns}", f"-d{duration}s", "--timeout", "5s",
            "-s", lua, f"http://127.0.0.1:{port}{path}", "--", depth, nheaders, body]
    r = run(argv, timeout=duration + 60)
    m = re.search(r"^RESULT (\{.*\})$", r.stdout, re.M)
    if not m:
        return {"error": (r.stdout + r.stderr)[-300:]}
    d = json.loads(m.group(1))
    d["rps"] = d["requests"] / (d["duration_us"] / 1e6)
    return d


SIZES = [13, 1024, 16384, 262144]


def sweeps(quick):
    """(id, title, axis, [(x, settings)], servers): settings are wrk's and W."""
    base = {"path": "/plaintext", "conns": 256, "depth": 1, "nheaders": 0, "body": 0, "W": 4}
    S = []

    def pts(axis_vals, **over):
        return [(x, {**base, **{k: (v(x) if callable(v) else v) for k, v in over.items()}})
                for x in axis_vals]

    S.append(("S1", "Plaintext, pipelined", "pipeline depth",
              pts([1, 4, 16], depth=lambda x: x), ["goose", "uv", "nginx"]))
    S.append(("S2", "JSON, not pipelined", "connections",
              pts([16, 64, 256, 1024], path="/json", conns=lambda x: x), ["goose", "uv", "nginx"]))
    S.append(("S3", "Server workers (plaintext, depth 16)", "workers",
              pts([1, 2, 4, 6, 8], depth=16, W=lambda x: x), ["goose", "uv", "nginx"]))
    S.append(("S4", "Connections (plaintext, depth 1)", "connections",
              pts([1, 16, 256, 4096], conns=lambda x: x), ["goose", "uv", "nginx"]))
    S.append(("S5", "Response size", "bytes",
              pts(SIZES, path=lambda x: f"/bytes/{x}", conns=64), ["goose", "uv", "nginx"]))
    S.append(("S6", "Request headers (plaintext, depth 16)", "extra headers",
              pts([0, 8, 24], depth=16, nheaders=lambda x: x), ["goose", "uv", "nginx"]))
    S.append(("S7", "Request body (POST /echo)", "body bytes",
              pts([0, 1024, 65536], path="/echo", conns=64, body=lambda x: x), ["goose", "uv"]))
    S.append(("S8", "Latency (1 connection, depth 1)", "",
              pts(["1 conn"], conns=1), ["goose", "uv", "nginx"]))
    if quick:
        S = [(i, t, a, p[::2] if len(p) > 2 else p, s) for i, t, a, p, s in S]
    return S


def suite_s(exes, args):
    out = []
    duration = 1 if args.quick else args.duration
    runs = 1 if args.quick else 3
    want = args.servers.split(",")
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(max(soft, 16384), hard), hard))
    except (ValueError, OSError):
        pass
    fdlimit = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
    for sid, title, axis, points, servers in sweeps(args.quick):
        if args.only and args.only not in ("S", sid):
            continue
        print(f"{sid} {title}", flush=True)
        rows = []
        for x, st in points:
            row = {"x": x, "settings": st}
            for kind in servers:
                if kind not in want:
                    continue
                if not exes.get(kind):
                    row[kind] = {"error": "not built"}
                    continue
                if st["conns"] * 2 + 64 > fdlimit:
                    row[kind] = {"error": f"needs ulimit -n {st['conns'] * 2 + 64}"}
                    continue
                try:
                    with Server(kind, exes[kind], st["W"]) as srv:
                        port = srv.port
                        kw = dict(conns=st["conns"], threads=args.wrk_threads,
                                  depth=st["depth"], nheaders=st["nheaders"], body=st["body"],
                                  port=port)
                        wrk(st["path"], duration=1, **kw)
                        results = []
                        for _ in range(runs):
                            c0 = cpu_seconds(srv.proc.pid)
                            res = wrk(st["path"], duration=duration, **kw)
                            if "error" not in res:
                                res["cpu_us_per_req"] = ((cpu_seconds(srv.proc.pid) - c0) * 1e6
                                                         / max(res["requests"], 1))
                            results.append(res)
                except RuntimeError as e:
                    row[kind] = {"error": str(e)}
                    continue
                good = [r for r in results if "error" not in r]
                if not good:
                    row[kind] = {"error": results[0]["error"]}
                    continue
                med = sorted(good, key=lambda r: r["rps"])[len(good) // 2]
                med = dict(med)
                med["runs"] = [round(r["rps"]) for r in good]
                errs = sum(r["connect"] + r["read"] + r["write"] + r["status"] + r["timeout"]
                           for r in good)
                if errs:
                    med["errors_total"] = errs
                row[kind] = med
                print(f"  {sid} {axis or 'point'}={x} {kind:6} {med['rps']:>12,.0f} req/s"
                      f"  p99 {med['p99'] / 1000:.2f} ms  cpu {med.get('cpu_us_per_req', 0):.2f}"
                      f" µs/req" + (f"  ERRORS {errs}" if errs else ""), flush=True)
            rows.append(row)
        out.append({"id": sid, "title": title, "axis": axis, "rows": rows, "servers": servers})
    return out


# --- report -----------------------------------------------------------------------------------

def fmt_ns(v):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "-"
    if v >= 1000:
        return f"{v / 1000:.2f} µs"
    return f"{v:.1f} ns"


def fit_line(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0, my
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return b, my - b * mx


def render(res, path):
    L = []
    meta = res["meta"]
    L.append("# HTTP benchmark results\n")
    L.append(f"Generated by `bench/http/http_bench.py` on {meta['date']}. "
             f"Machine: {meta['machine']}. C compiler: {meta['cc']}. "
             f"Plan and predictions: `design.md`.\n")
    if res.get("parse"):
        L.append("## Suite P: parsing\n")
        L.append("Median ns per request; for P10, per prefix. *no-BCE* is the Goose "
                 "parser built with `--no-bce`. *ratio* is Goose / picohttpparser.\n")
        L.append("| id | corpus | bytes | Goose | Goose no-BCE | picohttpparser | ratio | Goose MB/s |")
        L.append("|---|---|---:|---:|---:|---:|---:|---:|")
        for r in res["parse"]:
            g, nb, p = r["goose"], r["nobce"], r["pico"]
            ratio = (f"{g['ns'] / p['ns']:.2f}x" if "ns" in g and "ns" in p else "-")
            per_req = r["bytes"] / (16 if r["label"] == "pipelined" else 1)
            mbs = (f"{per_req / g['ns'] * 1000:.0f}" if "ns" in g and r["mode"] != "prefix"
                   else "-")
            note = " ⚠ checksum mismatch" if r.get("mismatch") else ""
            L.append(f"| {r['id']} | {r['label']}{note} | {r['bytes']} | {fmt_ns(g.get('ns'))} | "
                     f"{fmt_ns(nb.get('ns'))} | {fmt_ns(p.get('ns'))} | {ratio} | {mbs} |")
        L.append("")
        for pid, what, unit in (("P5", "per header", "header"), ("P6", "per value byte", "byte")):
            rows = [r for r in res["parse"] if r["id"] == pid and "ns" in r["goose"]
                    and "ns" in r["pico"]]
            if len(rows) >= 2:
                xs = [r["x"] for r in rows]
                gb, _ = fit_line(xs, [r["goose"]["ns"] for r in rows])
                pb, _ = fit_line(xs, [r["pico"]["ns"] for r in rows])
                extra = ""
                if unit == "byte":
                    extra = f" ({1 / gb:.2f} vs {1 / pb:.2f} GB/s)" if gb > 0 and pb > 0 else ""
                L.append(f"- {pid} slope, {what}: Goose {gb:.2f} ns, picohttpparser "
                         f"{pb:.2f} ns{extra}.")
        L.append("")
    if res.get("serve"):
        L.append("## Suite S: serving\n")
        L.append(f"wrk with {meta['wrk_threads']} threads, {meta['duration']} s per run, the "
                 f"median of {meta['runs']} runs per cell. Requests per second; *p99* is wrk's "
                 "99th-percentile latency; *CPU* is the server's CPU time per request. "
                 "Server W = 4 unless the sweep varies it.\n")
        for s in res["serve"]:
            L.append(f"### {s['id']}: {s['title']}\n")
            servers = s["servers"]
            hdr = f"| {s['axis'] or ' '} |" + "".join(
                f" {SERVER_NAMES[k]} req/s | p99 | CPU µs/req |" for k in servers)
            L.append(hdr)
            L.append("|---|" + "---:|---:|---:|" * len(servers))
            for row in s["rows"]:
                cells = []
                for k in servers:
                    c = row.get(k, {})
                    if "rps" in c:
                        err = f" ⚠{c['errors_total']}" if c.get("errors_total") else ""
                        cells.append(f" {c['rps']:,.0f}{err} | {c['p99'] / 1000:.2f} ms | "
                                     f"{c.get('cpu_us_per_req', float('nan')):.2f} |")
                    else:
                        cells.append(f" {c.get('error', '-')[:40]} | | |")
                L.append(f"| {row['x']} |" + "".join(cells))
            L.append("")
    if res.get("analysis"):
        L.append("## Findings\n")
        L.append(res["analysis"])
    tc.write_text(path, "\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="P, S, or one id (P3, S2, ...)")
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--duration", type=int, default=5)
    ap.add_argument("--wrk-threads", type=int, default=4)
    ap.add_argument("--servers", default="goose,uv,nginx")
    ap.add_argument("--report-only", action="store_true")
    ap.add_argument("--exe", help="the goose compiler")
    args = ap.parse_args()
    tc.setup_console()
    rjson = HERE / "results.json"
    if args.report_only:
        render(json.loads(rjson.read_text()), HERE / "results.md")
        return 0
    goose = tc.find_goose(args.exe)
    ccs = tc.find_ccs()
    cc = ccs.get("clang") or ccs.get("gcc")
    if not cc or cc.style != "gcc":
        print("needs clang or gcc (the servers and wrk are POSIX)")
        return 1
    if not shutil.which("wrk"):
        print("wrk not found (brew install wrk)")
        return 1
    print(f"building with {cc.desc}", flush=True)
    exes, errors = build(goose, cc)
    for e in errors:
        print("  build:", e)
    old = json.loads(rjson.read_text()) if rjson.exists() else {}
    res = {"meta": {"date": datetime.now().strftime("%Y-%m-%d %H:%M"),
                    "machine": f"{platform.machine()} {platform.platform()} "
                               f"({os.cpu_count()} cores)",
                    "cc": cc.desc, "duration": 1 if args.quick else args.duration,
                    "runs": 1 if args.quick else 3, "wrk_threads": args.wrk_threads,
                    "quick": args.quick}}
    if not args.only or args.only.startswith("P"):
        print("Suite P: parsing", flush=True)
        res["parse"] = suite_p(exes, args)
    elif "parse" in old:
        res["parse"] = old["parse"]
    if not args.only or args.only.startswith("S"):
        print("Suite S: serving", flush=True)
        res["serve"] = suite_s(exes, args)
    elif "serve" in old:
        res["serve"] = old["serve"]
    if "analysis" in old:
        res["analysis"] = old["analysis"]
    rjson.write_text(json.dumps(res, indent=1))
    render(res, HERE / "results.md")
    print(f"wrote {HERE / 'results.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
