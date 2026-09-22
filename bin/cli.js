#!/usr/bin/env node
/**
 * oc-harness-setup — installer engine. Pure Node ESM, stdlib only, ZERO dependencies.
 *
 * Subcommands / flags:
 *   setup                 full install (default when no args)
 *   --dry-run             print the install manifest, touch nothing
 *   --ci                  refuse to mutate: print the manifest, exit 0
 *   setup --uninstall     delete exactly the manifest-listed files, keep
 *                         user-modified ones, print the backup restore path
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

const PKG_NAME = 'oc-harness-setup';
const PKG_ROOT = path.resolve(import.meta.dirname, '..');
const MANIFEST_FILE = 'oc-harness-setup.manifest.json';
const COPY_DIRS = ['agents', 'commands', 'skills', 'reference', 'scripts', '.docs'];
const COPY_FILES = ['AGENTS.md', '.gitignore'];
// Ownership table for the opencode.jsonc merge. Every top-level key falls into
// exactly one bucket; there is no "known merge key" list to drift out of date.
//   INSTALL_OWNED — the distro's value wins outright (runtime policy).
//   UNION_KEYS    — arrays unioned + deduped (distro entries first).
//   'references'  — object union: distro keys + user-only keys.
//   'permissions' — ordered union: harness allow/ask rules first, then the
//                   adopter's rules, then the harness's hard DENIES last. Under
//                   last-match-wins this lets an adopter's deny beat a harness
//                   allow while nothing can shadow a harness deny. The `skill`
//                   wildcard deny is exempt from the move (its fail-closed
//                   allowlist is deny-then-allows; see mergeJsonc).
//   everything else (known or unknown) — the adopter's value wins; the distro
//                   value stays when the adopter does not define the key.
const INSTALL_OWNED = ['$schema', 'default_agent', 'compaction', 'tool_output', 'media', 'watcher'];
const UNION_KEYS = ['plugins'];
// Adopter-owned files: shipped copies are skeletons, so an existing destination
// that differs MUST survive an upgrade — overwriting it destroys their data.
const PRESERVE_IF_EXISTS = new Set(['reference/models.md', 'AGENTS.md', '.gitignore']);
// Author-leak markers — they catch the MAINTAINER's machine leaking into the
// shipped tree (paths, username, session ids). They are linted against the
// package source only, never the adopter's config, so a legitimate
// `{file:~/.secrets/…}` apiKey pointer can never abort an install.
//
// Every marker is anchored to the AUTHOR's CONCRETE machine — drive `Q:`, user
// `nathan`, a real `ses_<id>` — never to the product's own vocabulary. The
// harness's safety tooling legitimately ships the generic forms
// (`C:\Users\<name>`, `ses_<id>`, `~/.secrets/…` — redactor regexes and their
// self-test probes), so a bare generic token would abort every correct install.
// A leak of an author path into a secret store is caught by the username/drive
// markers; a bare `.secrets` cannot distinguish product from author and so is
// deliberately not a marker. `nathan` also subsumes `C:\Users\nathan`.
const LINT_PATTERNS = [
  { label: 'q:\\', test: /q:\\/ },
  { label: 'nathan', test: /nathan/ },
  { label: 'ses_<id>', test: /ses_[a-z0-9]{16,}/ },
];

/* ------------------------------ tiny helpers ------------------------------ */

function log(label, msg) {
  console.log(`[${label}] ${msg}`);
}

// Never reuse a taken path when preserving bytes: copying onto an existing file
// would destroy the very copy we are trying to keep.
function nextFreePath(base) {
  if (!existsSync(base)) return base;
  for (let i = 2; ; i++) {
    const p = `${base}-${i}`;
    if (!existsSync(p)) return p;
  }
}

