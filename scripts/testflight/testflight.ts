#!/usr/bin/env bun
/**
 * testflight — check the artifact you are about to publish, not the checkout you
 * built it in.
 *
 * Twice in this project the working copy passed and the *published* package
 * failed, because the checkout's node_modules satisfied imports that npm would
 * never install for a user:
 *
 *   - a peer marked optional via `peerDependenciesMeta`: npm skipped it, and the
 *     package died on `Cannot find package '@opentui/solid'`;
 *   - a plugin that resolved its own copy of `solid-js` while the host binary
 *     carried a different instance entirely.
 *
 * `npm pack --dry-run` catches neither. It lists files; it does not install them
 * and it does not resolve them.
 *
 * What this does:
 *   1. packs the real tarball
 *   2. extracts it and reads the *published* manifest, not the checkout's
 *   3. verifies every declared entry point is actually inside the tarball
 *   4. flags required peers marked optional, and peers duplicated as runtime deps
 *   5. greps the packed bytes for machine-specific paths
 *   6. installs into a throwaway project and confirms each peer resolved
 *
 * Honest limit: this proves packaging, contents, and resolution. It cannot
 * reproduce modules the host injects at runtime, so a plugin can still load here
 * and fail inside a bundled host binary. That failure has a different cause and
 * needs a different test — do not read a green run as "it works in the host".
 *
 * Usage:
 *   testflight .                    check the package in this directory
 *   testflight ./pkg-1.0.0.tgz      check an existing tarball
 *   testflight . --json             machine-readable
 *   testflight . --no-install       static checks only (no network, fast)
 *   testflight . --import           also import the declared entry points
 *   testflight . --keep             keep the sandbox, print its path
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

export type Severity = "error" | "warn" | "info";

export interface Finding {
  /** Stable identifier, e.g. `TF001`. Printed so a failure can be cited. */
  code: string;
  severity: Severity;
  title: string;
  detail: string;
  evidence?: string[];
}

export interface PackedFile {
  /** Path inside the tarball, POSIX separators, relative to the package root. */
  path: string;
  size: number;
  abs: string;
}

const SEVERITY_ORDER: Record<Severity, number> = { error: 0, warn: 1, info: 2 };

export function sortFindings(findings: Finding[]): Finding[] {
  return [...findings].sort(
    (a, b) => SEVERITY_ORDER[a.severity] - SEVERITY_ORDER[b.severity] || a.code.localeCompare(b.code),
  );
}

export function summarise(findings: Finding[]): { errors: number; warnings: number; infos: number } {
  return {
    errors: findings.filter((f) => f.severity === "error").length,
    warnings: findings.filter((f) => f.severity === "warn").length,
    infos: findings.filter((f) => f.severity === "info").length,
  };
}

// ---------------------------------------------------------------------------
// Running external tools
// ---------------------------------------------------------------------------

/**
 * `shell: true` because npm and tar are `.cmd` shims on Windows and
 * CreateProcess cannot execute those directly. Arguments are quoted here, and
 * they come from the user's own command line, so there is no untrusted input.
 */
