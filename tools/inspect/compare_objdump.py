#!/usr/bin/env python3
"""Compares the inspector's disassembly with LLVM's objdump: the arm64
decoder's, and for x86-64 Capstone's as the inspector restyles it.

    compare_objdump.py <inspect> <file>...       the text section of each file
    compare_objdump.py <inspect> --random N [--elf]
                                                 N random words, as a Mach-O or ELF object
    compare_objdump.py <inspect> --table OUT [--elf] <file>...
                                                 write the test table (test/inspect/) from
                                                 the files' code and random words

Each instruction is one of: the same as objdump prints it (symbols and
comments left out); not decoded (.word), which is never wrong; decoded
differently, or decoded where objdump has <unknown> -- both are bugs (for
x86-64, where Capstone decodes, a difference is the restyling's, or one of
the two that are left: objdump's `lock` on a line of its own, and the %st
fucompi leaves implicit). A
file can be a Mach-O or ELF executable or object; an object's sections are
at the addresses the inspector gives them, so its targets are compared
relative to the section. Needs objdump (Apple's, or llvm-objdump) and, for
--random, clang. See docs/design/inspect.md, section 4.3.
"""
import collections
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile

BRANCHY = re.compile(r"^(b|bl|b\.\w+|cbn?z|tbn?z|adrp?|ldr|ldrsw|j\w+|callq?)\b")


def norm(t):
    t = t.replace("<unknown>", "UNKNOWN").replace("(bad)", "UNKNOWN")
    t = re.sub(r"\s*<[^>]*>", "", t)
    t = re.sub(r"\s*(;|//|#).*$", "", t)
    return re.sub(r"\s+", " ", t).strip()


def text_section(inspect, path):
    out = subprocess.run([inspect, "sections", path], capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"{path}: {out.stderr.strip()}")
    m = re.search(r"^  (?:__TEXT,__text|\.text)\s+0x([0-9a-f]+)  size 0x([0-9a-f]+)", out.stdout, re.M)
    if not m:
        sys.exit(f"{path}: no text section")
    return int(m[1], 16), int(m[2], 16)


def objdump(path):
    exe = shutil.which("llvm-objdump") or shutil.which("objdump")
    out = subprocess.run([exe, "-d", path], capture_output=True, text=True).stdout
    x86 = "x86-64" in out[:400] or "x86_64" in out[:400]
    rows, section = [], None
    for line in out.splitlines():
        m = re.match(r"^Disassembly of section (\S+):", line)
        if m:
            section = m[1].rstrip(":")
            continue
        if section not in ("__TEXT,__text", ".text"):
            continue
        if x86:
            # Bytes one by one before a tab, then the text.
            g = re.match(r"^\s*([0-9a-f]+): ((?:[0-9a-f]{2} )+)\s*\t(.*)$", line)
            if g:
                rows.append((int(g[1], 16), g[2].replace(" ", ""), norm(g[3])))
            continue
        g = re.match(r"^\s*([0-9a-f]+): ([0-9a-f]{8})\s+(.*)$", line)
        if g:
            rows.append((int(g[1], 16), g[2], norm(g[3])))
    return rows


def compare(inspect, path, counts, examples):
    start, size = text_section(inspect, path)
    mine = subprocess.run([inspect, "disasm", path, hex(start), str(size)], capture_output=True, text=True)
    if mine.returncode:
        sys.exit(f"{path}: {mine.stderr.strip()}")
    ours = {}
    for line in mine.stdout.splitlines():
        g = re.match(r"^  ([0-9a-f]{9,})  ([0-9a-f]{8}|(?:[0-9a-f]{2} ?)+?)  \s*(\S.*)$", line)
        if g:
            ours[int(g[1], 16) - start] = (g[2].replace(" ", ""), g[3])
    theirs = objdump(path)
    if not theirs:
        return
    base = theirs[0][0]          # 0 for an object, the address for an executable
    for addr, word, t in theirs:
        if addr - base not in ours:
            continue
        w, m = ours[addr - base]
        decoded = not m.startswith(".word") and not m.startswith(".byte")
        m = norm(m)
        if decoded and BRANCHY.match(m) and start != base:
            # An object's targets, relative to the section as objdump has them.
            m = re.sub(r"(?<![#\w-])0x([0-9a-f]+)$", lambda x: hex((int(x[1], 16) - start + base) % (1 << 64)), m)
        if not t.startswith("UNKNOWN") and decoded:
            kind = "same" if m == t else "DIFFERENT"
        elif decoded:
            kind = "ACCEPTED (objdump: unknown)"
        elif not t.startswith("UNKNOWN"):
            kind = "not decoded"
        else:
            kind = "both unknown"
        counts[kind] += 1
        if kind not in ("same", "both unknown"):
            key = (kind, t.split(" ")[0])
            if len(examples[key]) < 3:
                examples[key].append((path, word, t, m))


