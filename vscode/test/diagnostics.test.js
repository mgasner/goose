'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');
const { parseDiagnostics, checkDiagnostics, CheckQueue } = require('../src/diagnostics');
const { moduleRoot } = require('../src/config');

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

test('synchronous launch failures are surfaced and pending timers cancel cleanly', async () => {
    const queue = new CheckQueue(() => { throw new Error('launch failure'); }, () => {});
    await queue.schedule({ file: 'a.goose', cwd: '/one' }, 0);
    assert.match(queue.results.get('a.goose').error.message, /launch failure/);
    const pending = queue.schedule({ file: 'a.goose', cwd: '/one' }, 1000);
    queue.invalidate();
    assert.equal(await pending, false);
});

test('a failed check with no located error is an error on the checked file, without progress lines', () => {
    const config = { file: path.resolve('lib.goose'), cwd: process.cwd(), compiler: 'goose', timeout: 1000 };
    const error = Object.assign(new Error('Command failed'), { code: 1 });
    assert.deepEqual(checkDiagnostics({ config, error, output: '\x1b[1mprogram needs exactly one global fn main()\x1b[0m\nparsed ok: 3 top-level declarations, 2 file(s)\n' }), [
        { file: config.file, line: 0, severity: 'error', message: 'program needs exactly one global fn main()', related: [] }
    ]);
    assert.equal(checkDiagnostics({ config, error, output: 'parsed ok: 1 top-level declarations, 1 file(s)' })[0].message, 'Command failed');
    const missing = checkDiagnostics({ config, error: Object.assign(new Error('spawn goose ENOENT'), { code: 'ENOENT' }), output: '' });
    assert.match(missing[0].message, /compiler not found/);
    assert.equal(checkDiagnostics({ config, error: Object.assign(new Error('killed'), { killed: true }) })[0].message, 'Goose check exceeded 1000 ms or was terminated.');
});

test('a located error or a successful check adds nothing', () => {
    const config = { file: path.resolve('lib.goose'), cwd: process.cwd() };
    const located = checkDiagnostics({ config, error: new Error('Command failed'), output: 'lib/part.goose:13: error: unknown type: Field\nparsed ok: 1' });
    assert.deepEqual(located.map(item => [item.file, item.line]), [[path.resolve('lib', 'part.goose'), 12]]);
    assert.deepEqual(checkDiagnostics({ config, error: null, output: 'parsed ok: 1\ntypechecked ok: 1' }), []);
});

test('two parts of one module share one check of its root', async () => {
    const files = {
        [path.resolve('/w/lib.goose')]: 'import .lib.a;\nimport .lib.b;\n',
        [path.resolve('/w/lib/a.goose')]: '', [path.resolve('/w/lib/b.goose')]: ''
    };
    const read = file => { if (!(file in files)) throw new Error('ENOENT'); return files[file]; };
    const runner = deferredRunner();
    const queue = new CheckQueue(config => runner.run(config), () => {});
    const first = queue.schedule({ file: moduleRoot('/w/lib/a.goose', read), cwd: '/w' }, 0);
    await tick();
    const second = queue.schedule({ file: moduleRoot('/w/lib/b.goose', read), cwd: '/w' }, 0);
    await tick();
    assert.equal(runner.calls.length, 2);
    assert.equal(runner.calls[0].cancelled, true);
    runner.calls[1].resolve({ output: 'root checked' });
    assert.equal(await first, false);
    assert.equal(await second, true);
    assert.deepEqual([...queue.results.keys()], [path.resolve('/w/lib.goose')]);
    queue.invalidate();
});
