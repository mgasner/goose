"""Data stack regions on Linux: the first 2 MB of each is marked for no
transparent huge pages (VmFlags nh in /proc/<pid>/smaps), so that a stack
holding a few bytes commits a page of memory rather than a huge one. The
program waits on stdin while its mappings are read."""
import subprocess
import sys
import tempfile
from pathlib import Path

import toolchain as tc

PROGRAM = """\
import os;

fn main() {
    print("ready");
    flush_stdout();
    var line: u8[>..] = [];
    read_line(line);
}
"""


def check_program(app):
    """Runs the built program and raises RuntimeError unless a 2 MB mapping
    of its is marked nh."""
    p = subprocess.Popen([str(app)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    try:
        ready = p.stdout.readline()
        if b"ready" not in ready:
            raise RuntimeError(f"huge pages: the program said {ready!r}")
        smaps = Path(f"/proc/{p.pid}/smaps").read_text()
    finally:
        p.communicate(b"\n", timeout=60)
    marked = 0
    size = 0
    for line in smaps.splitlines():
        if line.startswith("Size:"):
            size = int(line.split()[1])
        elif line.startswith("VmFlags:") and " nh" in line and size == 2048:
            marked += 1
    if not marked:
        raise RuntimeError("huge pages: no 2 MB mapping of the program is marked nh")


def check_huge_pages(exe, base):
    """Returns why it was skipped, or None when the check ran; raises
    RuntimeError on a failure."""
    if not sys.platform.startswith("linux"):
        return "not Linux"
    if not Path("/sys/kernel/mm/transparent_hugepage").exists():
        return "no transparent huge pages"
    base = Path(base).resolve()
    base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="huge-pages-", dir=base) as tmp:
        root = Path(tmp)
        source = root / "waits.goose"
        tc.write_text(source, PROGRAM)
        app = root / "waits"
        r = subprocess.run([str(exe), "build", "-o", str(app), str(source)], cwd=root,
                           capture_output=True, text=True, errors="replace", timeout=300)
        if r.returncode != 0:
            raise RuntimeError(f"huge pages: goose build:\n{r.stdout}{r.stderr}")
        check_program(app)
    return None
