'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');
const { parseDiagnostics, parseJsonDiagnostics, failureMessage, runCompiler, CheckQueue } = require('../src/diagnostics');

test('lexer carets, warnings, explicit columns and related instantiations', () => {
    const cwd = path.resolve('workspace');
    const result = parseDiagnostics(`module.goose:3: error: expected expression\r\n\tlet x = ;\r\n\t        ^\r\n  in fn f(i64) instantiated from main.goose:9\r\nmain.goose:11: warning: unused value\r\nmain.goose:12:4: error: explicit column`, cwd);
    assert.equal(result.length, 3);
    assert.deepEqual(result[0], {
        file: path.join(cwd, 'module.goose'), line: 2, column: 9, severity: 'error', message: 'expected expression',
        related: [{ file: path.join(cwd, 'main.goose'), line: 8, message: 'Instantiated fn f(i64)' }]
    });
    assert.equal(result[1].column, undefined);
    assert.equal(result[1].severity, 'warning');
    assert.equal(result[2].column, 3);
});

test('Windows drive letters, spaces and colons in error messages are preserved', () => {
    const filename = 'C:\\source dir\\module.goose';
    const result = parseDiagnostics(`${filename}:17: error: expected type: i64\n  in fn nested() instantiated from ${filename}:2`, process.cwd());
    assert.equal(result[0].file, path.resolve(filename));
    assert.equal(result[0].line, 16);
    assert.equal(result[0].message, 'expected type: i64');
    assert.equal(result[0].related[0].line, 1);
});

test('UTF-8 byte carets become UTF-16 editor columns', () => {
    const prefix = '\tprint("é😀"); ';
    const source = prefix + 'bad;';
    const caret = '\t' + ' '.repeat(Buffer.byteLength(prefix) - 1) + '^';
    const [item] = parseDiagnostics(`test.goose:1: error: bad\n${source}\n${caret}`, process.cwd());
    assert.equal(item.column, prefix.length);
});

test('unlocated compiler failures do not become fabricated parsed errors', () => {
    assert.deepEqual(parseDiagnostics('cannot open file: missing.goose\ntypechecked ok: 2 specialization(s)', process.cwd()), []);
});

test('JSON diagnostics: ranges, instantiation calls, warnings, lines alone, and no fabricated unlocated errors', async () => {
    const cwd = path.resolve('workspace');
    const file = path.join(cwd, 'chain.goose');
    const sources = { 'chain.goose': [
        'fn get<T>(a: T) -> i64 { a.nope }', '', 'fn main() {', '    let x = get(1);', '    let y: i64 = 1;',
        '    let z = y as i64;', '    print(x + z);', '}', ''
    ] };
    const result = await parseJsonDiagnostics([
        {
            severity: 'error', message: 'no field access on a value of type i64', file: 'chain.goose', line: 1, col: 26, endLine: 1, endCol: 32,
            related: [
                { message: 'in fn get(literal i64) instantiated from chain.goose:4', file: 'chain.goose', line: 4, col: 13 },
                { message: 'in fn main() instantiated from chain.goose:3', file: 'chain.goose', line: 3, col: 1 },
                { message: 'in the const for expansion of x' }
            ],
            text: 'chain.goose:1: error: no field access on a value of type i64\nfn get<T>(a: T) -> i64 { a.nope }\n  in fn get(literal i64) instantiated from chain.goose:4\n  in fn main() instantiated from chain.goose:3'
        },
        { severity: 'warning', message: 'redundant `as i64`: y is already i64', file: 'chain.goose', line: 6, col: 13, endLine: 6, endCol: 21, text: 'chain.goose:6: warning: redundant `as i64`: y is already i64' },
        { severity: 'error', message: 'f keeps a bounds check', file: 'chain.goose', line: 7, col: 11, text: 'chain.goose:7: error: f keeps a bounds check' },
        { severity: 'error', message: 'expected a declaration', file: 'chain.goose', line: 8, text: 'chain.goose:8: error: expected a declaration' },
        { severity: 'error', message: 'cannot open file: missing.goose', text: 'cannot open file: missing.goose' }
    ], cwd, (file, line) => sources[path.basename(file)]?.[line]);
    assert.equal(result.length, 4);
    assert.deepEqual(result[0], {
        file, line: 0, column: 25, endLine: 0, endColumn: 31, severity: 'error', message: 'no field access on a value of type i64',
        related: [{ file, line: 3, column: 12, message: 'Instantiated fn get(literal i64)' }, { file, line: 2, column: 0, message: 'Instantiated fn main()' }]
    });
    assert.deepEqual(result[1], { file, line: 5, column: 12, endLine: 5, endColumn: 20, severity: 'warning', message: 'redundant `as i64`: y is already i64', related: [] });
    assert.deepEqual(result[2], { file, line: 6, column: 10, severity: 'error', message: 'f keeps a bounds check', related: [] });
    assert.deepEqual(result[3], { file, line: 7, column: undefined, severity: 'error', message: 'expected a declaration', related: [] });
});

