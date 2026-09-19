#!/usr/bin/env node
/**
 * my-oc-harness — installer engine. Pure Node ESM, stdlib only, ZERO dependencies.
 *
 * Subcommands / flags:
 *   setup                 full install (default when no args)
 *   --dry-run             print the install manifest, touch nothing
 *   --ci                  refuse to mutate: print the manifest, exit 0
 *   setup --uninstall     delete exactly the manifest-listed files, keep
 *                         user-modified ones, print the backup restore path
 *   --fleet               also register the oc-freedom-fleet plugin
 *
 * Exit codes are strictly 0 (ok / clean abort) or 1 (failure).
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  cpSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync,
  rmSync, statSync, writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline/promises';

const PKG_NAME = 'my-oc-harness';
const PKG_ROOT = path.resolve(import.meta.dirname, '..');
const MANIFEST_FILE = 'my-oc-harness.manifest.json';
const COPY_DIRS = ['agents', 'commands', 'skills', 'reference', 'scripts'];
const COPY_FILES = ['AGENTS.md'];
const MERGE_KEYS = ['model', 'providers', 'mcp', 'plugins'];
const LINT_PATTERNS = ['c:\\users', 'q:\\', 'nathan', 'ses_', '.secrets'];

/* ------------------------------ tiny helpers ------------------------------ */

function log(label, msg) {
  console.log(`[${label}] ${msg}`);
}

function usage() {
  console.log(`my-oc-harness — install the OpenCode harness into your config dir.

usage:
  my-oc-harness setup                full install (default: no args needed)
  my-oc-harness --dry-run            print the manifest only; touch nothing
  my-oc-harness --ci                 print-only, refuse to mutate, exit 0
  my-oc-harness setup --uninstall    remove exactly the manifest-listed files
  my-oc-harness setup --fleet        also register plugin oc-freedom-fleet`);
}

class Bail extends Error {}
function bail(msg) {
  console.error(`[error] ${msg}`);
  throw new Bail(msg);
}

function sha256(buf) {
  return createHash('sha256').update(buf).digest('hex');
}
const sha256File = (p) => sha256(readFileSync(p));
const sha256Text = (s) => sha256(Buffer.from(s, 'utf8'));

function tsStamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function pkgVersion() {
  try {
    return JSON.parse(readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8')).version || '0.0.0';
  } catch {
    return '0.0.0';
  }
}

/**
 * Run a CLI. On Windows, npm-installed commands are .cmd shims that
 * CreateProcess cannot launch directly — retry through cmd.exe on ENOENT.
 */
function exec(name, args = [], capture = false) {
  const opts = {
    encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
    windowsHide: true,
  };
  try {
    const res1 = spawnSync(name, args, opts);
    if (!res1.error) return res1;
    if (res1.error.code !== 'ENOENT') return res1;
    if (process.platform === 'win32') {
      const comspec = process.env.ComSpec || 'cmd.exe';
      const res2 = spawnSync(comspec, ['/d', '/s', '/c', name, ...args], opts);
      if (!res2.error) return res2;
    }
    return res1;
  } catch (err) {
    return { error: err, status: null, stdout: '', stderr: '' };
  }
}

/* ------------------------- preflight / config discovery -------------------- */

function preflight() {
  const res = exec('opencode', ['--version'], true);
  if (res.error || res.status !== 0) {
    bail(
      'OpenCode CLI is required but not runnable (' +
        (res.error ? 'not found on PATH' : `exited ${res.status}`) +
        '). Install/upgrade OpenCode first, then re-run setup.'
    );
  }
  const first = (res.stdout || '').trim().split(/\r?\n/)[0] || 'unknown version';
  log('preflight', `opencode ${first} — OK`);
}

function findConfigDir() {
  const res = exec('opencode', ['debug', 'paths'], true);
  if (!res.error && res.status === 0) {
    const m = (res.stdout || '').match(/^config\s*[=:]?\s*(.+)$/m);
    if (m) {
      let dir = m[1].trim().replace(/^["']|["']$/g, '');
      if (dir.startsWith('~') && (dir[1] === '/' || dir[1] === '\\')) {
        dir = path.join(homedir(), dir.slice(2));
      }
      if (dir) {
        log('config', `resolved via 'opencode debug paths': ${dir}`);
        return dir;
      }
    }
  } else {
    log('config', 'opencode debug paths unavailable — falling back to the environment chain');
  }
  const env = process.env;
  if (env.OPENCODE_CONFIG_DIR) {
    log('config', `env OPENCODE_CONFIG_DIR: ${env.OPENCODE_CONFIG_DIR}`);
    return env.OPENCODE_CONFIG_DIR;
  }
  if (env.XDG_CONFIG_HOME) {
    const p = path.join(env.XDG_CONFIG_HOME, 'opencode');
    log('config', `XDG_CONFIG_HOME fallback: ${p}`);
    return p;
  }
  if (process.platform === 'win32' && env.USERPROFILE) {
    const p = path.join(env.USERPROFILE, '.config', 'opencode');
    log('config', `%USERPROFILE% fallback: ${p}`);
    return p;
  }
  if (env.HOME) {
    const p = path.join(env.HOME, '.config', 'opencode');
    log('config', `$HOME fallback: ${p}`);
    return p;
  }
  const home = homedir();
  if (home) {
    const p = path.join(home, '.config', 'opencode');
    log('config', `os.homedir() fallback: ${p}`);
    return p;
  }
  bail('could not determine the OpenCode config dir. Set OPENCODE_CONFIG_DIR and re-run.');
}

/* --------------------------- package tree collection ----------------------- */

function walkDir(dir, onFile) {
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walkDir(p, onFile);
    else onFile(p);
  }
}

function collectIncoming(configDir) {
  const files = [];
  for (const dirName of COPY_DIRS) {
    const srcDir = path.join(PKG_ROOT, dirName);
    if (!existsSync(srcDir) || !statSync(srcDir).isDirectory()) {
      log('staging', `note: ${dirName}/ not present in this package — nothing to copy from it`);
      continue;
    }
    walkDir(srcDir, (p) =>
      files.push({
        rel: path.relative(PKG_ROOT, p),
        src: p,
        dest: path.join(configDir, path.relative(PKG_ROOT, p)),
      })
    );
  }
  for (const f of COPY_FILES) {
    const src = path.join(PKG_ROOT, f);
    if (!existsSync(src)) {
      log('staging', `note: ${f} not present in this package — nothing to copy`);
      continue;
    }
    files.push({ rel: f, src, dest: path.join(configDir, f) });
  }
  return files;
}

/* -------------------------------- backup ----------------------------------- */

function makeBackup(configDir) {
  const backupPath = `${configDir}.bak-my-oc-harness-${tsStamp()}`;
  if (existsSync(configDir)) {
    if (!statSync(configDir).isDirectory()) {
      bail(`${configDir} exists but is not a directory — refusing to install over it`);
    }
    cpSync(configDir, backupPath, { recursive: true });
    log('backup', `copied ${configDir} → ${backupPath}`);
  } else {
    log('backup', `no config dir at ${configDir} yet — will create it (nothing to back up)`);
  }
  return backupPath;
}

/* ------------------------------ staged copy -------------------------------- */

function stageFiles(files, manifest) {
  let written = 0;
  for (const f of files) {
    const srcHash = sha256File(f.src);
    let action = 'written';
    if (existsSync(f.dest)) {
      if (sha256File(f.dest) === srcHash) {
        action = 'skip';
        log('staging', `skip   ${f.rel} (already identical — rerun-safe)`);
      } else {
        log('staging', `update ${f.rel} (destination differs — overwriting; backup + manifest protect you)`);
      }
    } else {
      log('staging', `copy   ${f.rel}`);
    }
    if (action === 'written') {
      mkdirSync(path.dirname(f.dest), { recursive: true });
      const tmp = `${f.dest}.my-oc-harness-tmp-${process.pid}`;
      writeFileSync(tmp, readFileSync(f.src));
      rmSync(f.dest, { force: true }); // Windows rename() cannot overwrite
      renameSync(tmp, f.dest);
      written += 1;
    }
    manifest.files.push({ path: f.rel, hash: srcHash, action });
  }
  return written;
}

/* ---------------------------- opencode.jsonc merge ------------------------- */

function stripJsonc(text) {
  let out = '';
  let inStr = false;
  let esc = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      out += c;
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') {
      inStr = true;
      out += c;
      continue;
    }
    if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      out += '\n';
      continue;
    }
    if (c === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++;
      i++;
      continue;
    }
    out += c;
  }
  return out;
}

