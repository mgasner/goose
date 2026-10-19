'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { compilerPath } = require('../src/config');
const { probe } = require('../src/client');

const root = path.resolve(__dirname, '../..');
const compiler = process.env.GOOSE_TEST_COMPILER || compilerPath('', root);
const available = fs.existsSync(compiler);

// A file URI as VS Code spells one: the drive letter in lower case, and
// everything but unreserved characters escaped.
function uriOf(file) {
    const parts = path.resolve(file).replace(/\\/g, '/').replace(/^([A-Za-z]):/, (_, drive) => `${drive.toLowerCase()}:`).split('/');
    return 'file:///' + parts.map(encodeURIComponent).join('/').replace(/^\/+/, '');
}

// A client of the server's own protocol, without VS Code: messages framed
// by Content-Length on the server's pipes.
class Client {
    constructor(exe, cwd) {
        this.p = spawn(exe, ['lsp'], { cwd, windowsHide: true });
        this.buffer = Buffer.alloc(0);
        this.messages = [];
        this.waiters = [];
        this.stderr = '';
        this.seq = 0;
        this.p.stdout.on('data', chunk => {
            this.buffer = Buffer.concat([this.buffer, chunk]);
            this.drain();
        });
        this.p.stderr.on('data', chunk => { this.stderr += chunk; });
    }

    drain() {
        for (;;) {
            const end = this.buffer.indexOf('\r\n\r\n');
            if (end < 0) return;
            const length = Number(/Content-Length: (\d+)/.exec(this.buffer.subarray(0, end).toString())[1]);
            if (this.buffer.length < end + 4 + length) return;
            this.messages.push(JSON.parse(this.buffer.subarray(end + 4, end + 4 + length).toString('utf8')));
            this.buffer = this.buffer.subarray(end + 4 + length);
            for (const waiter of this.waiters.splice(0)) waiter();
        }
    }

    send(method, params, request = true) {
        const message = { jsonrpc: '2.0', method };
        if (params !== undefined) message.params = params;
        if (request) message.id = ++this.seq;
        const body = Buffer.from(JSON.stringify(message));
        this.p.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
        return message.id;
    }

    async wait(accept, timeout = 30000) {
        const deadline = Date.now() + timeout;
        for (;;) {
            const i = this.messages.findIndex(accept);
            if (i >= 0) return this.messages.splice(i, 1)[0];
            if (Date.now() > deadline) throw new Error(`no message accepted in ${timeout} ms; the server printed:\n${this.stderr}`);
            await new Promise(resolve => {
                this.waiters.push(resolve);
                setTimeout(resolve, 200);
            });
        }
    }

    async request(method, params) {
        const id = this.send(method, params);
        const reply = await this.wait(m => m.id === id);
        if (reply.error) throw new Error(`${method}: ${JSON.stringify(reply.error)}`);
        return reply.result;
    }

    diagnostics(uri, accept) {
        return this.wait(m => m.method === 'textDocument/publishDiagnostics' && m.params.uri.toLowerCase() === uri.toLowerCase() && accept(m.params.diagnostics))
            .then(m => m.params.diagnostics);
    }
}

test('the real language server publishes diagnostics as the text changes and answers a hover', async t => {
    if (!available) { t.skip('Build Goose or set GOOSE_TEST_COMPILER to run language server tests.'); return; }
    if (!await probe(compiler, root)) { t.skip(`${compiler} serves no language server (goose lsp --probe).`); return; }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goose vscode lsp '));
    const client = new Client(compiler, dir);
    try {
        const main = path.join(dir, 'main.goose');
        const text = '// Twice x.\nfn twice(x: i64) -> i64 { x * 2 }\nfn main() { print(twice(21)); }\n';
        fs.writeFileSync(main, text);
        const uri = uriOf(main);
        const capabilities = await client.request('initialize', { processId: process.pid, rootUri: uriOf(dir), capabilities: {}, initializationOptions: { entryFiles: [main], stdlib: '' } });
        assert.ok(capabilities.capabilities.hoverProvider);
        client.send('initialized', {}, false);
        client.send('textDocument/didOpen', { textDocument: { uri, languageId: 'goose', version: 1, text } }, false);
        assert.deepEqual(await client.diagnostics(uri, () => true), []);
        const hover = await client.request('textDocument/hover', { textDocument: { uri }, position: { line: 2, character: 18 } });
        assert.ok(hover.contents.value.includes('fn twice(x: i64) -> i64'), hover.contents.value);
        assert.ok(hover.contents.value.includes('Twice x.'), hover.contents.value);
        client.send('textDocument/didChange', { textDocument: { uri, version: 2 }, contentChanges: [{ text: text.replace('twice(21)', 'twice("s")') }] }, false);
        const errors = await client.diagnostics(uri, items => items.length > 0);
        assert.equal(errors.length, 1);
        assert.equal(errors[0].severity, 1);
        assert.equal(errors[0].range.start.line, 2);
        await client.request('shutdown', null);
        client.send('exit', undefined, false);
        const code = await new Promise(resolve => client.p.on('exit', resolve));
        assert.equal(code, 0, client.stderr);
    } finally {
        if (client.p.exitCode === null) {
            client.p.kill();
            await new Promise(resolve => client.p.on('exit', resolve));
        }
        fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    }
});