test('JSON byte columns become UTF-16 editor columns, on the end line and at related calls too', async () => {
    const prefix = '\tprint("é😀"); ';
    const lines = [prefix + 'bad(', '  "ü", worse);'];
    const bytes = text => Buffer.byteLength(text);
    const [item] = await parseJsonDiagnostics([{
        severity: 'error', message: 'bad', file: 'test.goose', line: 1, col: bytes(prefix) + 1, endLine: 2, endCol: bytes('  "ü", worse') + 1,
        related: [{ message: 'in fn f() instantiated from test.goose:2', file: 'test.goose', line: 2, col: bytes('  "ü", ') + 1 }],
        text: `test.goose:1: error: bad\n${lines[0]}`
    }], process.cwd(), (file, line) => lines[line]);
    assert.equal(item.column, prefix.length);
    assert.deepEqual([item.endLine, item.endColumn], [1, '  "ü", worse'.length]);
    assert.deepEqual([item.related[0].line, item.related[0].column], [1, '  "ü", '.length]);
    const [unknown] = await parseJsonDiagnostics([{ severity: 'error', message: 'bad', file: 'gone.goose', line: 3, col: 5, endLine: 3, endCol: 9, text: '' }], process.cwd(), () => undefined);
    assert.deepEqual([unknown.column, unknown.endColumn], [4, 8], 'a line the sources do not have keeps the compiler column');
});

// A stand-in for execFile: respond(args) gives a run's error, stdout and stderr.
function fakeCompiler(respond) {
    const calls = [];
    const spawn = (file, args, options, callback) => {
        calls.push(args);
        const { error = null, stdout = '', stderr = '' } = respond(args);
        setImmediate(() => callback(error, stdout, stderr));
        return { kill() {} };
    };
    return { calls, spawn };
}
const failed = Object.assign(new Error('Command failed'), { code: 1 });
const fakeConfig = (name, stdlib = '') => ({ compiler: path.resolve('fake', name), cwd: path.resolve('fake'), file: 'main.goose', stdlib, timeout: 1000 });

test('a compiler without --diagnostics json is probed once, then checked in text mode', async () => {
    const config = fakeConfig('old-goose');
    const old = fakeCompiler(args => args.includes('--diagnostics')
        ? { error: failed, stderr: 'unknown option: --diagnostics\n' }
        : { error: failed, stdout: 'parsed ok: 1 top-level declarations, 1 file(s)\n', stderr: 'main.goose:1: error: bad\n' });
    const result = await runCompiler(config, old.spawn).promise;
    assert.deepEqual(old.calls, [['check', '--diagnostics', 'json', 'main.goose'], ['check', 'main.goose']]);
    assert.equal(result.error, failed);
    assert.equal(result.diagnostics, undefined);
    assert.deepEqual(result.args, ['check', 'main.goose']);
    assert.equal(result.output, 'parsed ok: 1 top-level declarations, 1 file(s)\n\nmain.goose:1: error: bad\n');
    assert.equal(parseDiagnostics(result.output, config.cwd)[0].file, path.join(config.cwd, 'main.goose'));
    await runCompiler(config, old.spawn).promise;
    assert.deepEqual(old.calls.slice(2), [['check', 'main.goose']], 'the flag is not probed again');
});

