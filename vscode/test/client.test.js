'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');
const { probe, serverSetup, createClient } = require('../src/client');

test('probe reads the protocol version a server prints, and nothing from a compiler without the verb', async () => {
    const spawn = (command, args, options, callback) => {
        assert.deepEqual(args, ['lsp', '--probe']);
        assert.equal(options.cwd, 'work');
        if (command === 'new') callback(null, 'goose lsp 3.17\n', '');
        else if (command === 'old') callback(Object.assign(new Error('exit 1'), { code: 1 }), '', 'goose: unknown option lsp\n');
        else callback(Object.assign(new Error('missing'), { code: 'ENOENT' }), '', '');
    };
    assert.equal(await probe('new', 'work', spawn), '3.17');
    assert.equal(await probe('old', 'work', spawn), undefined);
    assert.equal(await probe('none', 'work', spawn), undefined);
});

function fakeVscode({ folders, documents = [], active, values = new Map() }) {
    return {
        workspace: {
            workspaceFolders: folders,
            textDocuments: documents,
            getConfiguration(_section, uri) {
                const own = values.get(uri) || {};
                return { get: (key, dflt) => key in own ? own[key] : dflt };
            }
        },
        window: { activeTextEditor: active ? { document: active } : undefined }
    };
}

test('serverSetup takes the first folder\'s compiler and stdlib and every folder\'s entry file', () => {
    const a = { uri: { fsPath: path.resolve('a') } };
    const b = { uri: { fsPath: path.resolve('b') } };
    const values = new Map([
        [a.uri, { compilerPath: 'tools/goose', stdlibPath: '${workspaceFolder}/lib', entryFile: 'main.goose' }],
        [b.uri, { entryFile: 'src/app.goose' }]
    ]);
    const setup = serverSetup(fakeVscode({ folders: [a, b], values }));
    assert.equal(setup.enabled, true);
    assert.equal(setup.cwd, a.uri.fsPath);
    assert.equal(setup.compiler, path.resolve('a', 'tools/goose'));
    assert.equal(setup.stdlib, path.resolve('a', 'lib'));
    assert.deepEqual(setup.entryFiles, [path.resolve('a', 'main.goose'), path.resolve('b', 'src/app.goose')]);
    assert.deepEqual(setup.args, ['lsp', '--stdlib', path.resolve('a', 'lib')]);
});

test('without a folder, the open Goose file\'s directory is the working directory', () => {
    const doc = { languageId: 'goose', uri: { scheme: 'file', fsPath: path.resolve('one', 'prog.goose') } };
    const values = new Map([[doc.uri, { useLanguageServer: false }]]);
    const setup = serverSetup(fakeVscode({ folders: undefined, documents: [doc], active: doc, values }));
    assert.equal(setup.cwd, path.resolve('one'));
    assert.equal(setup.enabled, false);
    assert.deepEqual(setup.entryFiles, []);
    assert.deepEqual(setup.args, ['lsp']);
    assert.equal(setup.compiler, 'goose');
});

test('createClient starts goose lsp on stdio with the entry files and the commands lenses may name as initialization options', () => {
    let seen;
    class LanguageClient {
        constructor(id, name, server, client) { seen = { id, name, server, client }; }
    }
    const output = { name: 'Goose' };
    const watcher = { kind: 'watcher' };
    const setup = { compiler: 'C:/t/goose.exe', args: ['lsp'], cwd: 'C:/w', entryFiles: ['C:/w/main.goose'], stdlib: '' };
    createClient({ LanguageClient, TransportKind: { stdio: 'stdio' } }, setup, output, watcher);
    assert.equal(seen.id, 'goose');
    assert.deepEqual(seen.server, { command: 'C:/t/goose.exe', args: ['lsp'], transport: 'stdio', options: { cwd: 'C:/w' } });
    assert.deepEqual(seen.client.documentSelector, [{ language: 'goose', scheme: 'file' }]);
    assert.deepEqual(seen.client.initializationOptions, { entryFiles: ['C:/w/main.goose'], stdlib: '', commands: ['goose.run', 'goose.showInstantiations'] });
    assert.equal(seen.client.outputChannel, output);
    assert.equal(seen.client.synchronize.fileEvents, watcher);
});