function dropTrailingCommas(text) {
  let out = '';
  let inStr = false;
  let esc = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      out += c;
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') {
      inStr = true;
      out += c;
      continue;
    }
    if (c === ',') {
      let j = i + 1;
      while (j < text.length && /\s/.test(text[j])) j++;
      if (text[j] === '}' || text[j] === ']') continue; // trailing comma
    }
    out += c;
  }
  return out;
}

function parseJsonc(text, what) {
  try {
    return JSON.parse(dropTrailingCommas(stripJsonc(text)));
  } catch (err) {
    bail(`${what} is not valid JSONC: ${err.message}`);
  }
}

function describeKey(k, v) {
  if (k === 'model') return `model "${v}"`;
  if (Array.isArray(v)) return `${k} (${v.length} entr${v.length === 1 ? 'y' : 'ies'})`;
  if (v && typeof v === 'object') {
    const n = Object.keys(v).length;
    return `${k} (${n} entr${n === 1 ? 'y' : 'ies'})`;
  }
  return `${k} (${JSON.stringify(v)})`;
}

function mergeJsonc(configDir, backupPath, manifest) {
  const distroPath = path.join(PKG_ROOT, 'opencode.jsonc');
  const userPath = path.join(configDir, 'opencode.jsonc');
  if (!existsSync(distroPath)) {
    log('merge', 'note: this package ships no opencode.jsonc — no merge to do');
    return;
  }
  const merged = parseJsonc(
    readFileSync(distroPath, 'utf8'),
    `the shipped opencode.jsonc (this package build looks broken)`
  );
  const kept = [];
  if (existsSync(userPath)) {
    const user = parseJsonc(
      readFileSync(userPath, 'utf8'),
      `your existing opencode.jsonc — aborting before any write; your config is untouched (backup: ${backupPath})`
    );
    for (const k of MERGE_KEYS) {
      if (user[k] !== undefined) {
        merged[k] = user[k];
        kept.push(describeKey(k, user[k]));
      } else {
        log('merge', `opencode.jsonc: no ${k} in your config — harness default stays`);
      }
    }
    log('merge', `kept your ${kept.join(', ') || '(nothing — harness defaults only)'}`);
  } else {
    log('merge', 'no existing opencode.jsonc — writing the harness base');
  }
  const out = `${JSON.stringify(merged, null, 2)}\n`;
  mkdirSync(configDir, { recursive: true });
  const tmp = `${userPath}.my-oc-harness-tmp-${process.pid}`;
  writeFileSync(tmp, out);
  rmSync(userPath, { force: true });
  renameSync(tmp, userPath);
  manifest.files.push({ path: 'opencode.jsonc', hash: sha256Text(out), action: 'merged' });
  log('merge', `rewrote ${userPath} (distro base with permissions/deny, skill allowlist, default_agent "master", references; your model/providers/mcp/plugins re-injected)`);
}

/* ------------------------------ placeholder lint --------------------------- */

function lintCopiedFiles(files) {
  const hits = [];
  for (const f of files) {
    if (!existsSync(f.dest)) continue;
    const low = readFileSync(f.dest, 'utf8').toLowerCase();
    for (const pat of LINT_PATTERNS) {
      if (low.includes(pat)) {
        hits.push({ file: f.rel, pattern: pat });
        break;
      }
    }
  }
  return hits;
}

/* ------------------------------- plugin gate ------------------------------- */

function registerPlugins(fleet) {
  const list = ['oc-flight-deck', ...(fleet ? ['oc-freedom-fleet'] : [])];
  for (const p of list) {
    log('plugin', `opencode plugin add ${p}`);
    const res = exec('opencode', ['plugin', 'add', p], false);
    if (res.error || res.status !== 0) {
      log(
        'plugin',
        `'opencode plugin add ${p}' failed (${res.error ? 'not found' : `exit ${res.status}`}) — add it manually later; the config is already installed`
      );
    } else {
      log('plugin', `${p} registered`);
    }
  }
  return list;
}

/* --------------------------------- doctor ---------------------------------- */

function doctorPlan() {
  const probe = exec('pwsh', ['-NoProfile', '-Command', 'exit 0'], true);
  return probe.error || probe.status !== 0
    ? 'pwsh missing — doctor skipped, install note printed'
    : 'run scripts/harness-doctor.ps1 via pwsh';
}