test('a compiler with --diagnostics json gives the diagnostics as data, and their text as the output', async () => {
    const config = fakeConfig('new-goose', path.resolve('fake', 'stdlib'));
    const modern = fakeCompiler(() => ({
        error: failed, stderr: 'parsed ok: 1 top-level declarations, 1 file(s)\n',
        stdout: '[\n  {"severity": "error", "message": "bad", "file": "main.goose", "line": 1, "col": 1, "endLine": 1, "endCol": 4, "text": "main.goose:1: error: bad\\nbad\\n^"}\n]\n'
    }));
    const result = await runCompiler(config, modern.spawn).promise;
    assert.deepEqual(modern.calls, [['check', '--diagnostics', 'json', '--stdlib', config.stdlib, 'main.goose']]);
    assert.equal(result.error, failed);
    assert.deepEqual(result.args, modern.calls[0]);
    assert.equal(result.diagnostics.length, 1);
    assert.equal(result.diagnostics[0].endCol, 4);
    assert.equal(result.output, 'parsed ok: 1 top-level declarations, 1 file(s)\nmain.goose:1: error: bad\nbad\n^');
    const unlocated = fakeCompiler(() => ({ error: failed, stdout: '[\n  {"severity": "error", "message": "cannot open file: main.goose", "text": "cannot open file: main.goose"}\n]\n' }));
    const missing = await runCompiler(fakeConfig('new-goose'), unlocated.spawn).promise;
    assert.deepEqual(await parseJsonDiagnostics(missing.diagnostics, config.cwd, () => undefined), []);
    assert.equal(failureMessage(missing.output), 'cannot open file: main.goose');
});

test('a check that did not run, or failed without rejecting the flag, is not remembered as text-only', async () => {
    const notFound = Object.assign(new Error('spawn ENOENT'), { code: 'ENOENT' });
    const absent = fakeCompiler(() => ({ error: notFound }));
    const result = await runCompiler(fakeConfig('no-goose'), absent.spawn).promise;
    assert.equal(result.error, notFound);
    assert.equal(absent.calls.length, 1, 'a compiler that is not found is not run again in text mode');
    const crashing = fakeCompiler(() => ({ error: failed, stderr: 'assertion failed\n' }));
    for (let i = 0; i < 2; i++) await runCompiler(fakeConfig('crashing-goose'), crashing.spawn).promise;
    assert.deepEqual(crashing.calls.map(args => args.length), [4, 2, 4, 2], 'each check probes the flag again, then runs in text mode');
});

function deferredRunner() {
    const calls = [];
    return {
        calls,
        run(config) {
            let resolve;
            const promise = new Promise(done => { resolve = done; });
            const call = { config, resolve, cancelled: false };
            calls.push(call);
            return { promise, cancel() { call.cancelled = true; } };
        }
    };
}
const tick = () => new Promise(resolve => setTimeout(resolve, 10));

test('checks discard late results after an edit, and cancel superseded checks', async () => {
    const runner = deferredRunner();
    const queue = new CheckQueue(config => runner.run(config), () => {});
    const config = { file: 'main.goose', cwd: '/project' };
    const first = queue.schedule(config, 0);
    await tick();
    queue.invalidate(config.cwd);
    assert.equal(runner.calls[0].cancelled, true);
    assert.equal(await first, false);
    runner.calls[0].resolve({ output: 'old error' });
    await tick();
    assert.equal(queue.results.size, 0);
    const second = queue.schedule(config, 0);
    await tick();
    const third = queue.schedule(config, 0);
    await tick();
    runner.calls[1].resolve({ output: 'superseded error' });
    runner.calls[2].resolve({ output: 'new output' });
    assert.equal(await second, false);
    assert.equal(await third, true);
    assert.equal(queue.results.get(config.file).output, 'new output');
    queue.invalidate();
});

