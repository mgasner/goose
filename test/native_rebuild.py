"""When a native part is built again: a program's own C edited after a build
is compiled again for both `goose build` and `goose run`, and an extern fn
added to the program without touching its C rebuilds the JIT library, whose
symbol table names every extern fn. A library's symbol table leaves out the
extern fns of an example with a sidecar of its own and of a directory its
sidecar excludes.

A CMake package is configured again when its cmake_options change, including
after a configure that failed for want of one; a cmake_target its project
does not define is reported at configure; and a target compiled as C++ that
publishes a C++ standard to what links it builds, for both runs."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

import toolchain as tc


def check_native_rebuild(exe, base, *, jit):
    """Returns why a part was skipped, or None when every check ran; raises
    RuntimeError on a failure."""
    base = Path(base).resolve()
    base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rebuild-", dir=base) as tmp:
        root = Path(tmp)
        env = dict(os.environ)
        env["GOOSE_HOME"] = str(root / "home")

        def run(argv):
            r = subprocess.run([str(a) for a in argv], cwd=root, env=env, capture_output=True,
                               text=True, errors="replace", timeout=600)
            return r.returncode, r.stdout, r.stderr

        def require(good, message):
            if not good:
                raise RuntimeError(f"native rebuild: {message}")

        def expect(argv, want, what):
            code, out, err = run(argv)
            require(code == 0 and (want is None or out.split() == want),
                    f"{what}: wanted {' '.join(want or ['success'])}, got exit {code}:\n"
                    f"{out}{err}")

        def expect_failure(argv, message, what):
            code, out, err = run(argv)
            require(code != 0 and message in out + err,
                    f"{what}: wanted a failure saying {message!r}, got exit {code}:\n{out}{err}")

        # The program's own C.
        def program(*externs):
            tc.write_text(root / "rebuild.goose",
                          "import std;\n" +
                          "".join(f"extern fn {e}() -> i64;\n" for e in externs) +
                          "fn main() {\n" + "".join(f"    print({e}());\n" for e in externs) +
                          "}\n")

        def impl(a):
            tc.write_text(root / "rebuild_impl.c",
                          "#include <stdint.h>\n"
                          f"int64_t rebuild_a(void) {{ return {a}; }}\n"
                          "int64_t rebuild_b(void) { return 2; }\n")

        tc.write_text(root / "rebuild.build", 'c_sources = ["rebuild_impl.c"];\n')
        program("rebuild_a")
        impl(1)
        source = root / "rebuild.goose"
        app = root / ("rebuild" + tc.EXE_SUFFIX)
        expect([exe, "build", "-o", app, source], None, "goose build")
        expect([app], ["1"], "the built program")
        impl(11)
        expect([exe, "build", "-o", app, source], None, "goose build after editing the C")
        expect([app], ["11"], "the program built after editing the C")
        if jit:
            expect([exe, "run", source], ["11"], "goose run")
            impl(111)
            expect([exe, "run", source], ["111"], "goose run after editing the C")
            program("rebuild_a", "rebuild_b")
            expect([exe, "run", source], ["111", "2"], "goose run after adding an extern fn")

            # A library whose example has C of its own, and a directory its
            # sidecar excludes: their extern fns are none of the library's.
            nest = root / "pkgs" / "nest"
            for file, text in {
                    "nest.goose": "namespace nest;\nextern fn nest_seven() -> i64;\n"
                                  "fn f(x: i64) -> i64 { nest_seven() * x }\n",
                    "nest.c": "#include <stdint.h>\nint64_t nest_seven(void) { return 7; }\n",
                    "nest.build": 'c_sources = ["nest.c"];\nexclude = ["tools"];\n',
                    "examples/demo/demo.goose": "import std;\nextern fn demo_only() -> i64;\n"
                                                "fn main() { print(demo_only()); }\n",
                    "examples/demo/demo.c": "#include <stdint.h>\n"
                                            "int64_t demo_only(void) { return 1; }\n",
                    "examples/demo/demo.build": 'c_sources = ["demo.c"];\n',
                    "tools/gen.goose": "extern fn tools_only() -> i64;\n"}.items():
                (nest / file).parent.mkdir(parents=True, exist_ok=True)
                tc.write_text(nest / file, text)
            user = root / "use_nest.goose"
            tc.write_text(user, 'import std;\nimport nest from "./pkgs/nest";\n'
                                "fn main() { print(nest::f(7)); }\n")
            expect([exe, "run", user], ["49"], "goose run of a library with an example of its own")

        code, out, err = run([exe, "toolchain", "--json"])
        try:
            info = json.loads(out)
        except ValueError:
            raise RuntimeError(f"native rebuild: goose toolchain --json:\n{out}{err}")
        if not info.get("cmake"):
            return "no cmake"

        def package(name, lists, sources, goose):
            d = root / "pkgs" / name
            d.mkdir(parents=True, exist_ok=True)
            tc.write_text(d / "CMakeLists.txt", lists)
            for file, text in sources.items():
                tc.write_text(d / file, text)
            tc.write_text(d / f"{name}.goose", goose)
            user = root / f"use_{name}.goose"
            tc.write_text(user, f'import std;\nimport {name} from "./pkgs/{name}";\n'
                                f"fn main() {{ print({name}::f(7)); }}\n")
            return d / f"{name}.build", user, root / (f"use_{name}" + tc.EXE_SUFFIX)

        # A project that will not configure without an option.
        sidecar, user, app = package(
            "cfg",
            "cmake_minimum_required(VERSION 3.20)\nproject(cfg C)\n"
            "if(NOT DEFINED CFG_SCALE)\n"
            '    message(FATAL_ERROR "cfg needs CFG_SCALE")\n'
            "endif()\n"
            "add_library(cfg STATIC cfg.c)\n"
            "target_compile_definitions(cfg PRIVATE CFG_SCALE=${CFG_SCALE})\n",
            {"cfg.c": "#include <stdint.h>\n"
                      "int64_t cfg_scaled(int64_t x) { return CFG_SCALE * x; }\n"},
            "namespace cfg;\nextern fn cfg_scaled(x: i64) -> i64;\n"
            "fn f(x: i64) -> i64 { cfg_scaled(x) }\n")
        tc.write_text(sidecar, 'cmake_target = "cfg";\n')
        expect_failure([exe, "build", "-o", app, user], "cfg needs CFG_SCALE",
                       "goose build of a package missing a CMake option")
        for scale in (2, 3):
            tc.write_text(sidecar, f'cmake_target = "cfg";\ncmake_options = ["CFG_SCALE={scale}"];\n')
            expect([exe, "build", "-o", app, user], None, f"goose build with CFG_SCALE={scale}")
            expect([app], [str(7 * scale)], f"the program built with CFG_SCALE={scale}")
        tc.write_text(sidecar, 'cmake_target = "nosuch";\ncmake_options = ["CFG_SCALE=3"];\n')
        expect_failure([exe, "build", "-o", app, user],
                       "names the CMake target nosuch, which",
                       "goose build of a package naming a target its project does not define")

        # A C++ target publishing the standard it needs.
        sidecar, user, app = package(
            "cxx",
            "cmake_minimum_required(VERSION 3.20)\nproject(cxx CXX)\n"
            "add_library(cxx STATIC cxx.cpp)\n"
            "target_compile_features(cxx PUBLIC cxx_std_20)\n",
            {"cxx.cpp": "#include <cstdint>\n"
                        "template <typename T> constexpr T twice(T x) { return x + x; }\n"
                        'extern "C" int64_t cxx_twice(int64_t x) noexcept { return twice(x); }\n'},
            "namespace cxx;\nextern fn cxx_twice(x: i64) -> i64;\n"
            "fn f(x: i64) -> i64 { cxx_twice(x) }\n")
        tc.write_text(sidecar, 'cmake_target = "cxx";\n')
        expect([exe, "build", "-o", app, user], None, "goose build of a C++ package")
        expect([app], ["14"], "the program using a C++ package")
        if jit:
            expect([exe, "run", user], ["14"], "goose run of a C++ package")
    return None
