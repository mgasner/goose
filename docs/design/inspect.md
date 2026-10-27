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
Written against upstream `64d62fc`, with the fork's six translation
units. The first steps of the plan (§7), `--lines`, `--map`, the Mach-O
reader, the line tables, the arm64 decoder, the HTML export and ELF, are
implemented; the rest is not.

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
`#line N "file.goose"` before each C line of a Goose statement. Codegen
marks only where the line changes: `GenStmt` records the statement's line
as the wanted one, and `L()`, codegen's single line writer, writes a marker
when the wanted line differs from the one in force. The restores a
statement's scope ends with are its own; what the enclosing statement
emits after it is the enclosing line's again. A function's signature and
its entry code are its declaration's line.

The rest happens once the file is assembled (`FinishLines`,
`codegen.h`), because the passes over a function's text
(`HoistAggregateDecls`, the top-cache markers) move and insert lines after
codegen wrote them. `#line N` numbers only the line after it N, and the
ones after that N+1 and on, so a statement whose C takes several lines
needs the directive repeated before each of them, or its later
instructions are charged to the Goose lines below it. After each function
the C file's own numbering comes back (`#line <n> "out.c"`), so the
runtime, the declarations and the next function are not charged to Goose.
A line ending in a backslash takes no directive after it.

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
| `01_tour` | 99.4% | 0.6% | 46.2% | 47.7% | 6.2% |
| `09_sorting` | 99.8% | 0.2% | 58.8% | 34.2% | 7.0% |
| `12_huffman` | 99.4% | 0.6% | 70.9% | 26.8% | 2.4% |

At `-O0` the rest is the C `main` that starts the runtime. At `-O2` the C
share is runtime inlined into Goose functions (above), and line 0 is code
clang merged from several lines. Every Goose line the debug information
names is one a directive named. A breakpoint set by Goose file and line in
lldb resolves to the statement's first instruction. The C of every sample
is byte-identical to the C without `--lines` once the directives are
removed, and every test and sample that compiles gives C that clang
accepts with them.

### 3.2 The map

`--map prog.goosemap` writes JSON beside the C (`CodeGen::SourceMap`),
with or without `--lines`, and needs C output (`-o`, or `goose build`):

```json
{"version": 1,
"files": ["/abs/samples/01_tour.goose"],
"specs": [
 {"c": "main_g", "goose": "main", "params": [], "rets": [], "file": 0, "line": 39, "end": 166},
 {"c": "divide_g", "goose": "divide", "params": ["i64", "i64"], "rets": ["i64", "bool"],
  "file": 0, "line": 19, "end": 22}],
"structs": [
 {"goose": "Point", "args": [], "size": 16, "fields": [
   {"name": "x", "offset": 0, "type": "f64"}, {"name": "y", "offset": 8, "type": "f64"}]}],
"lines": [[1, -1, 0], [4301, 0, 39], [4303, 0, 45]]}
```

* `files` are absolute, as the directives name them.
* `specs` has every live specialization's C function, and the element-run
  twin's (C.3) as well, with the Goose name, the concrete parameter and
  result types, and the declaration's lines.
* `structs` has every fixed-size struct instance codegen laid out, with
  its packed field offsets (C.1): what the hex view needs to show a value.
* `lines` is a run-length table over the C the map was written with: from
  the C line given on, the Goose file and line, file -1 being the C file's
  own. An address whose debug line is a C line, from a build without
  `--lines`, reaches Goose through it.

