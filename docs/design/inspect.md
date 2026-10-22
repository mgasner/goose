# Inspecting compiled programs

<details>
<summary>Table of contents</summary>

- [1. Decisions](#1-decisions)
- [2. What a binary carries today](#2-what-a-binary-carries-today)
- [3. The compiler's part](#3-the-compilers-part)
- [4. The inspector](#4-the-inspector)
- [5. Without the source](#5-without-the-source)
- [6. Testing](#6-testing)
- [7. The plan](#7-the-plan)
- [8. Deferred and open](#8-deferred-and-open)

</details>

A tool, written in Goose, that opens an executable `goose build` made and
shows it three ways at once: its bytes, as a hex editor would; the machine
instructions those bytes decode to; and the Goose source each instruction
came from, through the C the compiler generated in between. It answers
"what did this line compile to", "which function is this address in", and
"what is at this offset in the file", for a program whose source is at hand,
and as much of the same as the binary allows for one whose source is not.
Written against the tree at `bd251f7`. The first step of the plan (§7),
`--lines`, is implemented; the rest is not.

## 1. Decisions

* **The C compiler's debug information carries the mapping.** The address
  to line mapping is DWARF's `.debug_line`, which every `cc -g` already
  writes. Goose's part is to make those lines Goose lines: the generated C
  says where each statement came from with `#line`, so the C compiler
  attributes its instructions to the `.goose` file. A debugger then steps
  through Goose source too, which is worth having on its own.
* **A sidecar for what DWARF cannot say.** `#line` replaces the C location,
  so it cannot also keep it, and a line table says nothing of
  specializations, inlined Goose calls or layouts. The compiler can write a
  JSON map beside the C (`--map`): each specialization's C name, Goose name,
  type arguments and source range; each struct and ADT instance's size and
  field offsets; Goose's own inlining chains. The inspector works without
  the map, with less to show.
* **The inspector is a Goose program, and reads the binary itself.**
  Mach-O, ELF and DWARF are parsed in Goose over `os.read_file` and the
  `binary` module, with no `objdump` (there are no subprocesses in `os`) and
  no native package for the formats. It is the first large consumer of
  `binary` and grows it where it is short (§4.1).
* **arm64 decoded in Goose; x86-64 through Capstone.** A fixed-width
  instruction set is a few hundred lines of decode table for what clang
  emits. x86-64 is not, and a dynamic extern (`dynamic_externs.md`) binds a
  system `libcapstone` with no adapter C. The arm64 decoder can be checked
  against the same library in tests.
* **Text first, a page second, a window last.** Subcommands that print, so
  every view is testable and scriptable; then an HTML export that links the
  three views statically; an interactive viewer on the `ui` package after
  that. A terminal UI waits on raw terminal input, which the runtime does
  not have.
* **Mach-O on arm64 first.** It is the platform the work happens on, and the
  one with the most awkward debug information (§2). ELF follows; PE and PDB
  are deferred.

## 2. What a binary carries today

`goose build` writes the program's C, then hands it to the toolchain
(`build.h`). With `--debug` that is `-O0 -g` and `GS_DEBUG=1`; otherwise
optimized, without debug information. The chain from an instruction back to
the program has three links:

| Link | Today |
|---|---|
| address → C line | `.debug_line`, under `--debug` only |
| C line → Goose line | nothing: the generated C has no `#line` and there is no map |
| address → function | the symbol table: every specialization is a `static` C function, so a local symbol, kept unless the binary is stripped |

What the compiler knows and does not write out: every node has a `Line`
(file, line and byte column, `ast.h`), and the runtime checks already name
theirs (`LocArgs`, the `gs_file<n>` strings). Specialization names are
`Sanitize(ns, name)` -- a `_g` suffix, a namespace's length after it -- plus
`_<id>` where one Goose name has several live specializations
(`CollectSpecs`, `codegen_frames.h`); the name decodes back to the Goose
name, the id to nothing without the map.

On macOS the DWARF of a program linked from objects stays in the objects:
the executable holds only a debug map (`N_OSO` stabs naming each `.o`), and
`dsymutil` collects the real thing into a `.dSYM` bundle. Clang runs
`dsymutil` itself when one invocation compiles and links, which is how
`Builder::Link` calls it, and the bundle then holds the runtime object's
debug information as well (the object is in the build cache, where the debug
map finds it). The inspector reads a `.dSYM` beside the executable and falls
back to the debug map.

## 3. The compiler's part

### 3.1 `#line`

Under `--lines` (which `--debug` implies), the generated C carries a
`#line N "file.goose"` before the C of each Goose statement whose line
differs from the last one written. The place to do it is codegen's single
line writer: `GenStmt` records the statement's line as the wanted one, and
`L()` writes the directive when the wanted line differs from the one in
force. A statement's own exit code -- restores, the jump past an `else` --
returns to the enclosing statement's line once the nested one is done, so
it is not charged to the last line of the block.

Each function's text ends by returning to the C file's own numbering
(`#line <n> "out.c"`), so that the runtime, declarations and the next
function are not attributed to Goose. The C line number is known only once
the file is assembled, so the directive is written as a marker and resolved
in the pass that assembles it (`main.cpp`).

What a line can and cannot say:

* **Granularity is the statement.** An expression across several lines
  belongs to its statement's first. The column is recorded but `#line` has
  none; the map can give it (§3.2).
* **Goose's inliner splices bodies before codegen** (`optimize.h`), so an
  inlined call's instructions carry the callee's lines, with nothing to say
  which call site they were inlined into. DWARF's inlined-subroutine entries
  describe only the C compiler's own inlining. The map records Goose's.
* **Optimization moves instructions.** At `-O2` clang interleaves the
  instructions of neighbouring statements; the line table stays correct for
  each instruction but a line's instructions are no longer contiguous. The
  inspector shows the instructions of a line as a set of ranges, not as a
  range.
* **The runtime inlines into Goose code.** At `-O2` much of what a Goose
  function's symbol covers is runtime helpers clang inlined into it
  (`gs_out_bytes`, the number formatting), whose lines are, correctly, the
  runtime's C. The Goose line such an instruction serves is the call site
  of the inlined subroutine in `.debug_info`, which is why the inspector
  reads more than the line table (§4.1).

### 3.1.1 What the spike measured

Instruction bytes in non-runtime functions, by the file the line table
gives them, with `--lines` and clang 21 on arm64 macOS:

| Sample | `-O0` Goose | `-O0` C | `-O2` Goose | `-O2` C | `-O2` line 0 |
|---|---|---|---|---|---|
| `01_tour` | 99.4% | 0.6% | 45.7% | 48.0% | 6.4% |
| `09_sorting` | 99.8% | 0.2% | 57.2% | 35.7% | 7.0% |
| `12_huffman` (`goose build --debug`) | 99.5% | 0.5% | | | |

At `-O0` the rest is the C `main` that starts the runtime. At `-O2` the C
share is runtime inlined into Goose functions (above), and line 0 is code
clang merged from several lines. A breakpoint set by Goose file and line
in lldb resolves to the statement's first instruction. The C of every
sample is byte-identical to the C without `--lines` once the directives
are removed.

### 3.2 The map

`--map prog.goosemap` writes JSON beside the C:

```json
{ "version": 1,
  "files": ["samples/01_tour.goose", "stdlib/std.goose"],
  "specs": [{ "c": "sum_g_12", "goose": "sum", "types": ["i64"],
              "file": 0, "line": 14, "end": 19 }],
  "types": [{ "c": "Point_g", "goose": "Point", "size": 16,
              "fields": [{ "name": "x", "offset": 0, "type": "f64" }] }],
  "lines": [[1201, 0, 15, 5, 12], [1207, 1, 88, 3, 40]] }
```

`lines` maps a C line of the generated file to a Goose file, line and
column, and to the spec whose source it is: through it, an address whose
DWARF line is a C line (a build without `#line`) still reaches Goose, and an
inlined body's lines name the spec that was inlined (its `FnSpec`) as well
as the one it was inlined into (the function the C line is in).

### 3.3 Cost

`#line` changes nothing a compile does except the text; the map is written
only when asked for. Neither changes code generation, which a test checks
(§6).

## 4. The inspector

`tools/inspect/`, a Goose program built with `goose build`.

### 4.1 Reading

* **Object formats:** Mach-O 64 (header, load commands, segments and
  sections, `LC_SYMTAB`, `LC_FUNCTION_STARTS`, `LC_UUID` to match a
  `.dSYM`), then ELF64 (section headers, `.symtab`, `.dynsym`).
* **DWARF:** the line program of `.debug_line`, versions 4 and 5, with
  `.debug_line_str` and `.debug_str`; then `.debug_info` and
  `.debug_abbrev` for subprogram ranges and inlined subroutines.
* **`binary` grows** the reads these need: `u64`, big-endian variants,
  ULEB128 and SLEB128, NUL-terminated strings. Each is checked like the
  existing ones (an offset and a success flag), so a truncated or hostile
  file yields an error, never a fault.

### 4.2 Views

```
inspect sections prog              segments and sections, file offsets, addresses
inspect syms prog                  symbols, decoded to Goose names where they are Goose
inspect hex prog <addr|sym|+off>   bytes, with the symbol and section each row is in
inspect disasm prog <sym>          instructions, each with its C and Goose line
inspect source prog file:line      the instructions a source line compiled to
inspect at prog <addr>             everything known about one address
inspect html prog out.html         all of the above as one linked page
```

`disasm --source` interleaves source lines with the instructions, as
`objdump -S` does, from the Goose source when the file is found, from the
map's names and lines when it is not. `hex` marks the bytes of the selected
instruction or source line in both directions.

### 4.3 Disassembly

The arm64 decoder covers the integer, load/store, branch and the scalar and
vector floating-point classes clang emits for the generated C, prints LLVM's
syntax, and prints anything else as `.word 0x...` with its encoding class:
an unknown instruction is shown, never guessed. Branch targets are resolved
to symbols, and `adrp`/`add` and `adrp`/`ldr` pairs to the address they
form, which names the string or global they load.

## 5. Without the source

| What there is | What the inspector shows |
|---|---|
| binary, DWARF and map, no source | Goose names, type arguments, lines and layouts; the text of a line is missing |
| binary and symbols | Goose names decoded from the C names; runtime functions (`gs_*`) marked as the runtime's; sections and strings |
| a stripped binary | hex and disassembly; function starts from `LC_FUNCTION_STARTS`; the runtime recognised by its strings |

## 6. Testing

Addresses and instruction choices depend on the C compiler and its version,
so the tests do not compare disassembly of freshly built programs to a
golden file. Instead:

* **Parsers** run on small binaries checked into `test/inspect/`, built once
  from a known sample, with golden output; truncated and corrupted copies of
  them must fail cleanly.
* **The decoder** runs on a generated corpus of arm64 encodings and is
  compared against Capstone where the library is present.
* **The mapping** is checked by property on samples built in the test run:
  every instruction a spec's symbol covers maps to a line inside that spec's
  source range, or to a spec the map says was inlined into it; every
  statement line of a sample's `main` has at least one instruction.
* **`--lines` and `--map` leave code alone:** a sample's C, with the
  directives removed, is identical to the C written without them.

## 7. The plan

1. **`#line` behind `--lines`** (§3.1), and `--debug` implying it. Done:
   a breakpoint set by Goose file and line resolves in a `goose build
   --debug` executable. Still to do: the test of §6 that the C is unchanged,
   in the suite rather than by hand.
2. **The map** (§3.2).
3. **`binary` additions** and the Mach-O reader: `sections`, `syms`, `hex`.
4. **DWARF line programs**, `.dSYM` lookup: `source` and `at`.
5. **The arm64 decoder**: `disasm`.
6. **The HTML export.**
7. **ELF**, then x86-64 through Capstone.
8. **The viewer** on the `ui` package.

## 8. Deferred and open

* **The JIT.** A JIT run writes no binary. TinyCC can write an object file
  with DWARF, which would make the in-process code inspectable as well.
* **PE and PDB.** The format is simple enough; PDB is not, and MSVC builds
  would need it.
* **Expression-level mapping.** `#line` cannot carry a column; DWARF 5 line
  programs can. Getting columns through would mean emitting each expression
  on a line of its own, which changes the C a great deal for little gain.
* **Data views.** With the map's layouts, `hex` could show a global's or a
  data stack's bytes as the Goose value they hold. That needs the process
  running, or a core file, which is a debugger's job.
* **`--lines` by default under `goose build`?** It costs nothing at run
  time, but `cc` diagnostics on the generated C then point into `.goose`
  files, which hides compiler bugs from whoever is chasing one.