export function run(
  cmd: string,
  args: string[],
  opts: { cwd?: string; timeoutMs?: number } = {},
): { code: number; stdout: string; stderr: string; timedOut: boolean } {
  const quote = (s: string) => (/[\s"]/.test(s) ? `"${s.replace(/"/g, '\\"')}"` : s);
  const line = [cmd, ...args].map(quote).join(" ");
  const r = spawnSync(line, {
    cwd: opts.cwd,
    encoding: "utf8",
    shell: true,
    windowsHide: true,
    timeout: opts.timeoutMs ?? 180_000,
  });
  return {
    code: r.status ?? 1,
    stdout: r.stdout ?? "",
    stderr: r.stderr ?? "",
    timedOut: r.error?.code === "ETIMEDOUT" || r.signal === "SIGTERM",
  };
}

/** npm buries the useful line; surface the first few non-empty ones. */
export function firstLines(text: string, count: number): string {
  return text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(0, count)
    .join("\n");
}

// ---------------------------------------------------------------------------
// Walking the packed tree
// ---------------------------------------------------------------------------

const TEXT_EXT = new Set([
  ".js", ".mjs", ".cjs", ".mts", ".cts", ".ts", ".tsx", ".jsx",
  ".json", ".md", ".txt", ".sh", ".ps1", ".cmd", ".bat",
  ".toml", ".yml", ".yaml", ".css", ".html",
]);

const MAX_SCAN_FILE = 1_000_000;
const MAX_SCAN_TOTAL = 40_000_000;

/** Every file in the extracted tarball, POSIX-relative paths. */
export function walkFiles(root: string): PackedFile[] {
  const out: PackedFile[] = [];
  const visit = (dir: string, prefix: string) => {
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      const abs = join(dir, name);
      const rel = prefix ? `${prefix}/${name}` : name;
      let st;
      try {
        st = statSync(abs);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        if (name === ".git") continue;
        visit(abs, rel);
      } else if (st.isFile()) {
        out.push({ path: rel, size: st.size, abs });
      }
    }
  };
  visit(root, "");
  return out.sort((a, b) => a.path.localeCompare(b.path));
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

export interface EntryRef {
  /** Relative path as declared, with any leading `./` stripped. */
  path: string;
  /** Which manifest field declared it, for the report. */
  field: string;
}

const STRING_ENTRY_FIELDS = [
  "main", "module", "browser", "types", "typings", "unpkg", "jsdelivr", "style",
] as const;

function normaliseEntry(value: string): string {
  return value.replace(/^\.\//, "").replace(/^[/\\]+/, "").replace(/\\/g, "/").replace(/\/+$/, "");
}

/**
 * Every file the package promises to ship, from `main`/`types`/`bin`/`exports`.
 * Wildcard patterns are skipped: they are a promise about shape, not a file.
 */
export function collectEntryPaths(manifest: Record<string, unknown>): EntryRef[] {
  const out: EntryRef[] = [];
  const push = (value: unknown, field: string) => {
    if (typeof value !== "string" || !value) return;
    if (value.includes("*")) return;
    const path = normaliseEntry(value);
    if (!path || path === "." || path === "./") return;
    if (!out.some((e) => e.path === path && e.field === field)) out.push({ path, field });
  };

  for (const field of STRING_ENTRY_FIELDS) push(manifest[field], field);

  const bin = manifest["bin"];
  if (typeof bin === "string") push(bin, "bin");
  else if (bin && typeof bin === "object") {
    for (const [name, value] of Object.entries(bin as Record<string, unknown>)) push(value, `bin.${name}`);
  }

  const walkExports = (value: unknown, field: string) => {
    if (typeof value === "string") push(value, field);
    else if (Array.isArray(value)) value.forEach((v) => walkExports(v, field));
    else if (value && typeof value === "object") {
      for (const child of Object.values(value as Record<string, unknown>)) walkExports(child, field);
    }
  };
  if (manifest["exports"] !== undefined) walkExports(manifest["exports"], "exports");

  // `files` is the third input npm uses, after `.npmignore` and `.gitignore`.
  // A missing entry point is usually a `files` entry that forgot the build dir.
  return out;
}

/** An entry point is satisfied by the file itself, or by a directory with that prefix. */
function entryExists(path: string, files: PackedFile[]): boolean {
  if (files.some((f) => f.path === path)) return true;
  return files.some((f) => f.path.startsWith(`${path}/`));
}

function findCaseMismatch(path: string, files: PackedFile[]): string | undefined {
  const lower = path.toLowerCase();
  return files.find((f) => f.path.toLowerCase() === lower)?.path;
}

/** Text files worth scanning, read once and shared by the analysers. */
export function readTexts(files: PackedFile[]): Map<string, string> {
  const texts = new Map<string, string>();
  let budget = MAX_SCAN_TOTAL;
  for (const file of files) {
    if (!TEXT_EXT.has(extname(file.path).toLowerCase())) continue;
    if (file.path.endsWith(".map")) continue;
    if (file.size > MAX_SCAN_FILE || file.size > budget) continue;
    try {
      texts.set(file.path, readFileSync(file.abs, "utf8"));
      budget -= file.size;
    } catch {
      /* an unreadable file is not a finding */
    }
  }
  return texts;
}

/**
 * The first version of this file *claimed* "the package imports it" without
 * ever looking. These are the patterns that make that claim true.
 */
function peerUsage(
  peer: string,
  texts: Map<string, string>,
): { static: string[]; dynamic: string[] } {
  const escaped = peer.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const suffix = `(?:/[^"'\`]*)?`;
  const staticRe = new RegExp(
    `(?:\\bfrom\\s*|\\brequire\\(\\s*)["'\`]${escaped}${suffix}["'\`]`,
  );
  const dynamicRe = new RegExp(`\\bimport\\(\\s*["'\`]${escaped}${suffix}["'\`]`);

  const found = { static: [] as string[], dynamic: [] as string[] };
  for (const [path, text] of texts) {
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const where = `${path}:${i + 1}: ${lines[i].trim().slice(0, 140)}`;
      if (staticRe.test(lines[i])) {
        if (found.static.length < 5) found.static.push(where);
      } else if (dynamicRe.test(lines[i])) {
        if (found.dynamic.length < 5) found.dynamic.push(where);
      }
    }
  }
  return found;
}

// ---------------------------------------------------------------------------
// Static analysis of the published manifest and bytes
// ---------------------------------------------------------------------------

export function analyseManifest(
  manifest: Record<string, unknown>,
  files: PackedFile[],
  texts: Map<string, string> = new Map(),
): Finding[] {
  const findings: Finding[] = [];
  const pkgName = typeof manifest["name"] === "string" ? manifest["name"] : "(unnamed)";

  // TF001 — an entry point the manifest promises is not in the tarball.
  for (const entry of collectEntryPaths(manifest)) {
    if (entryExists(entry.path, files)) continue;
    const mismatch = findCaseMismatch(entry.path, files);
    findings.push({
      code: "TF001",
      severity: "error",
      title: `Declared entry point is missing from the tarball: ${entry.path}`,
      detail: mismatch
        ? `"${entry.field}" points at "${entry.path}" but the tarball ships "${mismatch}". The case differs and the publish will break on a case-sensitive filesystem.`
        : `"${entry.field}" points at "${entry.path}", which is not in the packed tarball. Check the "files" whitelist — a build directory left out of it ships a package that cannot be imported.`,
      evidence: [`package.json → ${entry.field}: ${entry.path}`],
    });
  }

  // TF002 — a required peer marked optional. This is the oc-flight-deck@0.1.0 bug.
  const peers = (manifest["peerDependencies"] ?? {}) as Record<string, unknown>;
  const peerMeta = (manifest["peerDependenciesMeta"] ?? {}) as Record<string, Record<string, unknown>>;
  const deps = (manifest["dependencies"] ?? {}) as Record<string, unknown>;
  const optionalPeers = Object.entries(peerMeta)
    .filter(([, meta]) => meta && meta["optional"] === true)
    .map(([name]) => name);

  for (const peer of optionalPeers) {
    if (!(peer in peers)) continue;
    const usage = peerUsage(peer, texts);
    const declared = `package.json → peerDependenciesMeta["${peer}"].optional: true`;

    if (usage.static.length) {
      findings.push({
        code: "TF002",
        severity: "error",
        title: `Peer marked optional, but shipped code imports it: ${peer}`,
        detail:
          "npm skips optional peers during install. The package installs cleanly, then dies at import time with \"Cannot find package\". This is exactly how oc-flight-deck@0.1.0 shipped broken. Remove it from peerDependenciesMeta, or make the import dynamic and guarded.",
        evidence: [declared, ...usage.static],
      });
    } else if (usage.dynamic.length) {
      findings.push({
        code: "TF002",
        severity: "warn",
        title: `Peer marked optional and only imported dynamically: ${peer}`,
        detail:
          "npm skips optional peers. A dynamic import fails only if that code path runs, so this is safe only if the failure is handled. Confirm the call site catches the missing module.",
        evidence: [declared, ...usage.dynamic],
      });
    } else {
      findings.push({
        code: "TF002",
        severity: "info",
        title: `Peer marked optional and never referenced in shipped code: ${peer}`,
        detail:
          "Consistent: npm will skip it, and nothing in the tarball asks for it. Fine — but if the host is expected to provide it, plain peerDependencies documents that better.",
        evidence: [declared],
      });
    }
  }

  // TF003 — a peer also declared as a runtime dependency: two instances at runtime.
  for (const peer of Object.keys(peers)) {
    if (!(peer in deps)) continue;
    findings.push({
      code: "TF003",
      severity: "error",
      title: `Peer is also a runtime dependency: ${peer}`,
      detail:
        "The package will install its own copy of a module the host also provides. Both copies load, module identity differs, and state shared across the boundary silently stops working. Keep it in peerDependencies only.",
      evidence: [
        `package.json → peerDependencies["${peer}"]: ${peers[peer]}`,
        `package.json → dependencies["${peer}"]: ${deps[peer]}`,
      ],
    });
  }

  // TF004 — bin entries that are not shipped.
  const bin = manifest["bin"];
  if (bin && typeof bin === "object") {
    for (const [name, value] of Object.entries(bin as Record<string, unknown>)) {
      if (typeof value !== "string") continue;
      const path = normaliseEntry(value);
      if (path && !entryExists(path, files)) {
        findings.push({
          code: "TF004",
          severity: "error",
          title: `Declared bin is missing from the tarball: ${name}`,
          detail: `"bin.${name}" points at "${path}", which is not packed. The installed command will fail on every run.`,
        });
      }
    }
  }

  // TF005 — a peer symlinked in *as a bundled dependency*.
  const bundledPeers = Object.keys(peers).filter((peer) =>
    files.some((f) => f.path.startsWith(`node_modules/${peer}/`)),
  );
  if (bundledPeers.length) {
    findings.push({
      code: "TF005",
      severity: "warn",
      title: `Peer bundled inside the tarball: ${bundledPeers.join(", ")}`,
      detail:
        "A peer that ships in the tarball is a second copy of something the host already provides. If the host loads the peer itself, module identity differs across the boundary.",
      evidence: bundledPeers.map((p) => `node_modules/${p}/`),
    });
  }

  if (findings.length === 0) {
    findings.push({
      code: "TF000",
      severity: "info",
      title: `Manifest and contents look consistent (${pkgName})`,
      detail: `Checked ${collectEntryPaths(manifest).length} declared entry point(s) against ${files.length} packed file(s).`,
    });
  }

  return findings;
}

/**
 * Machine-specific paths. A package that hardcodes an absolute path works on
 * exactly one machine, and the README is the most common place for it to hide.
 *
 * URL-shaped text is stripped before the bare-path patterns run, so a
 * `https://github.com/...` link is not mistaken for a `C:` drive — the first
 * version of this file did exactly that. `file://` is only ever a host path, so
 * it is matched against the raw line.
 */
const PATH_PATTERNS: ReadonlyArray<{
  re: RegExp;
  label: string;
  severity: Severity;
  ignoreUrls: boolean;
}> = [
  { re: /file:\/\/\/[A-Za-z]:[\\/]/, label: "an absolute Windows path in a file:// URL", severity: "error", ignoreUrls: false },
  { re: /file:\/\/(?:\/)?(?:Users|home)\/[A-Za-z0-9._-]+\//, label: "an absolute home path in a file:// URL", severity: "error", ignoreUrls: false },
  { re: /file:\/\//, label: "a file:// URL", severity: "warn", ignoreUrls: false },
  { re: /(?<![\w:/])[A-Za-z]:[\\/]/, label: "an absolute Windows path", severity: "warn", ignoreUrls: true },
  { re: /(?<![\w.-])\/(?:Users|home)\/[A-Za-z0-9._-]+\//, label: "an absolute POSIX home path", severity: "warn", ignoreUrls: true },
];

const URL_SHAPED = /https?:\/\/\S+/gi;

export function scanContents(texts: Map<string, string>): Finding[] {
  const findings: Finding[] = [];
  const hits = new Map<string, { label: string; severity: Severity; evidence: string[] }>();

  for (const [path, text] of texts) {
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const withoutUrls = line.replace(URL_SHAPED, "");
      for (const { re, label, severity, ignoreUrls } of PATH_PATTERNS) {
        if (!re.test(ignoreUrls ? withoutUrls : line)) continue;
        const bucket = hits.get(label) ?? { label, severity, evidence: [] };
        if (bucket.evidence.length < 5) {
          bucket.evidence.push(`${path}:${i + 1}: ${line.trim().slice(0, 140)}`);
        }
        hits.set(label, bucket);
        break;
      }
    }
  }

  let index = 0;
  for (const bucket of hits.values()) {
    findings.push({
      code: `TF${(10 + index++).toString().padStart(3, "0")}`,
      severity: bucket.severity,
      title: `Packaged files reference ${bucket.label}`,
      detail:
        "A path that names one machine is a package that works on one machine. It usually means a default value, a config, or an example was written for a local checkout and packed as-is.",
      evidence: bucket.evidence,
    });
  }

  return findings;
}

// ---------------------------------------------------------------------------
// Pack, extract, install
// ---------------------------------------------------------------------------

export function packPackage(dir: string, dest: string): { tgz?: string; error?: string } {
  const r = run("npm", ["pack", "--pack-destination", dest, "--loglevel=error"], {
    cwd: dir,
    timeoutMs: 180_000,
  });
  if (r.timedOut) return { error: "npm pack timed out" };
  if (r.code !== 0) return { error: firstLines(r.stderr || r.stdout, 6) || "npm pack failed" };

  const tgzs = readdirSync(dest).filter((f) => f.endsWith(".tgz"));
  if (!tgzs.length) return { error: "npm pack reported success but produced no tarball" };
  return { tgz: join(dest, tgzs[0]) };
}

export function extractTarball(tgz: string, dest: string): { root?: string; error?: string } {
  mkdirSync(dest, { recursive: true });
  const r = run("tar", ["-xzf", tgz, "-C", dest], { timeoutMs: 120_000 });
  if (r.timedOut) return { error: "tar timed out" };
  if (r.code !== 0) return { error: firstLines(r.stderr || r.stdout, 6) || "tar failed" };

  // npm tarballs nest everything under `package/`.
  const nested = join(dest, "package");
  return { root: existsSync(nested) ? nested : dest };
}

/**
 * A real install in a throwaway project. This is the step `npm pack --dry-run`
 * cannot do, and the step that would have caught the 0.1.0 release.
 */
export function installAndCheck(
  manifest: Record<string, unknown>,
  tgz: string,
  sandbox: string,
): Finding[] {
  const findings: Finding[] = [];
  const project = join(sandbox, "project");
  mkdirSync(project, { recursive: true });
  writeFileSync(
    join(project, "package.json"),
    JSON.stringify({ name: "testflight-sandbox", version: "0.0.0", private: true }, null, 2),
  );

  const r = run(
    "npm",
    ["install", tgz, "--no-audit", "--no-fund", "--ignore-scripts", "--loglevel=error"],
    { cwd: project, timeoutMs: 300_000 },
  );

  if (r.timedOut || r.code !== 0) {
    const message = firstLines(r.stderr || r.stdout, 8);
    const network = /\b(ENOTFOUND|ETIMEDOUT|EAI_AGAIN|ECONNREFUSED|network|offline)\b/i.test(message);
    findings.push({
      code: "TF020",
      severity: network ? "warn" : "error",
      title: network ? "Install could not reach the registry" : "Install failed in a clean project",
      detail: network
        ? "The install could not resolve against the registry, so peer resolution was not verified. Re-run with a network connection to complete the check."
        : "Installing the packed tarball into an empty project failed. This is the error a user sees on `npm install`.",
      evidence: message ? message.split("\n") : [],
    });
    return findings;
  }

  const modules = join(project, "node_modules");
  const peers = (manifest["peerDependencies"] ?? {}) as Record<string, unknown>;
  const peerMeta = (manifest["peerDependenciesMeta"] ?? {}) as Record<string, Record<string, unknown>>;

  for (const [peer, range] of Object.entries(peers)) {
    const installed = existsSync(join(modules, ...peer.split("/"), "package.json"));
    const optional = peerMeta[peer]?.["optional"] === true;
    if (installed) continue;
    if (optional) {
      findings.push({
        code: "TF021",
        severity: "info",
        title: `Optional peer was skipped, as marked: ${peer}`,
        detail: "Correct npm behaviour. It is only a bug if shipped code imports it — TF002 covers that.",
      });
    } else {
      findings.push({
        code: "TF022",
        severity: "error",
        title: `Required peer did not resolve after install: ${peer}`,
        detail: `The manifest requires "${peer}@${range}" but a clean install did not provide it. Users will hit the same failure.`,
      });
    }
  }

  const installedName =
    typeof manifest["name"] === "string" ? manifest["name"] : "";
  if (installedName && !existsSync(join(modules, ...installedName.split("/"), "package.json"))) {
    findings.push({
      code: "TF023",
      severity: "error",
      title: `The package itself is missing after install: ${installedName}`,
      detail: "npm install succeeded but the package is not in node_modules. The tarball manifest is inconsistent.",
    });
  }

  return findings;
}

/** `--import`: load the declared entry points from the *installed* package. */
export async function importEntries(
  manifest: Record<string, unknown>,
  sandbox: string,
): Promise<Finding[]> {
  const findings: Finding[] = [];
  const name = typeof manifest["name"] === "string" ? manifest["name"] : "";
  if (!name) return findings;

  const root = join(sandbox, "project", "node_modules", ...name.split("/"));
  const entries = collectEntryPaths(manifest).filter((e) => e.field !== "types" && e.field !== "typings");
  const seen = new Set<string>();

  for (const entry of entries) {
    const target = join(root, ...entry.path.split("/"));
    if (seen.has(target) || !existsSync(target)) continue;
    seen.add(target);
    if (!/\.[cm]?js$/.test(target)) continue;
    try {
      await import(pathToFileURL(target).href);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const missingPeer = /Cannot find (?:package|module)\s+'?([^'\s]+)'?/.exec(message);
      findings.push({
        code: "TF030",
        severity: missingPeer ? "error" : "warn",
        title: `Import failed: ${entry.field} → ${entry.path}`,
        detail: missingPeer
          ? `Loading the installed entry point could not resolve "${missingPeer[1]}". This is the failure a user gets on first run.`
          : "Loading the installed entry point threw. If the package expects a host runtime this may be expected — read the message before treating it as a packaging fault.",
        evidence: [`${entry.path}: ${message.split(/\r?\n/)[0].slice(0, 200)}`],
      });
    }
  }

  return findings;
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

export interface Options {
  json: boolean;
  keep: boolean;
  noInstall: boolean;
  doImport: boolean;
}

export async function check(target: string, opts: Options): Promise<{
  findings: Finding[];
  sandbox: string | null;
  packageName: string;
  packageVersion: string;
  fileCount: number;
  failed: boolean;
  fatal?: string;
}> {
  const sandbox = mkdtempSync(join(tmpdir(), "testflight-"));
  const empty = { findings: [] as Finding[], sandbox: null, packageName: "", packageVersion: "", fileCount: 0, failed: false };

  try {
    // 1. pack — always from a real tarball, never from the checkout.
    let tgz: string;
    const resolved = resolve(target);
    if (!existsSync(resolved)) {
      return { ...empty, fatal: `no such file or directory: ${target}`, failed: true };
    }

    if (resolved.toLowerCase().endsWith(".tgz")) {
      tgz = resolved;
    } else {
      const packed = packPackage(resolved, sandbox);
      if (!packed.tgz) {
        return { ...empty, fatal: `npm pack failed: ${packed.error}`, failed: true };
      }
      tgz = packed.tgz;
    }

    // 2. extract — read the published bytes, not the working copy.
    const extracted = extractTarball(tgz, join(sandbox, "pkg"));
    if (!extracted.root) {
      return { ...empty, fatal: `could not extract tarball: ${extracted.error}`, failed: true };
    }

    const manifestPath = join(extracted.root, "package.json");
    if (!existsSync(manifestPath)) {
      return { ...empty, fatal: "the tarball has no package.json", failed: true };
    }
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>;
    const files = walkFiles(extracted.root);
    const texts = readTexts(files);

    // 3. static checks
    const findings: Finding[] = [];
    findings.push(...analyseManifest(manifest, files, texts));
    findings.push(...scanContents(texts));

    // 4. install + peers
    if (!opts.noInstall) {
      findings.push(...installAndCheck(manifest, tgz, sandbox));
    }

    // 5. optional import
    if (opts.doImport && !opts.noInstall) {
      findings.push(...(await importEntries(manifest, sandbox)));
    }

    // TF000 is the "everything checked out" marker. It is only worth printing
    // when there is nothing else to say.
    const reportable = findings.filter((f) => f.code !== "TF000");
    const finalFindings = reportable.length ? sortFindings(reportable) : findings;

    return {
      findings: finalFindings,
      sandbox: opts.keep ? sandbox : null,
      packageName: typeof manifest["name"] === "string" ? manifest["name"] : "(unnamed)",
      packageVersion: typeof manifest["version"] === "string" ? manifest["version"] : "(unversioned)",
      fileCount: files.length,
      failed: finalFindings.some((f) => f.severity === "error"),
    };
  } catch (error) {
    return { ...empty, fatal: error instanceof Error ? error.message : String(error), failed: true };
  } finally {
    if (!opts.keep) {
      try {
        rmSync(sandbox, { recursive: true, force: true });
      } catch {
        /* the sandbox is in the OS temp dir; leaving it is harmless */
      }
    }
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const USAGE = `testflight — verify the artifact you are about to publish.

  testflight <dir|tarball>     pack, extract, inspect, install, resolve
  testflight . --no-install    static checks only (fast, no network)
  testflight . --import        also load the declared entry points
  testflight . --json          machine-readable output
  testflight . --keep          keep the sandbox and print its path
  testflight --help

Exit codes: 0 clean (warnings allowed), 1 findings, 2 could not run.
`;

const SEVERITY_LABEL: Record<Severity, string> = { error: "FAIL", warn: "WARN", info: "ok  " };

export function formatReport(result: Awaited<ReturnType<typeof check>>): string {
  const lines: string[] = [];
  const { errors, warnings } = summarise(result.findings);

  lines.push(`${result.packageName}@${result.packageVersion} — ${result.fileCount} packed file(s)`);
  lines.push("");

  if (result.fatal) {
    lines.push(`  FAIL  ${result.fatal}`);
    lines.push("");
    lines.push("Could not run the check.");
    return lines.join("\n");
  }

  for (const finding of result.findings) {
    lines.push(`  ${SEVERITY_LABEL[finding.severity]} ${finding.code}  ${finding.title}`);
    lines.push(`        ${finding.detail}`);
    for (const line of finding.evidence ?? []) lines.push(`        · ${line}`);
    lines.push("");
  }

  if (result.sandbox) lines.push(`sandbox kept: ${result.sandbox}`);
  if (errors) lines.push(`${errors} failure(s), ${warnings} warning(s). The package is not safe to publish.`);
  else if (warnings) lines.push(`Clean on failures, ${warnings} warning(s) worth reading.`);
  else lines.push("Clean. Packaged bytes, manifest, and peer resolution all check out.");
  lines.push("");
  lines.push("Does not prove host-runtime behaviour: modules the host injects are not reproduced here.");

  return lines.join("\n");
}

function parseArgs(argv: string[]): { target?: string; opts: Options; help: boolean } {
  const opts: Options = { json: false, keep: false, noInstall: false, doImport: false };
  let target: string | undefined;
  for (const arg of argv) {
    if (arg === "--help" || arg === "-h") return { opts, help: true };
    else if (arg === "--json") opts.json = true;
    else if (arg === "--keep") opts.keep = true;
    else if (arg === "--no-install") opts.noInstall = true;
    else if (arg === "--import") opts.doImport = true;
    else if (arg.startsWith("-")) return { opts, help: false };
    else if (!target) target = arg;
  }
  return { target, opts, help: false };
}

export async function main(argv: string[]): Promise<number> {
  const { target, opts, help } = parseArgs(argv);
  if (help || !target) {
    process.stdout.write(USAGE);
    return help ? 0 : 2;
  }

  const result = await check(target, opts);

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`${formatReport(result)}\n`);
  }

  if (result.fatal) return 2;
  return result.failed ? 1 : 0;
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)));
}