function usage() {
  console.log(`oc-harness-setup — install the OpenCode harness into your config dir.

usage:
  oc-harness-setup setup                full install (default: no args needed)
  oc-harness-setup --dry-run            print the manifest only; touch nothing
  oc-harness-setup --ci                 print-only, refuse to mutate, exit 0
  oc-harness-setup setup --uninstall    remove exactly the manifest-listed files`);
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

function makeBackup(configDir, backupPath) {
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

// A second-resolution stamp can repeat on a fast re-run. If that path already
// exists it may be the PRESERVED ORIGINAL snapshot, and cpSync into an existing
// dir would overwrite pristine bytes — so never reuse a taken path.
function nextBackupPath(configDir) {
  const stamp = tsStamp();
  let p = `${configDir}.bak-oc-harness-setup-${stamp}`;
  for (let i = 2; existsSync(p); i++) p = `${configDir}.bak-oc-harness-setup-${stamp}-${i}`;
  return p;
}

/* ------------------------------ staged copy -------------------------------- */

function stageFiles(files, manifest) {
  let written = 0;
  for (const f of files) {
    const srcHash = sha256File(f.src);
    let action = 'written';
    let prevHash = null;
    if (existsSync(f.dest)) {
      const destHash = sha256File(f.dest);
      if (destHash === srcHash) {
        action = 'skip';
        log('staging', `skip   ${f.rel} (already identical — rerun-safe)`);
      } else if (PRESERVE_IF_EXISTS.has(f.rel)) {
        action = 'preserved';
        log('staging', `preserve ${f.rel} (exists and differs — kept; harness will not overwrite adopter-owned files)`);
      } else {
        // A genuine overwrite: journal it so --uninstall can put the original
        // back from the pre-install backup instead of deleting the harness copy.
        action = 'overwritten';
        prevHash = destHash;
        log('staging', `update ${f.rel} (destination differs — overwriting; backup + manifest protect you)`);
      }
    } else {
      log('staging', `copy   ${f.rel}`);
    }
    if (action === 'written' || action === 'overwritten') {
      mkdirSync(path.dirname(f.dest), { recursive: true });
      const tmp = `${f.dest}.oc-harness-setup-tmp-${process.pid}`;
      writeFileSync(tmp, readFileSync(f.src));
      rmSync(f.dest, { force: true }); // Windows rename() cannot overwrite
      renameSync(tmp, f.dest);
      written += 1;
    }
    // Preserved entries journal the SRC hash on purpose: --uninstall deletes
    // only on an exact match, so a preserved destination (bytes differ from
    // src) reads as modified → kept, not deleted.
    manifest.files.push(prevHash ? { path: f.rel, hash: srcHash, prevHash, action } : { path: f.rel, hash: srcHash, action });
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

function mergeJsonc(configDir, backupPath, manifest) {
  const distroPath = path.join(PKG_ROOT, 'opencode.jsonc');
  if (!existsSync(distroPath)) {
    log('merge', 'note: this package ships no opencode.jsonc — no merge to do');
    return;
  }
  // Output is always opencode.jsonc (the canonical file the doctor grades).
  // Input prefers the adopter's opencode.jsonc; when only opencode.json exists
  // we merge THAT, rather than ignoring the adopter's real config.
  const targetPath = path.join(configDir, 'opencode.jsonc');
  const jsonPath = path.join(configDir, 'opencode.json');
  const sourcePath = existsSync(targetPath) ? targetPath : existsSync(jsonPath) ? jsonPath : null;
  if (sourcePath === jsonPath) {
    console.warn(
      `[warn] merge: found ${jsonPath} but no opencode.jsonc — merging it into a freshly written opencode.jsonc. ` +
        'Your opencode.json is left untouched; reconcile or remove it so the two cannot drift.'
    );
  }

  const merged = structuredClone(
    parseJsonc(readFileSync(distroPath, 'utf8'), 'the shipped opencode.jsonc (this package build looks broken)')
  );
  const preserved = [];
  if (sourcePath) {
    const user = parseJsonc(
      readFileSync(sourcePath, 'utf8'),
      `your existing ${path.basename(sourcePath)} — aborting before any write; your config is untouched (backup: ${backupPath})`
    );
    const userPerms = Array.isArray(user.permissions) ? user.permissions : null;
    if (user.permissions !== undefined && !userPerms) {
      console.warn('[warn] merge: your "permissions" is not an array (v2 expects an array of {action,resource,effect}) — harness denies kept; fix your rules manually.');
    }
    for (const k of Object.keys(user)) {
      if (INSTALL_OWNED.includes(k)) continue; // distro value wins outright
      if (k === 'permissions') {
        if (!userPerms) continue;
        // Ordered union, deny-last. Under last-match-wins an adopter's rule must
        // sit AFTER the harness's allow/ask rules (whose leading `shell *` allow
        // would otherwise neutralise an adopter `shell … deny`), and every
        // harness HARD DENY must stay after both so nothing can shadow it
        // (Law 12). The `skill` action is exempt from the move: its fail-closed
        // allowlist is `skill * → deny` FOLLOWED by one allow per local skill
        // (Law 9 requires the wildcard deny; Law 12 exempts the action), so
        // moving that deny last would deny every known skill. Skill rules keep
        // their shipped relative order in the head.
        // Rules identical to a harness rule are dropped from the adopter's side
        // and kept from the harness's, so a re-run reproduces the same array
        // exactly (a plain concat would double it on every run).
        const distroPerms = Array.isArray(merged.permissions) ? merged.permissions : [];
        const sameRule = (a, b) => JSON.stringify(a) === JSON.stringify(b);
        const isHardDeny = (p) => !!p && p.effect === 'deny' && p.action !== 'skill';
        const distroHead = distroPerms.filter((p) => !isHardDeny(p));
        const distroTail = distroPerms.filter(isHardDeny);
        const userOnly = userPerms.filter((p) => !distroPerms.some((d) => sameRule(d, p)));
        merged.permissions = [...distroHead, ...userOnly, ...distroTail];
      } else if (UNION_KEYS.includes(k)) {
        merged[k] = Array.isArray(user[k])
          ? [...new Set([...(Array.isArray(merged[k]) ? merged[k] : []), ...user[k]])]
          : user[k];
      } else if (k === 'references') {
        // Object union: distro keys + user-only keys.
        merged.references = { ...(user.references ?? {}), ...(merged.references ?? {}) };
      } else {
        merged[k] = user[k]; // adopter value wins
      }
      preserved.push(k);
    }
  } else {
    log('merge', 'no existing opencode.jsonc/opencode.json — writing the harness base');
  }
  // JSON.stringify strips comments, including the marker the doctor's Law 11
  // cites as evidence — reinsert it so the merged file still documents the
  // deny gate (the law grades the rules; the marker keeps its cited evidence).
  const denyEvidence =
    '  // Hard stops. `ask` is auto-approved under --auto, so `deny` is the only gate\n' +
    '  // that holds while you are away. Keep this set minimal and last.\n';
  const mergedText = JSON.stringify(merged, null, 2).replace(
    '  "permissions": [\n',
    `  "permissions": [\n${denyEvidence}`
  );
  const out = `${mergedText}\n`;
  mkdirSync(configDir, { recursive: true });
  const tmp = `${targetPath}.oc-harness-setup-tmp-${process.pid}`;
  writeFileSync(tmp, out);
  rmSync(targetPath, { force: true });
  renameSync(tmp, targetPath);
  manifest.files.push({ path: 'opencode.jsonc', hash: sha256Text(out), action: 'merged' });
  log(
    'merge',
    `ownership — install-owned (distro wins): ${INSTALL_OWNED.join(', ')} · union: ${[...UNION_KEYS, 'references'].join(', ')} · your keys preserved: ${preserved.length}${preserved.length ? ` (${preserved.join(', ')})` : ''}`
  );
  log('merge', `rewrote ${targetPath} (distro base + your keys; permissions = harness allows, yours, harness denies last)`);
}

/* ------------------------------ author-leak lint --------------------------- */

// Lints the PACKAGE source (files[].src) and nothing else. The adopter's config
// is never a lint target, so a valid config — including a DOCS-SANCTIONED
// `{file:~/.secrets/…}` apiKey pointer — can never trip this abort. Called
// pre-write, so a hit aborts before anything lands.
function lintPackagedSource(files) {
  const hits = [];
  for (const f of files) {
    if (!f.src || !existsSync(f.src)) continue;
    const low = readFileSync(f.src, 'utf8').toLowerCase();
    // No `break`: a file can carry more than one marker, and reporting only the
    // first hides the rest of the leak.
    for (const pat of LINT_PATTERNS) {
      if (pat.test.test(low)) hits.push({ file: f.rel, pattern: pat.label });
    }
  }
  return hits;
}

/* ------------------------------- plugin gate ------------------------------- */

function registerPlugins() {
  const list = ['oc-flight-deck'];
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

function pwshProbe() {
  const probe = exec('pwsh', ['-NoProfile', '-Command', 'exit 0'], true);
  return { usable: !(probe.error || probe.status !== 0) };
}

function doctorPlan() {
  return pwshProbe().usable
    ? 'run scripts/harness-doctor.ps1 via pwsh'
    : 'pwsh missing — doctor SKIPPED, 16 laws UNVERIFIED (warned + journaled)';
}

function runDoctor(configDir, probe) {
  if (!probe.usable) {
    console.warn('[doctor] WARNING: pwsh (PowerShell 7) was not found — harness-doctor did NOT run, so the 16 laws are UNVERIFIED.');
    console.warn('[doctor] Your config still landed, and the skip is recorded in the manifest. To verify later:');
    console.log('    winget install --id Microsoft.PowerShell --source winget   (Windows)');
    console.log('    brew install --cask powershell                             (macOS)');
    console.log('    then re-run: npx oc-harness-setup setup');
    return { code: 0, skipped: true };
  }
  const script = path.join(configDir, 'scripts', 'harness-doctor.ps1');
  if (!existsSync(script)) {
    console.warn(`[doctor] WARNING: ${script} not found — harness-doctor did NOT run, so the 16 laws are UNVERIFIED.`);
    return { code: 0, skipped: true };
  }
  log('doctor', `running ${script}`);
  const res = exec('pwsh', ['-NoProfile', '-File', script, '-ConfigDir', configDir], false);
  if (res.error || res.status !== 0) {
    log(
      'doctor',
      `harness-doctor exited ${res.error ? 'with an error' : `${res.status}`} — fix the issue, then re-run setup (idempotent)`
    );
    return { code: 1, skipped: false };
  }
  log('doctor', 'harness-doctor passed');
  return { code: 0, skipped: false };
}

/* --------------------------- manifest print (gate) ------------------------- */

function printManifest(configDir, files, backupPath, doctor) {
  const newCount = files.filter((f) => !existsSync(f.dest)).length;
  const sameCount = files.length - newCount;
  console.log('----------------------------- install manifest -----------------------------');
  console.log(`  destination config dir : ${configDir}`);
  console.log(`  incoming files         : ${files.length} (${newCount} new, ${sameCount} already identical — rerun-safe)`);
  console.log(`  backup path            : ${backupPath}`);
  console.log('  opencode.jsonc merge   : distro base (permissions/deny block, skill allowlist,');
  console.log('                            default_agent: "master", references registry)');
  console.log('                            + your keys kept · permissions: harness allows, yours, harness denies last');
  console.log('  plugin registration    : oc-flight-deck (via \'opencode plugin add\')');
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
  const backupRoot = manifest.backupPath ? path.resolve(String(manifest.backupPath)) : null;
  let removed = 0;
  let restored = 0;
  let kept = 0;
  let preserved = 0;
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
    if (entry.action === 'overwritten' || entry.action === 'merged') {
      // A genuine overwrite comes back from the pre-install backup; the merged
      // opencode.jsonc is never deleted — restore the adopter's original, or
      // leave the harness copy in place when no backup holds it.
      const original = backupRoot ? path.join(backupRoot, rel) : null;
      if (original && existsSync(original)) {
        // Restoring is only reversible if the bytes being replaced survive. When
        // the current file is not the one the installer wrote (hash differs, or
        // none was journaled) it holds post-install edits — copy it aside before
        // the restore overwrites it. Byte-identical installer output needs no
        // copy.
        if (!entry.hash || sha256File(resolved) !== entry.hash) {
          const keep = nextFreePath(`${resolved}.replaced-${tsStamp()}`);
          cpSync(resolved, keep);
          preserved += 1;
          log('uninstall', `kept   ${path.relative(base, keep)} (your post-install edits — copied before restore)`);
        }
        cpSync(original, resolved, { force: true });
        restored += 1;
        log('uninstall', `restored ${rel} (your pre-install file, from ${manifest.backupPath})`);
      } else {
        kept += 1;
        log('uninstall', `kept   ${rel} (WARNING: no backup at ${original || '(no backupPath recorded)'} — not deleted)`);
      }
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
  log('uninstall', `removed ${removed}, restored ${restored} overwritten, kept ${kept} modified, preserved ${preserved} edit-copies, already-missing ${missing}`);
  console.log(`  backup (pre-install config dir): ${manifest.backupPath || '(none recorded)'}`);
  if (manifest.priorBackup) console.log(`  later snapshot (kept for the chain): ${manifest.priorBackup}`);
  console.log('  to restore it fully, replace the current config dir with that backup.');
  if (preserved > 0) {
    console.log(`  ${preserved} post-install edit-copy(ies) written beside the restored file(s) as <name>.replaced-<ts> (listed above).`);
  }
  if (manifest.doctorSkipped) {
    console.log('  note: this install skipped the doctor — the 16 laws were never verified.');
  }
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

// R4: a re-run must not erase what an earlier run knew. A file this run sees as
// "skip" may have been an overwrite two runs ago; downgrading it to "skip" would
// make --uninstall delete the adopter's original instead of restoring it. Keep
// the earliest truth: overwritten stays overwritten (with the ORIGINAL prevHash),
// preserved stays preserved.
function carryForwardJournal(manifest, prior) {
  if (!prior || !Array.isArray(prior.files)) return;
  const before = new Map(prior.files.map((f) => [String(f.path), f]));
  for (const e of manifest.files) {
    const p = before.get(String(e.path));
    if (!p) continue;
    if (p.action === 'overwritten') {
      e.action = 'overwritten';
      e.prevHash = p.prevHash || e.prevHash;
    } else if (p.action === 'preserved' && e.action !== 'overwritten') {
      e.action = 'preserved';
    }
  }
}

function readManifest(configDir) {
  const p = path.join(configDir, MANIFEST_FILE);
  if (!existsSync(p)) return null;
  try {
    const m = JSON.parse(readFileSync(p, 'utf8'));
    return m && typeof m === 'object' ? m : null;
  } catch {
    return null; // an unreadable manifest is not a reason to abort — a fresh one is written
  }
}

function warnConfigTargets(configDir) {
  if (process.env.OPENCODE_CONFIG) {
    console.warn(
      `[warn] OPENCODE_CONFIG is set (${process.env.OPENCODE_CONFIG}) — it loads ABOVE the global config and may shadow this merge; check 'opencode debug config' after install.`
    );
  }
  const own = new Set([
    path.resolve(configDir, 'opencode.jsonc'),
    path.resolve(configDir, 'opencode.json'),
  ]);
  let dir = path.resolve(process.cwd());
  for (;;) {
    for (const name of ['opencode.jsonc', 'opencode.json']) {
      const p = path.join(dir, name);
      if (existsSync(p) && !own.has(path.resolve(p))) {
        console.warn(
          `[warn] project config ${p} outranks the global config — it may shadow this merge for sessions started in ${dir} or below (warn only; nothing changes).`
        );
        return;
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) return;
    dir = parent;
  }
}

async function setup(opts) {
  preflight();
  const configDir = findConfigDir();
  warnConfigTargets(configDir);
  const files = collectIncoming(configDir);

  // Author-leak lint runs PRE-write, over the PACKAGE source only. A hit aborts
  // before the consent gate, so nothing lands and the adopter's config (which
  // is never linted) can never trip it.
  const hits = lintPackagedSource(files);
  if (hits.length) {
    for (const h of hits) console.error(`[lint] author-leak marker "${h.pattern}" found in ${h.file}`);
    bail(
      `author-leak markers found in the packaged source (${hits.length} file(s) listed above) — this package build is corrupted; NOTHING was written. Reinstall from npm.`
    );
  }

  const prior = readManifest(configDir); // read-only
  const newBackupPath = nextBackupPath(configDir);
  // R4(d): a re-run must never re-point the original backup — that snapshot has
  // already been mutated by the previous install, so restoring from it would be
  // a lie. Keep the original pointer; chain the new snapshot as priorBackup.
  const backupPath = prior && prior.backupPath ? prior.backupPath : newBackupPath;
  const doctorProbe = pwshProbe(); // read-only probe
  printManifest(configDir, files, backupPath, doctorPlan());

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
  const backup = makeBackup(configDir, newBackupPath);
  const manifest = {
    package: PKG_NAME,
    version: pkgVersion(),
    created: new Date().toISOString(),
    configDir,
    backupPath: backupPath,
    ...(prior && prior.backupPath ? { priorBackup: backup } : {}),
    plugins: ['oc-flight-deck'],
    files: [],
  };

  stageFiles(files, manifest);
  carryForwardJournal(manifest, prior);
  // Register plugins BEFORE the merge: on a fresh dir `opencode plugin add`
  // installs the plugin, but once the merged opencode.jsonc lists it, add
  // no-ops with "already configured" and nothing lands in `opencode plugin
  // list` — the doctor's Law 6 grades exactly that list.
  registerPlugins();
  mergeJsonc(configDir, backup, manifest);

  // R6: record the skip in the journal so "all 16 laws unrun" is never silent.
  manifest.doctorSkipped = !doctorProbe.usable || !existsSync(path.join(configDir, 'scripts', 'harness-doctor.ps1'));
  writeManifest(configDir, manifest);
  log('manifest', `journal written: ${path.join(configDir, MANIFEST_FILE)}`);

  const doctorResult = runDoctor(configDir, doctorProbe);
  if (doctorResult.code !== 0) return 1;

  console.log();
  console.log('-------------------------------- summary ---------------------------------');
  console.log('  installed: agents/, commands/, skills/, reference/, scripts/, AGENTS.md + merged opencode.jsonc');
  console.log('  plugins  : oc-flight-deck');
  console.log(`  backup   : ${manifest.backupPath}${manifest.priorBackup ? `\n  snapshot : ${manifest.priorBackup} (chained — backup() pointer above is the original)` : ''}`);
  if (manifest.doctorSkipped) {
    console.log('  doctor   : ⚠ SKIPPED — the 16 laws were NOT verified (journaled as doctorSkipped; install PowerShell 7 and re-run to verify)');
  }
  console.log('  undo     : npx oc-harness-setup setup --uninstall');
  console.log('  restart  : restart your OpenCode session so the new agents/commands/skills load.');
  console.log('----------------------------------------------------------------------------');
  return 0;
}

/* --------------------------------- entry ---------------------------------- */

function parseArgs(argv) {
  const opts = { command: 'setup', dryRun: false, ci: false, uninstall: false };
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