Not yet in the map: columns (the statement's are known), Goose's inlining
-- an inlined body's lines are the callee's, which the specs' ranges
place, but a generic callee's specialization is not told apart -- and
ADT layouts.

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
inspect lines prog <sym>           the line table over a function, with the source
inspect hex prog <addr|sym|+off>   bytes, with the symbol and section each row is in
inspect disasm prog <sym>          instructions, each with its C and Goose line
inspect source prog file:line      the address ranges a source line compiled to
inspect at prog <addr>             everything known about one address
inspect html prog out.html         all of the above as one linked page
```

`disasm --source` interleaves source lines with the instructions, as
`objdump -S` does, from the Goose source when the file is found, from the
map's names and lines when it is not. `hex` marks the bytes of the selected
instruction or source line in both directions.

### 4.3 Disassembly

The arm64 decoder (`arm64.goose`) covers the integer, load/store (single,
pair, literal, atomic, exclusive, and the structure loads), branch and
system, scalar floating-point and the vector classes clang emits, and
prints them as LLVM's objdump does: its aliases (`mov`, `cmp`, `cset`,
`lsl`, `ubfx`, ...), its numbers (hex, but decimal bitfield positions;
`%#016llx` for `movi.2d`), and in the syntax objdump uses for the file:
Apple's for Mach-O (`add.2d v0, v1, v2`, `mov.s v0[1], w8`), the generic
one for ELF (`add v0.2d, v1.2d, v2.2d`, `mov v0.s[1], w8`), where each
operand carries its own arrangement (`uaddw v1.8h, v1.8h, v2.8b`).
Branch targets are resolved to the function and offset they land in, as
are `adrp`'s pages. Anything else prints as `.word 0x...`: an unknown
instruction is shown, never guessed.

Measured against `objdump -d` (`tools/inspect/compare_objdump.py`, which
any change to the decoder should be run through):

| Input | Instructions | Same | Not decoded | Different |
|---|---|---|---|---|
| clang's code for the samples and a ninth of the tests, `-O0` to `-O3`, Mach-O | 884,901 | 884,901 | 0 | 0 |
| held out: another ninth of the tests at `-O1`, `-O2`, `-Os`, and the Goose compiler (C++) | 1,141,193 | 1,141,192 | 1 | 0 |
| the same C for `aarch64-linux-gnu`, ELF objects, generic syntax | 1,279,968 | 1,279,968 | 0 | 0 |
| the Mach-O set rebuilt after the generic syntax went in, and the compiler | 1,950,180 | 1,950,180 | 0 | 0 |
| random 32-bit words, 1,800,000 in both syntaxes: those objdump decodes | 728,356 | 521,656 | 206,700 | 0 |

The decoder was written against the first set; the held-out set came after
it, and its only miss was a half-precision vector `fneg`. Of the random
words, none the decoder prints is printed differently by objdump, and none
objdump rejects is accepted: what it leaves undecoded is SVE, the
half-precision forms, the system registers and the like, none of which
clang emits for Goose. x86-64 is not decoded (§7).

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

* **The reader** runs on a sample the suite builds (`test/inspect_tool.py`)
  and is checked by what must hold of any build: each symbol decoded to a
  Goose name is the name the map gives that C function, an address resolves
  to the function its symbol starts, the bytes `hex` shows are the file's,
  every Goose line a function's table names is inside a function the map
  says that file declares, a line's code is in its function, and
  truncated, empty and foreign files, and a missing `.dSYM`, are refused
  with a message. No binary is checked in. Fuzz runs (random bytes in the
  load commands, and in `__debug_line`, 300 files each) found no fault,
  and a comparison with lldb no difference; neither is part of the suite,
  the second since lldb is slow to start and not on every machine.
* **The page** for the sample holds the functions it should (Goose's,
  not the runtime's), `main`'s instructions as `disasm` prints them, and
  lines that are lines of the source files it carries. The script itself
  was checked in headless Chrome, not in the suite: an instruction, a
  source line, a branch target and the filter each do what they should.
* **The decoder** decodes the 4,449 encodings of
  `test/inspect/arm64_words.txt`, each of up to three per operand shape
  clang's code had and random ones, against objdump's text; an encoding
  only a random word gave may stay `.word`. The sample's whole `__text`
  must decode, and its `main` disassemble with its source lines. The
  comparison of §4.3 is not in the suite: it needs objdump and minutes.
* **The mapping** is checked by property on samples built in the test run:
  every instruction a spec's symbol covers maps to a line inside that spec's
  source range, or to a spec the map says was inlined into it; every
  statement line of a sample's `main` has at least one instruction.
* **`--lines` and `--map` leave code alone:** a sample's C, with the
  directives removed, is identical to the C written without them.

## 7. The plan

1. **`#line` behind `--lines`** (§3.1), and `--debug` implying it. Done:
   a breakpoint set by Goose file and line resolves in a `goose build
   --debug` executable, and the suite checks the C is otherwise unchanged.
2. **The map** (§3.2). Done, less what §3.2 lists as not yet in it.
3. **`binary` additions** and the Mach-O reader: `sections`, `syms`, `hex`.
   Done, with `at`: `u8`, `i32`, `u64`/`i64`, big-endian, C-string and
   LEB128 reads in `binary`; `tools/inspect/macho.goose` and
   `tools/inspect/inspect.goose`.
4. **DWARF line programs**, `.dSYM` lookup: `source` and `at`. Done,
   with `lines`: `tools/inspect/dwarf.goose` reads every unit's line
   program, versions 2 to 5, 32- and 64-bit; the companion is the `.dSYM`
   beside the executable, matched by UUID. Its answers agree with lldb's
   `image lookup` at every one of 580 addresses sampled from `-O0` and
   `-O2` builds, runtime functions among them. Not done: the debug map
   (objects' DWARF without a `.dSYM`), and `.debug_info`'s inlined call
   sites.
5. **The arm64 decoder**: `disasm`. Done: `tools/inspect/arm64.goose`,
   and `decode` for a list of encodings (§4.3).
6. **The HTML export.** Done: `inspect html prog out.html [--all]`
   writes one page with no server behind it (`html.goose`): the
   functions, each instruction's address, bytes, text and source line, and
   the source files those lines are in, as JSON in the page, which a script
   shows as a function list, the disassembly with its source lines, the
   source file, and the function's bytes. Selecting an instruction marks
   its line and its bytes; selecting a line marks every instruction it
   compiled to; a branch target opens its function. The runtime's
   functions are on the page with `--all`. A page for a 13,000-instruction
   program with the runtime is 1.2 MB.
7. **ELF**, then x86-64 through Capstone. ELF done (`elf.goose`):
   executables, shared objects and relocatable objects, for arm64 and
   x86-64, with the build ID, the DWARF the file carries, and for an
   object its sections laid out and its debug relocations applied as a
   linker would; arm64 disassembly in the generic syntax. Its line tables
   agree with dwarfdump at every row of three objects (4,560 rows). Not
   done: compressed debug sections, and x86-64 decoding, which waits on
   Capstone.
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
