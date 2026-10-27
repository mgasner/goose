// The page `inspect html` writes (docs/design/inspect.md §4.2): one file,
// no server, the program's functions, instructions, bytes and source as
// JSON in it and a script that shows them side by side. Selecting an
// instruction marks its source line and its bytes; selecting a source line
// marks every instruction it compiled to.
namespace html;

// Appends s as a JSON string. `</` is written `<\/`, so that no string in
// the data can end the script element it is in.
fn json_string(out: u8[>..]&, s: const u8[:]) {
    out.push('"');
    for c, i in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == '\r' { out.append("\\r"); }
        else if c < 0x20 { out.append("\\u00"); out.push("0123456789abcdef"[c >> 4]); out.push("0123456789abcdef"[c & 15]); }
        else if c == '/' && i > 0 && s[i - 1] == '<' { out.append("\\/"); }
        else { out.push(c); }
    }
    out.push('"');
}

// What comes before the data, and after it.
let HEAD = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Goose Inspect</title>
    <style>
    :root {
      --bg: #fbfbfa; --panel: #ffffff; --ink: #1d1f22; --muted: #6b7078; --line: #e3e4e6;
      --sel: #fff1b8; --rel: #e7f0ff; --accent: #1f6feb; --src: #f4f5f6; --unk: #b42318;
      color-scheme: light dark;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg: #131416; --panel: #1b1d20; --ink: #e6e7e9; --muted: #9096a0; --line: #2c2f34;
        --sel: #4a3f12; --rel: #1d2b44; --accent: #6ea8fe; --src: #202327; --unk: #ff8a80;
      }
    }
    :root[data-theme="dark"] {
      --bg: #131416; --panel: #1b1d20; --ink: #e6e7e9; --muted: #9096a0; --line: #2c2f34;
      --sel: #4a3f12; --rel: #1d2b44; --accent: #6ea8fe; --src: #202327; --unk: #ff8a80;
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--ink);
           font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    header { padding: 10px 16px; border-bottom: 1px solid var(--line); display: flex; gap: 16px;
             align-items: baseline; flex-wrap: wrap; }
    header h1 { font-size: 15px; margin: 0; }
    header .meta { color: var(--muted); }
    main { display: grid; grid-template-columns: 260px minmax(0, 1.3fr) minmax(0, 1fr);
           grid-template-rows: minmax(0, 1fr) 190px; height: calc(100vh - 44px); }
    @media (max-width: 900px) {
      main { grid-template-columns: 1fr; grid-template-rows: 200px 50vh 40vh 190px; height: auto; }
    }
    section { overflow: auto; border-right: 1px solid var(--line); background: var(--panel); min-width: 0; }
    #fns { grid-row: 1 / 3; }
    #hexp { grid-column: 2 / 4; border-top: 1px solid var(--line); }
    @media (max-width: 900px) { #fns, #hexp { grid-row: auto; grid-column: auto; } }
    .head { position: sticky; top: 0; background: var(--panel); padding: 6px 10px;
            border-bottom: 1px solid var(--line); color: var(--muted); z-index: 1; }
    input { width: 100%; font: inherit; padding: 4px 6px; color: var(--ink); background: var(--bg);
            border: 1px solid var(--line); border-radius: 4px; }
    .fn { padding: 2px 10px; cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .fn:hover { background: var(--rel); }
    .fn.on { background: var(--sel); }
    .fn .k { color: var(--muted); }
    table { border-collapse: collapse; width: 100%; }
    td { padding: 0 8px; white-space: pre; vertical-align: top; }
    tr.i { cursor: pointer; }
    tr.i:hover td { background: var(--rel); }
    tr.i td.a, tr.i td.w { color: var(--muted); }
    tr.s td { background: var(--src); color: var(--muted); padding-top: 3px; cursor: pointer; }
    tr.on td, .sl.on, .b.on { background: var(--sel) !important; }
    tr.rel td, .sl.rel { background: var(--rel); }
    td.u { color: var(--unk); }
    a { color: var(--accent); text-decoration: none; }
    .sl { padding: 0 8px; white-space: pre; cursor: pointer; }
    .sl .n { color: var(--muted); display: inline-block; width: 4em; text-align: right; margin-right: 1em; }
    .sl.code .n { color: var(--accent); }
    .hx { padding: 4px 10px; white-space: pre; }
    .b.rel { background: var(--rel); }
    .empty { padding: 12px; color: var(--muted); }
    </style>
    </head>
    <body>
    <header><h1 id="title">inspect</h1><span class="meta" id="meta"></span></header>
    <main>
    <section id="fns"><div class="head"><input id="filter" placeholder="filter functions"></div><div id="fnlist"></div></section>
    <section id="dis"><div class="head" id="dishead">select a function</div><table id="distab"></table></section>
    <section id="src"><div class="head" id="srchead">source</div><div id="srcbody"></div></section>
    <section id="hexp"><div class="head" id="hexhead">bytes</div><div id="hexbody" class="hx"></div></section>
    </main>
    <script id="data" type="application/json">
    """;

let TAIL = """
    </script>
    <script>
    "use strict";
    const D = JSON.parse(document.getElementById("data").textContent);
    const $ = id => document.getElementById(id);
    const hex = (v, w) => v.toString(16).padStart(w || 0, "0");
    const byAddr = new Map();  // function index by start address
    D.functions.forEach((f, i) => byAddr.set(f.start, i));
    $("title").textContent = D.exe;
    $("meta").textContent = `${D.arch}, ${D.functions.length} functions` + (D.lines ? "" : ", no line information");
    let cur = -1, selIns = -1, selLine = null;

    function fnAt(a) {
      // The function whose range holds a, for branch targets.
      let lo = 0, hi = D.functions.length;
      while (lo < hi) { const m = (lo + hi) >> 1; if (D.functions[m].start <= a) lo = m + 1; else hi = m; }
      const i = lo - 1;
      return i >= 0 && a < D.functions[i].end ? i : -1;
    }
    function listFns() {
      const q = $("filter").value.toLowerCase();
      const out = [];
      D.functions.forEach((f, i) => {
        if (q && !f.name.toLowerCase().includes(q) && !f.c.toLowerCase().includes(q)) return;
        out.push(`<div class="fn${i === cur ? " on" : ""}" data-i="${i}">${esc(f.name)} <span class="k">${f.kind === "goose" ? "" : f.kind === "other" ? "C" : f.kind}</span></div>`);
      });
      $("fnlist").innerHTML = out.join("") || `<div class="empty">no match</div>`;
    }
    function esc(s) { return s.replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c])); }
    function lineKey(file, line) { return file + ":" + line; }

    function showFn(i, keepSel) {
      cur = i;
      const f = D.functions[i];
      if (!keepSel) { selIns = -1; selLine = null; }
      $("dishead").textContent = `${f.name}  ${f.c !== f.name ? "(" + f.c + ")  " : ""}0x${hex(f.start)}, ${f.end - f.start} bytes`;
      const rows = [];
      let last = null;
      f.insns.forEach((ins, k) => {
        const [off, word, text, file, line, target] = ins;
        if (file >= 0 && line > 0 && lineKey(file, line) !== last) {
          last = lineKey(file, line);
          const t = (D.files[file].lines[line - 1] || "").trim();
          rows.push(`<tr class="s" data-f="${file}" data-l="${line}"><td colspan="3">${esc(D.files[file].name)}:${line}  ${esc(t)}</td></tr>`);
        }
        let body = esc(text);
        if (target) {
          const j = fnAt(target);
          if (j >= 0) {
            const fj = D.functions[j];
            const lab = fj.name + (target !== fj.start ? "+0x" + hex(target - fj.start) : "");
            body += `  <a href="#" data-go="${j}" data-at="${target}">&lt;${esc(lab)}&gt;</a>`;
          }
        }
        const unk = text.startsWith(".word");
        rows.push(`<tr class="i" data-k="${k}"><td class="a">${hex(f.start + off)}</td><td class="w">${hex(word, 8)}</td><td${unk ? ' class="u"' : ""}>${body}</td></tr>`);
      });
      $("distab").innerHTML = rows.join("");
      listFns();
      showHex();
      mark();
    }
    function showSource(file, line) {
      if (file < 0) { $("srchead").textContent = "source"; $("srcbody").innerHTML = `<div class="empty">no line</div>`; return; }
      const F = D.files[file];
      $("srchead").textContent = F.path;
      if (!F.lines.length) { $("srcbody").innerHTML = `<div class="empty">the file was not there when the page was made</div>`; return; }
      const withCode = new Set();
      if (cur >= 0) for (const ins of D.functions[cur].insns) if (ins[3] === file) withCode.add(ins[4]);
      $("srcbody").innerHTML = F.lines.map((t, n) =>
        `<div class="sl${withCode.has(n + 1) ? " code" : ""}" data-f="${file}" data-l="${n + 1}"><span class="n">${n + 1}</span>${esc(t)}</div>`).join("");
      const el = $("srcbody").querySelector(`[data-l="${line}"]`);
      if (el) el.scrollIntoView({block: "center"});
    }
    function showHex() {
      const f = D.functions[cur];
      const rows = [];
      for (let r = 0; r < f.insns.length; r += 4) {
        const cells = [];
        for (let k = r; k < Math.min(r + 4, f.insns.length); k++) {
          const w = f.insns[k][1];
          for (let b = 0; b < 4; b++) cells.push(`<span class="b" data-k="${k}">${hex((w >>> (8 * b)) & 255, 2)}</span>`);
        }
        rows.push(`${hex(f.start + f.insns[r][0])}  +${hex(f.fileoff + f.insns[r][0], 6)}  ${cells.join(" ")}`);
      }
      $("hexhead").textContent = `bytes of ${f.name}, as the file has them (little-endian words)`;
      $("hexbody").innerHTML = rows.join("\n");
    }
    function mark() {
      for (const el of document.querySelectorAll(".on, .rel")) if (!el.classList.contains("fn")) el.classList.remove("on", "rel");
      if (cur < 0) return;
      const f = D.functions[cur];
      f.insns.forEach((ins, k) => {
        const hit = k === selIns ? "on" : (selLine && ins[3] === selLine[0] && ins[4] === selLine[1]) ? "rel" : null;
        if (!hit) return;
        const tr = $("distab").querySelector(`tr.i[data-k="${k}"]`);
        if (tr) tr.classList.add(hit);
        for (const b of $("hexbody").querySelectorAll(`.b[data-k="${k}"]`)) b.classList.add(hit);
      });
      if (selLine) {
        const sl = $("srcbody").querySelector(`.sl[data-f="${selLine[0]}"][data-l="${selLine[1]}"]`);
        if (sl) sl.classList.add("on");
      }
    }
    function pickIns(k) {
      selIns = k;
      const ins = D.functions[cur].insns[k];
      selLine = ins[3] >= 0 && ins[4] > 0 ? [ins[3], ins[4]] : null;
      if (selLine) showSource(selLine[0], selLine[1]); else showSource(-1, 0);
      mark();
    }
    function pickLine(file, line) {
      selIns = -1;
      selLine = [file, line];
      const first = D.functions[cur].insns.findIndex(i => i[3] === file && i[4] === line);
      if (first >= 0) $("distab").querySelector(`tr.i[data-k="${first}"]`).scrollIntoView({block: "center"});
      mark();
    }
    $("filter").addEventListener("input", listFns);
    $("fnlist").addEventListener("click", e => { const d = e.target.closest(".fn"); if (d) { showFn(+d.dataset.i); const f = D.functions[cur]; const s = f.insns.find(i => i[3] >= 0 && i[4] > 0); showSource(s ? s[3] : -1, s ? s[4] : 0); } });
    $("distab").addEventListener("click", e => {
      const a = e.target.closest("a[data-go]");
      if (a) {
        e.preventDefault();
        const j = +a.dataset.go, at = +a.dataset.at;
        showFn(j);
        const k = D.functions[j].insns.findIndex(i => D.functions[j].start + i[0] === at);
        if (k >= 0) { pickIns(k); $("distab").querySelector(`tr.i[data-k="${k}"]`).scrollIntoView({block: "center"}); }
        return;
      }
      const tr = e.target.closest("tr");
      if (!tr) return;
      if (tr.classList.contains("i")) pickIns(+tr.dataset.k);
      else { showSource(+tr.dataset.f, +tr.dataset.l); pickLine(+tr.dataset.f, +tr.dataset.l); }
    });
    $("srcbody").addEventListener("click", e => { const d = e.target.closest(".sl"); if (d && cur >= 0) pickLine(+d.dataset.f, +d.dataset.l); });
    $("hexbody").addEventListener("click", e => { const b = e.target.closest(".b"); if (b) { pickIns(+b.dataset.k); $("distab").querySelector(`tr.i[data-k="${b.dataset.k}"]`).scrollIntoView({block: "center"}); } });
    listFns();
    const start = D.functions.findIndex(f => f.c === "main_g");
    if (start >= 0) { showFn(start); const s = D.functions[start].insns.find(i => i[3] >= 0 && i[4] > 0); showSource(s ? s[3] : -1, s ? s[4] : 0); }
    </script>
    </body>
    </html>
    """;