def random_object(n, elf, workdir):
    s = os.path.join(workdir, "words.s")
    with open(s, "w") as f:
        f.write(".text\n.globl words\n.p2align 2\nwords:\n" if elf else
                ".section __TEXT,__text,regular,pure_instructions\n.globl _words\n.p2align 2\n_words:\n")
        for _ in range(n):
            # .inst, not .long: ELF marks .long in code as data ($d).
            f.write(f"{'.inst' if elf else '.long'} 0x{random.getrandbits(32):08x}\n")
    o = os.path.join(workdir, "words.o")
    target = ["-target", "aarch64-linux-gnu"] if elf else ["-arch", "arm64"]
    subprocess.run(["clang", *target, "-c", s, "-o", o], check=True)
    return o


def shape(t):
    # An instruction's operand shape: registers and numbers abstracted.
    t = re.sub(r"\b[xwsdqbhvz]\d+(\.\w+)?\b", "R", t)
    return re.sub(r"#-?0x[0-9a-f]+|#-?\d+(\.\d+)?|0x[0-9a-f]+|\[\d+\]", "N", t)


def table(inspect, out, elf, files):
    """Up to three encodings of each operand shape the files' code has, and
    random words: the ones objdump decodes, which the decoder may leave as
    .word (marked ?), and some neither decodes."""
    seen = collections.defaultdict(list)
    for path in files:
        for addr, word, t in objdump(path):
            if t.startswith("UNKNOWN") or any(w == word for _, w, _ in seen[shape(t)]):
                continue
            if len(seen[shape(t)]) < 3:
                seen[shape(t)].append((addr, word, t))
    rows = [(a, w, t) for v in seen.values() for a, w, t in v]
    random.seed(5)
    work = tempfile.mkdtemp()
    rnd = objdump(random_object(20000, elf, work))
    shutil.rmtree(work)
    known = [(a, w, t) for a, w, t in rnd if not t.startswith("UNKNOWN")]
    unknown = [(a, w, ".word") for a, w, t in rnd if t.startswith("UNKNOWN")]
    rows += [(a, w, "?" + t) for a, w, t in random.sample(known, 1500)]
    rows += random.sample(unknown, 1000)
    rows.sort(key=lambda r: r[1])
    syntax = "LLVM's generic syntax, as for ELF" if elf else "Apple's syntax, as for Mach-O"
    with open(out, "w") as f:
        f.write(f"""# arm64 encodings, the address each is at, and what LLVM's objdump makes of it
# in {syntax} (symbols and comments left out), or .word for one neither decodes.
# A ? marks a random word the decoder may leave as .word (an extension it does
# not read, SVE and the like) but must not decode as anything else. Written by
# tools/inspect/compare_objdump.py --table; checked by test/inspect_tool.py.
""")
        for a, w, t in rows:
            f.write(f"{a:x} {w} {t}\n")
    print(f"{len(seen)} shapes, {len(rows)} rows")


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)     # quiet under head
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    inspect, files = args[0], args[1:]
    if files[0] == "--table":
        elf = "--elf" in files
        table(inspect, files[1], elf, [f for f in files[2:] if f != "--elf"])
        return
    work = None
    if files[0] == "--random":
        n = int(files[1])
        random.seed(int(os.environ.get("SEED", "1")))
        work = tempfile.mkdtemp()
        files = [random_object(n, "--elf" in files, work)]
    counts, examples = collections.Counter(), collections.defaultdict(list)
    for path in files:
        compare(inspect, path, counts, examples)
    total = sum(counts.values())
    print(f"{total} words: " + ", ".join(f"{k} {v}" for k, v in counts.most_common()))
    for (kind, mnemonic), ex in sorted(examples.items(), key=lambda e: (e[0][0] != "DIFFERENT", e[0])):
        for path, word, t, m in ex:
            print(f"  {kind:28} {word}  objdump: {t:44}  inspect: {m}")
    if work:
        shutil.rmtree(work)
    bad = counts["DIFFERENT"] + counts["ACCEPTED (objdump: unknown)"]
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