test('roots have separate results and workspace invalidation is scoped', async () => {
    const queue = new CheckQueue(config => ({ promise: Promise.resolve({ output: config.file }), cancel() {} }), () => {});
    await queue.schedule({ file: 'a.goose', cwd: '/one' }, 0);
    await queue.schedule({ file: 'b.goose', cwd: '/two' }, 0);
    await queue.schedule({ file: 'c.goose', cwd: '/two' }, 0);
    queue.invalidate('/one');
    assert.deepEqual([...queue.results.keys()], ['b.goose', 'c.goose']);
    queue.invalidate();
});

test('edits keep results stale per workspace until a recheck replaces them', async () => {
    const runner = deferredRunner();
    let notified = 0;
    const queue = new CheckQueue(config => runner.run(config), () => { notified++; });
    const a = { file: 'a.goose', cwd: '/one' }, b = { file: 'b.goose', cwd: '/two' };
    const first = [queue.schedule(a, 0), queue.schedule(b, 0)];
    await tick();
    runner.calls[0].resolve({ output: 'a error' });
    runner.calls[1].resolve({ output: 'b ok' });
    await Promise.all(first);
    queue.stale('/one');
    const before = notified;
    queue.stale('/one');
    assert.equal(notified, before, 'further edits change nothing');
    assert.equal(queue.results.get('a.goose').stale, true);
    assert.equal(queue.results.get('b.goose').stale, undefined, 'another workspace stays current');
    const again = queue.schedule(a, 0);
    await tick();
    assert.equal(queue.results.get('a.goose').output, 'a error', 'a recheck keeps the stale result until it lands');
    queue.stale('/one');
    assert.equal(runner.calls[2].cancelled, true);
    assert.equal(await again, false);
    assert.equal(queue.results.get('a.goose').output, 'a error');
    const last = queue.schedule(a, 0);
    await tick();
    runner.calls[3].resolve({ output: 'a ok' });
    assert.equal(await last, true);
    assert.equal(queue.results.get('a.goose').stale, undefined);
    assert.equal(queue.results.get('a.goose').output, 'a ok');
    queue.invalidate();
});

test('results of entries no longer checked are dropped', async () => {
    let notified = 0;
    const queue = new CheckQueue(config => ({ promise: Promise.resolve({ output: config.file }), cancel() {} }), () => { notified++; });
    await queue.schedule({ file: 'a.goose', cwd: '/one' }, 0);
    await queue.schedule({ file: 'b.goose', cwd: '/one' }, 0);
    queue.stale('/one');
    queue.retain(file => file === 'b.goose');
    assert.deepEqual([...queue.results.keys()], ['b.goose']);
    const before = notified;
    queue.retain(file => file === 'b.goose');
    assert.equal(notified, before);
    queue.invalidate();
    assert.equal(queue.results.size, 0);
});

test('synchronous launch failures are surfaced and pending timers cancel cleanly', async () => {
    const queue = new CheckQueue(() => { throw new Error('launch failure'); }, () => {});
    await queue.schedule({ file: 'a.goose', cwd: '/one' }, 0);
    assert.match(queue.results.get('a.goose').error.message, /launch failure/);
    const pending = queue.schedule({ file: 'a.goose', cwd: '/one' }, 1000);
    queue.invalidate();
    assert.equal(await pending, false);
});

test('unlocated failures drop the compiler progress lines', () => {
    assert.equal(failureMessage('parsed ok: 50 top-level declarations, 3 file(s)\nprogram needs exactly one global fn main()\n'),
        'program needs exactly one global fn main()');
    assert.equal(failureMessage('parsed ok: 1 top-level declarations, 1 file(s)\n'), '');
    assert.equal(failureMessage('cannot open file: x.goose\n'), 'cannot open file: x.goose');
    assert.equal(failureMessage('typechecked ok: 1 specialization(s)\nbce: elided 0/0 index and 0/0 slice checks\nwrote a.c (12 bytes)\nbroken'), 'broken');
});
