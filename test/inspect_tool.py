"""The binary inspector (tools/inspect, docs/design/inspect.md) on a program
built here, checked by what must hold rather than against a golden file,
since addresses and instructions depend on the C compiler: every symbol it
decodes to a Goose name is the name the program's --map gives that
function, an address resolves to the function its symbol starts, the bytes
it shows are the file's, and a truncated or foreign file is an error it
reports, never a fault. Mach-O only, for now."""
import json
import re
import subprocess
from pathlib import Path

import toolchain as tc


def check_inspect(exe, cc, base, *, runtime, extra=()):
    """Raises RuntimeError on a failure; does nothing off macOS or with
    no C compiler."""
    if not cc or not tc.IS_MACOS or cc.style == "msvc":
        return
    base = (Path(base) / "inspect").resolve()
    base.mkdir(parents=True, exist_ok=True)

    def run(argv):
        r = subprocess.run([str(a) for a in argv], capture_output=True, text=True,
                           errors="replace", timeout=600)
        if tc.sanitizer_failure(r.stderr):
            raise RuntimeError(r.stdout + r.stderr)
        return r.returncode, r.stdout, r.stderr

    def build(source, name, opt, goose_args=(), cflags=()):
        cfile = base / f"{name}.c"
        code, out, err = run([exe, f"-O{opt}", *goose_args, "-o", cfile, source])
        if code:
            raise RuntimeError(f"{name}: {out}{err}")
        binary = base / f"{name}{tc.EXE_SUFFIX}"
        ok, log = cc.compile(cfile, binary, opt=opt, extra=list(extra) + list(cflags),
                             runtime=runtime)
        if not ok:
            raise RuntimeError(f"{name}:\n{log}")
        return binary

    inspect = build(tc.REPO_ROOT / "tools" / "inspect" / "inspect.goose", "inspect", 1)
    mapfile = base / "sorting.goosemap"
    prog = build(tc.REPO_ROOT / "samples" / "09_sorting.goose", "sorting", 0,
                 ("--lines", "--map", mapfile), ("-g",))
    specs = {s["c"]: s["goose"] for s in json.loads(mapfile.read_text())["specs"]}

    code, out, err = run([inspect, "sections", prog])
    if code or "__TEXT,__text" not in out:
        raise RuntimeError(f"sections:\n{out}{err}")

    code, out, err = run([inspect, "syms", prog])
    if code:
        raise RuntimeError(f"syms:\n{out}{err}")
    rows = re.findall(r"^0x([0-9a-f]+) +(\d+)  (\S+)  \((\w+)\)$", out, re.MULTILINE)
    found = [(int(a, 16), name, c) for a, _, name, c in rows if c in specs]
    wrong = [f"{c}: {name}, the map says {specs[c]}" for _, name, c in found
             if name.split("#")[0] != specs[c]]
    if wrong or len(found) < len(specs) // 2:
        raise RuntimeError(f"syms decoded {len(found)} of {len(specs)} specs; "
                           + "; ".join(wrong[:5]) + f"\n{out[:2000]}")

    start = next((a for a, _, c in found if c == "main_g"), None)
    if start is None:
        raise RuntimeError(f"syms: no main_g\n{out[:2000]}")
    code, out, err = run([inspect, "at", prog, hex(start + 4)])
    if code or "main  (main_g) +0x4" not in out:
        raise RuntimeError(f"at {hex(start + 4)}:\n{out}{err}")
    offset = re.search(r"file \+0x([0-9a-f]+)", out)

    code, out, err = run([inspect, "hex", prog, "main_g", "32"])
    first = re.search(r"^0x[0-9a-f]+  \+([0-9a-f]+)  ((?:[0-9a-f]{2} +)+)", out, re.MULTILINE)
    if code or not first or not offset:
        raise RuntimeError(f"hex main_g:\n{out}{err}")
    data = prog.read_bytes()
    row = int(first[1], 16)
    shown = bytes(int(b, 16) for b in first[2].split())
    # The row is aligned to 16 bytes; main_g's bytes are its last ones.
    at = int(offset[1], 16) - 4
    if shown != data[at:at + len(shown)] or row > at:
        raise RuntimeError(f"hex main_g shows {shown.hex()}, the file has "
                           f"{data[at:at + len(shown)].hex()} at {at:#x}\n{out}")

    # Line information, from the .dSYM the compile and link left beside it:
    # every Goose line a function's table names is inside a function the
    # map says that file declares, and a line's code is in the function.
    m = json.loads(mapfile.read_text())
    ranges = {}
    for s in m["specs"]:
        ranges.setdefault(Path(m["files"][s["file"]]).name, []).append((s["line"], s["end"]))
    code, out, err = run([inspect, "lines", prog, "main_g"])
    rows = re.findall(r"^  0x[0-9a-f]+  (\S+?):(?: no line|(\d+))", out, re.MULTILINE)
    if code or len(rows) < 20:
        raise RuntimeError(f"lines main_g:\n{out}{err}")
    outside = [f"{f}:{l}" for f, l in rows if l and not any(
        lo <= int(l) <= hi for lo, hi in ranges.get(f, []))]
    if outside:
        raise RuntimeError(f"lines main_g names lines no function has: {outside[:5]}\n{out}")
    line = next(int(l) for f, l in rows if f == "09_sorting.goose" and l and
                int(l) > min(lo for lo, _ in ranges[f]))
    code, out, err = run([inspect, "source", prog, f"09_sorting.goose:{line}"])
    if code or "main  (main_g)" not in out:
        raise RuntimeError(f"source 09_sorting.goose:{line}:\n{out}{err}")
    code, out, err = run([inspect, "at", prog, hex(start + 4)])
    if code or not re.search(r"^  09_sorting\.goose:\d+", out, re.MULTILINE):
        raise RuntimeError(f"at {hex(start + 4)} gives no line:\n{out}{err}")
    alone = base / "sorting-alone"
    alone.write_bytes(prog.read_bytes())
    code, out, err = run([inspect, "lines", alone, "main_g"])
    if code != 1 or "no line information" not in err:
        raise RuntimeError(f"lines without a .dSYM: exit {code}\n{out}{err}")

    foreign = base / "sorting.c"
    for name, content in [("empty", b""), ("short", data[:3]), ("header", data[:100]),
                          ("half", data[:len(data) // 2]), ("c", foreign.read_bytes())]:
        path = base / f"broken-{name}"
        path.write_bytes(content)
        for cmd in ("sections", "syms"):
            code, out, err = run([inspect, cmd, path])
            if code != 1 or not err.startswith("inspect: ") or "runtime error" in err:
                raise RuntimeError(f"{cmd} on {name}: exit {code}\n{err}")
