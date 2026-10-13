'use strict';

const path = require('node:path');
const { execFile } = require('node:child_process');
const { argumentsFor } = require('./config');

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
            if (caret) {
                // Lexer carets count UTF-8 bytes, preserving tabs as single characters.
                current.column = Buffer.from(lines[i + 1], 'utf8')
                    .subarray(0, caret[0].indexOf('^')).toString('utf8').length;
            }
            diagnostics.push(current);
        } else {
            const frame = /^\s+in (.+) instantiated from (.+):(\d+)$/.exec(lines[i]);
            if (frame && current) current.related.push({
                message: `Instantiated ${frame[1]}`, file: path.resolve(cwd, frame[2]),
                line: Math.max(0, Number(frame[3]) - 1)
            });
        }
    }
    return diagnostics;
}

// What a check reports on its own progress, never an error's text.
const progress = /^(?:parsed ok|typechecked ok|roundtrip ok|bce|bce-line|bce-test):/;

// A check's diagnostics. A failed check with no located error (a file that
// cannot be opened, a missing compiler, a timeout, or any error the compiler
// prints without a file:line: prefix) becomes an error on the checked file,
// at its first line, so that it is never silent; no position is invented in
// an import.
function checkDiagnostics({ config, error, output = '' }) {
    const parsed = parseDiagnostics(output, config.cwd);
    if (!error || parsed.some(item => item.severity === 'error')) return parsed;
    const text = output.replace(/\x1b\[[0-9;]*m/g, '').split(/\r?\n/)
        .filter(line => line.trim() && !progress.test(line)).join('\n').trim();
    const message = error.code === 'ENOENT'
        ? `Goose compiler not found: ${config.compiler}. Set goose.compilerPath to the executable.`
        : error.killed ? `Goose check exceeded ${config.timeout} ms or was terminated.`
        : text || error.message;
    return [...parsed, { file: config.file, line: 0, severity: 'error', message, related: [] }];
}

function runCompiler(config) {
    let child;
    const promise = new Promise(resolve => {
        child = execFile(config.compiler, argumentsFor('check', config), {
            cwd: config.cwd, timeout: config.timeout, maxBuffer: 8 * 1024 * 1024,
            encoding: 'utf8', windowsHide: true, shell: false
        }, (error, stdout, stderr) => resolve({ error, output: [stdout, stderr].filter(Boolean).join('\n') }));
    });
    return { promise, cancel: () => child.kill() };
}

// Own results per checked entry file: clearing one root must not erase another's
// errors in a shared import. A generation token prevents late checks resurfacing.
class CheckQueue {
    constructor(check, changed) {
        this.check = check;
        this.changed = changed;
        this.jobs = new Map();
        this.results = new Map();
    }

    invalidate(cwd) {
        for (const [key, job] of this.jobs) {
            if (!cwd || job.config.cwd === cwd) {
                clearTimeout(job.timer);
                job.run?.cancel();
                job.finish(false);
                this.jobs.delete(key);
            }
        }
        for (const [key, result] of this.results) {
            if (!cwd || result.config.cwd === cwd) this.results.delete(key);
        }
        this.changed(this.results);
    }

    schedule(config, delay = 180) {
        const key = config.file;
        const old = this.jobs.get(key);
        if (old) {
            clearTimeout(old.timer);
            old.run?.cancel();
            old.finish(false);
        }
        this.results.delete(key);
        this.changed(this.results);
        return new Promise(finish => {
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
    }
}

module.exports = { parseDiagnostics, checkDiagnostics, runCompiler, CheckQueue };
