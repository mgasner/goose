'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { argumentsFor } = require('./config');

// The compiler counts columns in UTF-8 bytes; the editor in UTF-16 units. The
// editor column of the character at byte offset bytes of line's text.
function utf16Column(line, bytes) {
    return Buffer.from(line, 'utf8').subarray(0, bytes).toString('utf8').length;
}

// An instantiation chain line, `in fn f(i64) instantiated from main.goose:9`,
// becomes a related location's message; the place is attached separately.
const instantiation = /^in (.+) instantiated from (.+):(\d+)$/;

// The errors and warnings in the text the compiler prints: one per
// `file:line[:col]: error|warning: message` line, with the caret line a lexer
// error puts under the source line, and the `in f instantiated from file:line`
// lines after a typecheck error as related locations. Lines are 0-based,
// columns 0-based UTF-16 editor columns, or undefined for a line alone.
function parseDiagnostics(output, cwd) {
    const lines = output.replace(/\x1b\[[0-9;]*m/g, '').split(/\r?\n/);
    const diagnostics = [];
    let current;
    for (let i = 0; i < lines.length; i++) {
        const match = /^(.+?):(\d+)(?::(\d+))?: (error|warning): (.*)$/.exec(lines[i]);
        if (match) {
            current = {
                file: path.resolve(cwd, match[1]), line: Math.max(0, Number(match[2]) - 1),
                column: match[3] ? Math.max(0, Number(match[3]) - 1) : undefined,
                severity: match[4], message: match[5], related: []
            };
            const caret = /^[\t ]*\^~*\s*$/.exec(lines[i + 2] || '');
            // Lexer carets count UTF-8 bytes, preserving tabs as single characters.
            if (caret) current.column = utf16Column(lines[i + 1], caret[0].indexOf('^'));
            diagnostics.push(current);
        } else {
            const frame = /^\s/.test(lines[i]) && instantiation.exec(lines[i].trimStart());
            if (frame && current) current.related.push({
                message: `Instantiated ${frame[1]}`, file: path.resolve(cwd, frame[2]),
                line: Math.max(0, Number(frame[3]) - 1)
            });
        }
    }
    return diagnostics;
}

// The lines of files on disk, by 0-based line, as parseJsonDiagnostics reads
// them when given no other source: undefined past the end or when unreadable.
function linesOnDisk() {
    const files = new Map();
    return async (file, line) => {
        if (!files.has(file)) files.set(file, fs.promises.readFile(file, 'utf8').then(text => text.split(/\r?\n/), () => []));
        return (await files.get(file))[line];
    };
}

// The diagnostics `goose check --diagnostics json` prints on stdout, an array
// with one object per error or warning (docs/implementation.md §1), given as
// parseDiagnostics gives the text's, with the range the compiler reports as
// endLine and endColumn (0-based, one past the last character) and related
// locations at their column (a related line that names no place is left
// out). Only diagnostics with a place in the program are items; one without
// (a file that cannot be opened) is reported through the output text alone,
// as in text mode. The compiler's byte columns are
// mapped to editor columns through sourceLine(file, line), the text of that
// 0-based line, or undefined where unknown, which keeps the byte column.
async function parseJsonDiagnostics(diagnostics, cwd, sourceLine = linesOnDisk()) {
    const column = async (file, line, bytes) => {
        const text = await sourceLine(file, line);
        return text === undefined ? bytes : utf16Column(text, bytes);
    };
    async function place(item) {
        if (typeof item.file !== 'string' || !Number.isInteger(item.line) || item.line < 1) return undefined;
        const file = path.resolve(cwd, item.file);
        const line = item.line - 1;
        const col = Number.isInteger(item.col) && item.col > 0 ? await column(file, line, item.col - 1) : undefined;
        return { file, line, column: col };
    }
    const items = [];
    for (const item of diagnostics) {
        if (!item || typeof item !== 'object') continue;
        const at = await place(item);
        if (!at) continue;
        const parsed = { ...at, severity: item.severity === 'warning' ? 'warning' : 'error', message: String(item.message ?? ''), related: [] };
        if (Number.isInteger(item.endLine) && item.endLine >= item.line && Number.isInteger(item.endCol) && item.endCol > 0) {
            parsed.endLine = item.endLine - 1;
            parsed.endColumn = await column(at.file, parsed.endLine, item.endCol - 1);
        }
        for (const frame of Array.isArray(item.related) ? item.related : []) {
            const where = frame && typeof frame === 'object' ? await place(frame) : undefined;
            if (!where) continue;
            const message = String(frame.message ?? '');
            const chain = instantiation.exec(message);
            parsed.related.push({ ...where, message: chain ? `Instantiated ${chain[1]}` : message });
        }
        items.push(parsed);
    }
    return items;
}

// Progress lines the compiler prints on success (parsed ok, typechecked ok, ...).
const statusLine = /^(?:parsed ok|roundtrip ok|typechecked ok|bce|bce-line|bce-test):|^wrote .+ \(\d+ bytes\)$/;

// The text of a failure that has no source location, without the progress lines.
function failureMessage(output) {
    return output.replace(/\x1b\[[0-9;]*m/g, '').split(/\r?\n/)
        .filter(line => !statusLine.test(line)).join('\n').trim();
}

// The JSON array on the stdout of a check run with --diagnostics json, or
// undefined when there is none: a compiler without the flag rejects it.
function jsonArray(stdout) {
    try {
        const parsed = JSON.parse(stdout);
        return Array.isArray(parsed) ? parsed : undefined;
    } catch {
        return undefined;
    }
}

// The compilers found to lack --diagnostics json, by path and build time, so
// that their checks run in text mode without a probe. A compiler rebuilt at
// the same path is probed again.
const withoutJson = new Set();

function compilerKey(compiler) {
    let built = '';
    try { built = String(fs.statSync(compiler).mtimeMs); } catch { /* A command on PATH, or missing: the path alone. */ }
    return `${compiler}\n${built}`;
}

// A check of config's entry file. Its result has the compiler's error, if
// any, the output as the text mode prints it (the progress lines, then the
// diagnostics), the arguments the check ran with and, from a compiler with
// --diagnostics json, the diagnostics as data. A compiler not known to lack
// the flag runs with it, and runs again in text mode when it printed no JSON
// array; one that rejects the flag is remembered.
function runCompiler(config, spawn = execFile) {
    let child, cancelled = false;
    const run = args => new Promise(resolve => {
        child = spawn(config.compiler, args, {
            cwd: config.cwd, timeout: config.timeout, maxBuffer: 8 * 1024 * 1024,
            encoding: 'utf8', windowsHide: true, shell: false
        }, (error, stdout, stderr) => resolve({ error, stdout, stderr, args }));
    });
    const textResult = ({ error, stdout, stderr, args }) => ({ error, output: [stdout, stderr].filter(Boolean).join('\n'), args });
    const promise = (async () => {
        const key = compilerKey(config.compiler);
        if (!withoutJson.has(key)) {
            const result = await run(argumentsFor('check', config, { diagnostics: 'json' }));
            const diagnostics = jsonArray(result.stdout);
            if (diagnostics) {
                const texts = diagnostics.map(item => item?.text).filter(text => typeof text === 'string');
                return { error: result.error, output: [result.stderr.trimEnd(), ...texts].filter(Boolean).join('\n'), args: result.args, diagnostics };
            }
            // A compiler that did not run (not found, timed out, cancelled)
            // would not in text mode either. One that complains about the flag
            // lacks it; any other failure is retried in text mode, which
            // reports it, and probed again next time.
            if (cancelled || result.error?.code === 'ENOENT' || result.error?.killed) return textResult(result);
            if (/--diagnostics/.test(result.stderr)) withoutJson.add(key);
        }
        return textResult(await run(argumentsFor('check', config)));
    })();
    return { promise, cancel: () => { cancelled = true; child?.kill(); } };
}

// Own results per checked entry file: clearing one root must not erase another's
// errors in a shared import. A generation token prevents late checks resurfacing.
// A result stays until the next check of its entry replaces it, marked stale
// once its sources change; one that no longer applies is dropped instead.
class CheckQueue {
    constructor(check, changed) {
        this.check = check;
        this.changed = changed;
        this.jobs = new Map();
        this.results = new Map();
    }

    cancel(key) {
        const job = this.jobs.get(key);
        if (!job) return false;
        clearTimeout(job.timer);
        job.run?.cancel();
        job.finish(false);
        this.jobs.delete(key);
        return true;
    }

    // The checks and results in cwd (or everywhere) no longer apply.
    invalidate(cwd) {
        for (const [key, job] of this.jobs) {
            if (!cwd || job.config.cwd === cwd) this.cancel(key);
        }
        for (const [key, result] of this.results) {
            if (!cwd || result.config.cwd === cwd) this.results.delete(key);
        }
        this.changed(this.results);
    }

    // Sources in cwd changed: stop its checks, and keep its results, marked
    // stale, for the next checks to replace.
    stale(cwd) {
        let changed = false;
        for (const [key, job] of this.jobs) {
            if (job.config.cwd === cwd) changed = this.cancel(key) || changed;
        }
        for (const result of this.results.values()) {
            if (result.config.cwd === cwd && !result.stale) result.stale = changed = true;
        }
        if (changed) this.changed(this.results);
    }

    // Drop the results of entry files that are no longer checked.
    retain(checked) {
        let changed = false;
        for (const key of this.results.keys()) {
            if (!checked(key)) changed = this.results.delete(key);
        }
        if (changed) this.changed(this.results);
    }

    schedule(config, delay = 180) {
        const key = config.file;
        this.cancel(key);
        const scheduled = new Promise(finish => {
            const job = { config, finish };
            this.jobs.set(key, job);
            job.timer = setTimeout(async () => {
                try {
                    job.startedAt = Date.now();
                    job.run = this.check(config);
                    const result = await job.run.promise;
                    if (this.jobs.get(key) !== job) return;
                    this.jobs.delete(key);
                    this.results.set(key, { config, startedAt: job.startedAt, ...result });
                    this.changed(this.results);
                    finish(true);
                } catch (error) {
                    if (this.jobs.get(key) !== job) return;
                    this.jobs.delete(key);
                    this.results.set(key, { config, startedAt: job.startedAt, error, output: '' });
                    this.changed(this.results);
                    finish(true);
                }
            }, delay);
        });
        // Report after the job is registered, so a listener can see it is running.
        this.changed(this.results);
        return scheduled;
    }
}

module.exports = { utf16Column, parseDiagnostics, parseJsonDiagnostics, failureMessage, runCompiler, CheckQueue };
