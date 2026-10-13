'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { imports } = require('./language');

function expand(value, folder, file) {
    return value.replace(/\$\{workspaceFolder\}/g, () => folder)
        .replace(/\$\{file\}/g, () => file);
}

function absolute(value, folder, file) {
    return path.resolve(folder, expand(value, folder, file));
}

function compilerPath(configured, folder) {
    if (configured) {
        const expanded = expand(configured, folder, '');
        return /[\\/]/.test(expanded) ? path.resolve(folder, expanded) : expanded;
    }
    const name = process.platform === 'win32' ? 'goose.exe' : 'goose';
    for (const relative of [name, `build/Release/${name}`, `build/Debug/${name}`, `build/${name}`]) {
        const candidate = path.join(folder, relative);
        if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
    }
    return 'goose';
}

// Whether `root`, compiled as the program's root file, loads `target`: what it
// imports, and what those import in turn, as ParseProgram in src/main.cpp
// resolves them (`import .a.b;` from the importing file's directory, `import
// a.b;` from the root's). Only files of the module's own directory
// (`<dir>/<name>/` beside `<dir>/<name>.goose`) are followed.
function loads(root, target, read) {
    const moduleDir = root.slice(0, -'.goose'.length) + path.sep;
    const queue = [root];
    const seen = new Set(queue);
    while (queue.length && seen.size < 512) {
        const file = queue.shift();
        let source;
        try { source = read(file); } catch { continue; }
        for (const item of imports(source)) {
            const imported = path.join(item.relative ? path.dirname(file) : path.dirname(root), ...item.parts) + '.goose';
            if (imported === target) return true;
            if (imported.startsWith(moduleDir) && !seen.has(imported)) {
                seen.add(imported);
                queue.push(imported);
            }
        }
    }
    return false;
}

// A file of a module split across several, `<dir>/<name>/<part>.goose`, does
// not check alone: it uses what the other parts declare. Its module's root
// file, `<dir>/<name>.goose`, imports the parts and stands for it, and the
// compiler checks a root without `fn main()`. A root that is itself a part of
// a module one directory up stands for that one's root in turn.
function moduleRoot(file, read = name => fs.readFileSync(name, 'utf8')) {
    let current = path.resolve(file);
    for (let depth = 0; depth < 32; depth++) {
        const dir = path.dirname(current);
        if (path.dirname(dir) === dir) break;
        const root = `${dir}.goose`;
        if (!loads(root, current, read)) break;
        current = root;
    }
    return current;
}

function folderOf(vscode, uri, taskFolder) {
    const workspaceFolder = taskFolder || vscode.workspace.getWorkspaceFolder(uri);
    return { workspaceFolder, cwd: workspaceFolder ? workspaceFolder.uri.fsPath : path.dirname(uri.fsPath) };
}

function settings(vscode, uri, definition = {}, taskFolder, read) {
    const { workspaceFolder, cwd } = folderOf(vscode, uri, taskFolder);
    const config = vscode.workspace.getConfiguration('goose', taskFolder?.uri || uri);
    const explicit = definition.file || config.get('entryFile', '');
    let file = absolute(explicit || uri.fsPath, cwd, uri.fsPath);
    // Checking the open file of a module checks the module (moduleRoot).
    // Running or generating C keeps to the file asked for.
    if (!explicit && (definition.action || 'check') === 'check') file = moduleRoot(file, read);
    return {
        workspaceFolder, cwd, file,
        compiler: compilerPath(config.get('compilerPath', ''), cwd),
        stdlib: config.get('stdlibPath', '') ? absolute(config.get('stdlibPath'), cwd, uri.fsPath) : '',
        timeout: Math.min(300000, Math.max(1000, config.get('checkTimeout', 15000))),
        checkOnSave: config.get('checkOnSave', true),
        runArguments: config.get('runArguments', []),
        output: definition.output ? absolute(definition.output, cwd, file) : file.replace(/(?:\.goose)?$/, '.c')
    };
}

function argumentsFor(action, config) {
    // `goose check` and `goose build` are verbs, which come first; the rest are flags.
    const args = action === 'build' || action === 'check' ? [action] : [];
    if (config.stdlib) args.push('--stdlib', config.stdlib);
    if (action === 'run') args.push('--jit');
    else if (action === 'generateC') args.push('-o', config.output);
    else if (action !== 'build' && action !== 'check') throw new Error(`Unknown Goose task action: ${action}`);
    args.push(config.file);
    if (action === 'run' && config.runArguments.length) args.push('--', ...config.runArguments);
    return args;
}

// Mirror StdlibDirs in src/main.cpp, including lookup next to a PATH executable.
function stdlibDirectories(config, env = process.env) {
    let executable = config.compiler;
    if (!path.isAbsolute(executable)) {
        const names = process.platform === 'win32' && !path.extname(executable)
            ? [`${executable}.exe`, executable] : [executable];
        executable = (env.PATH || '').split(path.delimiter)
            .flatMap(dir => names.map(name => path.resolve(dir, name)))
            .find(candidate => fs.existsSync(candidate)) || '';
    }
    const dirs = [config.stdlib, env.GOOSE_STDLIB].filter(Boolean)
        .map(dir => path.resolve(config.cwd, dir));
    if (executable) {
        for (let i = 0; i < 4; i++) {
            dirs.push(path.resolve(path.dirname(executable), ...Array(i).fill('..'), 'stdlib'));
        }
    }
    dirs.push(path.join(config.cwd, 'stdlib'));
    return [...new Set(dirs)];
}

module.exports = { absolute, compilerPath, folderOf, moduleRoot, settings, argumentsFor, stdlibDirectories };
