// Shared test bootstrap. Resolves a TypeScript compiler without a machine-specific
// path and transpiles one .ets file to CommonJS.
//
// Tests used to hardcode the macOS DevEco bundle
// (/Applications/DevEco-Studio.app/.../typescript/lib/typescript.js), so every
// suite failed to load on Windows. Resolution order:
//   argv[2] > $MINIPC_TYPESCRIPT > a local node_modules copy > the DevEco
//   command-line-tools and DevEco Studio layouts that ship with HarmonyOS tooling.
//
// Each test still builds its own `vm` context: the mocked @kit imports differ per
// suite, and keeping runInNewContext in the test's own realm avoids cross-realm
// identity surprises in assert.deepEqual / instanceof checks.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const TS_RELATIVE = path.join('node_modules', 'typescript', 'lib', 'typescript.js');

function candidatePaths() {
  const home = os.homedir();
  const programFiles = process.env['ProgramFiles'] || 'C:\\Program Files';
  const programFilesX86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
  const roots = [];
  for (const dir of ['command-line-tools', 'DevEco Studio', 'DevEco-Studio.app']) {
    roots.push(path.join('D:', dir));
    roots.push(path.join('C:', dir));
    roots.push(path.join(programFiles, 'Huawei', dir));
    roots.push(path.join(programFilesX86, 'Huawei', dir));
    roots.push(path.join(home, dir));
    roots.push(path.join('/Applications', dir));
  }
  for (const dir of ['.ohpm', 'ohpm']) roots.push(path.join(home, dir));
  // A DevEco install nests the bundled ohpm inside the root and under tools/.
  const paths = [];
  for (const root of roots) {
    paths.push(path.join(root, TS_RELATIVE));
    paths.push(path.join(root, 'tools', 'ohpm', TS_RELATIVE));
    paths.push(path.join(root, 'Contents', 'tools', 'ohpm', TS_RELATIVE));
    paths.push(path.join(root, 'ohpm', TS_RELATIVE));
    paths.push(path.join(root, 'hvigor', 'hvigor', TS_RELATIVE));
  }
  return paths;
}

function resolveTypeScript() {
  const explicit = process.argv[2] || process.env['MINIPC_TYPESCRIPT'];
  if (explicit) {
    if (!fs.existsSync(explicit)) {
      throw new Error('TypeScript not found at ' + explicit + ' (pass argv[2] or set MINIPC_TYPESCRIPT)');
    }
    return explicit;
  }
  // A locally installed copy wins, so `npm i -D typescript` makes the suite portable.
  let dir = __dirname;
  for (let depth = 0; depth < 6; depth++) {
    const local = path.join(dir, TS_RELATIVE);
    if (fs.existsSync(local)) return local;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  for (const candidate of candidatePaths()) {
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error('No TypeScript compiler found. Run `npm i -D typescript`, or pass the path to ' +
    'typescript/lib/typescript.js as argv[2] or in MINIPC_TYPESCRIPT.');
}

let cached = null;

function typescript() {
  if (cached === null) cached = require(resolveTypeScript());
  return cached;
}

function compile(source) {
  const ts = typescript();
  return ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
}

/** Transpile `file` (an .ets source path) to ES2021 CommonJS text. */
function transpile(file) {
  return compile(fs.readFileSync(file, 'utf8'));
}

module.exports = { transpile, transpileSource: compile, resolveTypeScript, typescript };
