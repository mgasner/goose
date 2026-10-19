'use strict';

const path = require('node:path');
const { execFile } = require('node:child_process');
const { compilerPath, absolute } = require('./config');

// Whether a compiler serves an editor: `goose lsp --probe` prints the
// protocol version it serves and exits with 0, where one without the verb
// fails on it. Resolves to the version, or undefined.
function probe(compiler, cwd, spawn = execFile) {
    return new Promise(resolve => {
        spawn(compiler, ['lsp', '--probe'], { cwd, timeout: 10000, windowsHide: true, encoding: 'utf8', shell: false },
            (error, stdout) => {
                const match = !error && /^goose lsp (\S+)/.exec(String(stdout || ''));
                resolve(match ? match[1] : undefined);
            });
    });
}

// What the server is started with: the compiler, working directory and
// standard library of the first workspace folder (or of the Goose file open
// without one), the entry files the folders configure, and whether the
// settings ask for a server at all. One server serves the window.
function serverSetup(vscode) {
    const folders = vscode.workspace.workspaceFolders || [];
    const first = folders[0];
    const isGoose = doc => doc.languageId === 'goose' && doc.uri.scheme === 'file';
    const active = vscode.window.activeTextEditor?.document;
    const doc = active && isGoose(active) ? active : vscode.workspace.textDocuments.find(isGoose);
    const cwd = first ? first.uri.fsPath : doc ? path.dirname(doc.uri.fsPath) : process.cwd();
    const config = vscode.workspace.getConfiguration('goose', first?.uri || doc?.uri);
    const stdlib = config.get('stdlibPath', '') ? absolute(config.get('stdlibPath'), cwd, '') : '';
    const entryFiles = folders.flatMap(folder => {
        const entry = vscode.workspace.getConfiguration('goose', folder.uri).get('entryFile', '');
        return entry ? [absolute(entry, folder.uri.fsPath, '')] : [];
    });
    return {
        enabled: config.get('useLanguageServer', true),
        compiler: compilerPath(config.get('compilerPath', ''), cwd),
        cwd, stdlib, entryFiles,
        args: ['lsp', ...(stdlib ? ['--stdlib', stdlib] : [])]
    };
}

// The extension's commands the server's code lenses may name: running a
// file, and listing a generic function's instantiations.
const CLIENT_COMMANDS = ['goose.run', 'goose.showInstantiations'];

// The client for a setup, through the language client library given (the
// `vscode-languageclient/node` module), logging to the output channel and
// telling the server of files changed on disk through the watcher.
function createClient(languageclient, setup, output, watcher) {
    const { LanguageClient, TransportKind } = languageclient;
    return new LanguageClient('goose', 'Goose Language Server',
        { command: setup.compiler, args: setup.args, transport: TransportKind.stdio, options: { cwd: setup.cwd } },
        {
            documentSelector: [{ language: 'goose', scheme: 'file' }],
            initializationOptions: { entryFiles: setup.entryFiles, stdlib: setup.stdlib, commands: CLIENT_COMMANDS },
            synchronize: { fileEvents: watcher },
            outputChannel: output,
            diagnosticCollectionName: 'goose-server'
        });
}

module.exports = { probe, serverSetup, createClient };