function runDoctor(configDir) {
  const probe = exec('pwsh', ['-NoProfile', '-Command', 'exit 0'], true);
  if (probe.error || probe.status !== 0) {
    log('doctor', 'pwsh is not on PATH — /doctor cannot run here. Config still lands.');
    console.log('  PowerShell 7 is optional here but powers /doctor — install:');
    console.log('    winget install --id Microsoft.PowerShell --source winget   (Windows)');
    console.log('    brew install --cask powershell                             (macOS)');
    return 0;
  }
  const script = path.join(configDir, 'scripts', 'harness-doctor.ps1');
  if (!existsSync(script)) {
    log('doctor', `note: ${script} not found — doctor skipped`);
    return 0;
  }
  log('doctor', `running ${script}`);
  const res = exec('pwsh', ['-NoProfile', '-File', script], false);
  if (res.error || res.status !== 0) {
    log(
      'doctor',
      `harness-doctor exited ${res.error ? 'with an error' : `${res.status}`} — fix the issue, then re-run setup (idempotent)`
    );
    return 1;
  }
  log('doctor', 'harness-doctor passed');
  return 0;
}

/* --------------------------- manifest print (gate) ------------------------- */

function printManifest(configDir, files, backupPath, fleet, doctor) {
  const newCount = files.filter((f) => !existsSync(f.dest)).length;
  const sameCount = files.length - newCount;
  console.log('----------------------------- install manifest -----------------------------');
  console.log(`  destination config dir : ${configDir}`);
  console.log(`  incoming files         : ${files.length} (${newCount} new, ${sameCount} already identical — rerun-safe)`);
  console.log(`  backup path            : ${backupPath}`);
  console.log('  opencode.jsonc merge   : distro base (permissions/deny block, skill allowlist,');
  console.log('                            default_agent: "master", references registry)');
  console.log(`                            + your keys re-injected: ${MERGE_KEYS.join(', ')}`);
  console.log(`  plugin registration    : oc-flight-deck${fleet ? ' + oc-freedom-fleet' : ''} (via 'opencode plugin add')`);
  console.log(`  doctor plan            : ${doctor}`);
  console.log('----------------------------------------------------------------------------');
}

async function confirmProceed() {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  let answer = '';
  try {
    answer = (await rl.question('Type y to continue (anything else aborts; nothing is touched): ')).trim().toLowerCase();
  } catch {
    answer = ''; // stdin closed (EOF) — treat as abort
  } finally {
    rl.close();
  }
  return answer === 'y' || answer === 'yes';
}

/* -------------------------------- uninstall -------------------------------- */

function uninstall(configDir) {
  const manifestPath = path.join(configDir, MANIFEST_FILE);
  if (!existsSync(manifestPath)) {
    bail(
      `no ${MANIFEST_FILE} found in ${configDir} — nothing to uninstall (an install may already have been removed, or the config dir moved).`
    );
  }
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (err) {
    bail(`could not read ${manifestPath}: ${err.message} — inspect it manually before touching anything.`);
  }
  const base = path.resolve(configDir);
  const files = Array.isArray(manifest.files) ? manifest.files : [];
  if (!files.length) bail(`manifest at ${manifestPath} lists no files — refusing a blind cleanup.`);
  let removed = 0;
  let kept = 0;
  let missing = 0;
  for (const entry of files) {
    const rel = String(entry.path || '');
    const resolved = path.resolve(base, rel);
    if (resolved !== base && !resolved.startsWith(base + path.sep)) {
      log('uninstall', `skip   ${rel} (escapes the config dir — refusing)`);
      continue;
    }
    if (!existsSync(resolved)) {
      missing += 1;
      continue;
    }
    if (entry.hash && sha256File(resolved) === entry.hash) {
      rmSync(resolved, { force: true });
      removed += 1;
      log('uninstall', `removed ${rel}`);
    } else {
      kept += 1;
      log('uninstall', `kept   ${rel} (you modified it — hash differs)`);
    }
  }
  rmSync(manifestPath, { force: true });
  log('uninstall', `removed ${removed}, kept ${kept} modified, already-missing ${missing}`);
  console.log(`  backup (pre-install config dir): ${manifest.backupPath || '(none recorded)'}`);
  console.log('  to restore it fully, replace the current config dir with that backup.');
  if (Array.isArray(manifest.plugins) && manifest.plugins.length) {
    console.log(
      `  plugins left registered: ${manifest.plugins.join(', ')} — remove with 'opencode plugin remove <name>' if unwanted.`
    );
  }
}

