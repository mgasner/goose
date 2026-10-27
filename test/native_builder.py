"""C compiled on its own appends to a Goose builder: a `u8[>..]&` parameter
arrives as goose.h's gs_rref, and gs_bld_append adds bytes to it. Checked for
a program's sidecar C and for a CMake package's target, built with
`goose build` and run in process by `goose run`."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

import toolchain as tc

APPEND_C = '''#include "goose.h"
/* Appends "ab" n times; an empty append changes nothing. */
void {name}(gs_rref out, int64_t n) {{
    for (int64_t i = 0; i < n; i++) gs_bld_append(out, "ab", 2);
    gs_bld_append(out, "", 0);
}}
'''


def check_native_builder(exe, base, *, jit):
    """Returns why a part was skipped, or None when every check ran; raises
    RuntimeError on a failure."""
    base = Path(base).resolve()
    base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="builder-", dir=base) as tmp:
        root = Path(tmp)
        env = dict(os.environ)
        env["GOOSE_HOME"] = str(root / "home")

        def run(argv):
            r = subprocess.run([str(a) for a in argv], cwd=root, env=env, capture_output=True,
                               text=True, errors="replace", timeout=600)
            return r.returncode, r.stdout, r.stderr

        def expect(argv, want, what):
            code, out, err = run(argv)
            if code != 0 or (want is not None and out.split() != want):
                raise RuntimeError(f"native builder: {what}: wanted {' '.join(want or ['success'])},"
                                   f" got exit {code}:\n{out}{err}")

        def program(path, extern, call):
            tc.write_text(path, "import std;\n" + extern +
                          "fn main() {\n    var s: u8[>..] = [];\n    s.append(\"<\");\n"
                          f"    {call}(s, 3);\n    s.append(\">\");\n    print(s, \" \", s.len);\n}}\n")

        # The program's own C.
        source = root / "fill.goose"
        program(source, "extern fn fill_ab(out: u8[>..]&, n: i64);\n", "fill_ab")
        tc.write_text(root / "fill_impl.c", APPEND_C.format(name="fill_ab"))
        tc.write_text(root / "fill.build", 'c_sources = ["fill_impl.c"];\n')
        app = root / ("fill" + tc.EXE_SUFFIX)
        expect([exe, "build", "-o", app, source], None, "goose build")
        expect([app], ["<ababab>", "8"], "the built program")
        if jit:
            expect([exe, "run", source], ["<ababab>", "8"], "goose run")

        code, out, err = run([exe, "toolchain", "--json"])
        try:
            info = json.loads(out)
        except ValueError:
            raise RuntimeError(f"native builder: goose toolchain --json:\n{out}{err}")
        if not info.get("cmake"):
            return "no cmake"

        # A CMake package's target.
        pkg = root / "pkgs" / "fillpkg"
        pkg.mkdir(parents=True, exist_ok=True)
        tc.write_text(pkg / "CMakeLists.txt",
                      "cmake_minimum_required(VERSION 3.20)\nproject(fillpkg C)\n"
                      "add_library(fillpkg STATIC fillpkg.c)\n")
        tc.write_text(pkg / "fillpkg.c", APPEND_C.format(name="fillpkg_ab"))
        tc.write_text(pkg / "fillpkg.build", 'cmake_target = "fillpkg";\n')
        tc.write_text(pkg / "fillpkg.goose",
                      "namespace fillpkg;\nextern fn fillpkg_ab(out: u8[>..]&, n: i64);\n"
                      "fn fill(out: u8[>..]&, n: i64) { fillpkg_ab(out, n); }\n")
        user = root / "use_fillpkg.goose"
        program(user, 'import fillpkg from "./pkgs/fillpkg";\n', "fillpkg::fill")
        app = root / ("use_fillpkg" + tc.EXE_SUFFIX)
        expect([exe, "build", "-o", app, user], None, "goose build of a CMake package")
        expect([app], ["<ababab>", "8"], "the program using a CMake package")
        if jit:
            expect([exe, "run", user], ["<ababab>", "8"], "goose run of a CMake package")
    return None