/* ---------------------------------- setup ---------------------------------- */

function writeManifest(configDir, manifest) {
  mkdirSync(configDir, { recursive: true });
  writeFileSync(path.join(configDir, MANIFEST_FILE), `${JSON.stringify(manifest, null, 2)}\n`);
}

async function setup(opts) {
  preflight();
  const configDir = findConfigDir();
  const files = collectIncoming(configDir);
  const backupPath = `${configDir}.bak-my-oc-harness-${tsStamp()}`;
  const doctor = doctorPlan(); // read-only probe
  printManifest(configDir, files, backupPath, opts.fleet, doctor);

  if (opts.dryRun) {
    console.log('[dry-run] manifest only — nothing was touched.');
    return 0;
  }
  if (opts.ci) {
    console.log('[ci] refusing to mutate — print-only. Run setup interactively to install.');
    return 0;
  }
  if (!(await confirmProceed())) {
    console.log('[gate] aborted — nothing was modified.');
    return 0;
  }

  /* ---------------- mutations begin (all journaled) ---------------- */
  const backup = makeBackup(configDir);
  const manifest = {
    package: PKG_NAME,
    version: pkgVersion(),
    created: new Date().toISOString(),
    configDir,
    backupPath: backup,
    plugins: ['oc-flight-deck', ...(opts.fleet ? ['oc-freedom-fleet'] : [])],
    files: [],
  };

  stageFiles(files, manifest);
  mergeJsonc(configDir, backup, manifest);

  const hits = lintCopiedFiles(files);
  if (hits.length) {
    // Journal first — uninstall must know exactly what landed.
    writeManifest(configDir, manifest);
    for (const h of hits) console.error(`[lint] placeholder pattern "${h.pattern}" found in ${h.file}`);
    bail(
      `placeholder data found in the shipped tree (${hits.length} file(s) listed above) — this package build is corrupted; stop and reinstall from npm. Restore your config from: ${backup}`
    );
  }

  writeManifest(configDir, manifest);
  log('manifest', `journal written: ${path.join(configDir, MANIFEST_FILE)}`);

  registerPlugins(opts.fleet);
  const doctorOk = runDoctor(configDir);
  if (doctorOk !== 0) return 1;

  console.log();
  console.log('-------------------------------- summary ---------------------------------');
  console.log('  installed: agents/, commands/, skills/, reference/, scripts/, AGENTS.md + merged opencode.jsonc');
  console.log(`  plugins  : oc-flight-deck${opts.fleet ? ', oc-freedom-fleet' : ''}`);
  console.log(`  backup   : ${backup}`);
  console.log('  undo     : npx my-oc-harness setup --uninstall');
  console.log('  restart  : restart your OpenCode session so the new agents/commands/skills load.');
  console.log('----------------------------------------------------------------------------');
  return 0;
}

/* --------------------------------- entry ---------------------------------- */

function parseArgs(argv) {
  const opts = { command: 'setup', dryRun: false, ci: false, uninstall: false, fleet: false };
  for (const a of argv) {
    switch (a) {
      case 'setup':
        opts.command = 'setup';
        break;
      case '--dry-run':
        opts.dryRun = true;
        break;
      case '--ci':
        opts.ci = true;
        break;
      case '--uninstall':
        opts.uninstall = true;
        break;
      case '--fleet':
        opts.fleet = true;
        break;
      case '--help':
      case '-h':
        usage();
        process.exitCode = 0;
        return null;
      default:
        usage();
        bail(`unknown argument: ${a}`);
        return null;
    }
  }
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!opts) return;
  if (opts.uninstall) {
    const configDir = findConfigDir();
    uninstall(configDir);
    return;
  }
  const code = await setup(opts);
  if (code !== 0) process.exitCode = code;
}

main().catch((err) => {
  if (!(err instanceof Bail)) console.error(`[fatal] ${err && err.stack ? err.stack : err}`);
  process.exitCode = 1;
});