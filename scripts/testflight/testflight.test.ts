import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  analyseManifest,
  check,
  collectEntryPaths,
  firstLines,
  formatReport,
  readTexts,
  scanContents,
  sortFindings,
  summarise,
  walkFiles,
  type Finding,
  type PackedFile,
} from "./testflight";

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const sandboxes: string[] = [];

function sandbox(): string {
  const dir = mkdtempSync(join(tmpdir(), "testflight-test-"));
  sandboxes.push(dir);
  return dir;
}

afterAll(() => {
  for (const dir of sandboxes) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      /* the OS temp dir is cleaned up eventually */
    }
  }
});

/** A file list as `walkFiles` would produce, without touching the disk. */
function packed(paths: string[], size = 10): PackedFile[] {
  return paths.map((path) => ({ path, size, abs: join("Z:\\nonexistent", path) }));
}

function writePackage(dir: string, manifest: Record<string, unknown>, files: Record<string, string>) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "package.json"), JSON.stringify(manifest, null, 2));
  for (const [rel, content] of Object.entries(files)) {
    const abs = join(dir, ...rel.split("/"));
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
}

const codes = (findings: Finding[]) => findings.map((f) => f.code);
const find = (findings: Finding[], code: string) => findings.find((f) => f.code === code);

// ---------------------------------------------------------------------------
// collectEntryPaths
// ---------------------------------------------------------------------------

describe("collectEntryPaths", () => {
  test("reads the plain string fields", () => {
    const refs = collectEntryPaths({ main: "./dist/index.js", types: "dist/index.d.ts" });
    expect(refs.map((r) => r.path)).toEqual(["dist/index.js", "dist/index.d.ts"]);
    expect(refs.map((r) => r.field)).toEqual(["main", "types"]);
  });

  test("walks nested exports and their conditions", () => {
    const refs = collectEntryPaths({
      exports: {
        ".": { types: "./src/index.ts", import: "./src/index.ts" },
        "./tui": { import: ["./src/tui/index.tsx", "./src/tui/fallback.ts"] },
      },
    });
    expect(refs.map((r) => r.path).sort()).toEqual([
      "src/index.ts",
      "src/tui/fallback.ts",
      "src/tui/index.tsx",
    ]);
  });

  test("skips wildcard patterns, which promise a shape and not a file", () => {
    const refs = collectEntryPaths({ exports: { "./*": "./dist/*.js" } });
    expect(refs).toHaveLength(0);
  });

  test("reads bin as a string and as a map", () => {
    expect(collectEntryPaths({ bin: "./cli.js" })[0].path).toBe("cli.js");
    const mapped = collectEntryPaths({ bin: { testflight: "bin/run.js" } });
    expect(mapped[0].path).toBe("bin/run.js");
    expect(mapped[0].field).toBe("bin.testflight");
  });

  test("ignores non-relative and empty values", () => {
    expect(collectEntryPaths({ main: "" })).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// analyseManifest — TF001..TF005
// ---------------------------------------------------------------------------

describe("analyseManifest", () => {
  test("TF001: an entry point missing from the tarball is a failure", () => {
    const findings = analyseManifest(
      { name: "x", main: "./dist/index.js", files: ["src"] },
      packed(["package.json", "src/index.ts"]),
    );
    const finding = find(findings, "TF001");
    expect(finding?.severity).toBe("error");
    expect(finding?.title).toContain("dist/index.js");
    expect(finding?.detail).toContain("files");
  });

  test("TF001: a directory entry point is satisfied by its contents", () => {
    const findings = analyseManifest(
      { name: "x", main: "lib" },
      packed(["package.json", "lib/index.js"]),
    );
    expect(codes(findings)).not.toContain("TF001");
  });

  test("TF001: a case mismatch names both spellings", () => {
    const findings = analyseManifest(
      { name: "x", main: "./dist/Index.js" },
      packed(["package.json", "dist/index.js"]),
    );
    const finding = find(findings, "TF001");
    expect(finding?.detail).toContain("dist/index.js");
    expect(finding?.detail).toMatch(/case/i);
  });

  test("TF002: an optional peer that shipped code imports is a failure", () => {
    // This is the oc-flight-deck@0.1.0 release, reproduced.
    const texts = new Map([
      ["src/index.ts", `import { render } from "@opentui/solid";\nexport const boot = render;`],
    ]);
    const findings = analyseManifest(
      {
        name: "oc-flight-deck",
        peerDependencies: { "@opentui/solid": ">=0.5.10" },
        peerDependenciesMeta: { "@opentui/solid": { optional: true } },
      },
      packed(["package.json", "src/index.ts"]),
      texts,
    );
    const finding = find(findings, "TF002");
    expect(finding?.severity).toBe("error");
    expect(finding?.title).toContain("@opentui/solid");
    expect(finding?.evidence?.some((e) => e.includes("src/index.ts:1"))).toBe(true);
  });

  test("TF002: require() counts as a static import too", () => {
    const texts = new Map([["index.js", `const s = require("@opentui/solid");`]]);
    const findings = analyseManifest(
      {
        name: "x",
        peerDependencies: { "@opentui/solid": "*" },
        peerDependenciesMeta: { "@opentui/solid": { optional: true } },
      },
      packed(["index.js"]),
      texts,
    );
    expect(find(findings, "TF002")?.severity).toBe("error");
  });

  test("TF002: a dynamic import is only a warning", () => {
    const texts = new Map([["index.js", `const load = () => import("@opentui/solid");`]]);
    const findings = analyseManifest(
      {
        name: "x",
        peerDependencies: { "@opentui/solid": "*" },
        peerDependenciesMeta: { "@opentui/solid": { optional: true } },
      },
      packed(["index.js"]),
      texts,
    );
    expect(find(findings, "TF002")?.severity).toBe("warn");
  });

  test("TF002: an unreferenced optional peer is informational, not a failure", () => {
    const findings = analyseManifest(
      {
        name: "x",
        peerDependencies: { "some-optional": "*" },
        peerDependenciesMeta: { "some-optional": { optional: true } },
      },
      packed(["index.js"]),
      new Map([["index.js", "export const nothing = 1;"]]),
    );
    expect(find(findings, "TF002")?.severity).toBe("info");
  });

  test("TF002: does not fire when the peer is not declared a peer at all", () => {
    const findings = analyseManifest(
      { name: "x", peerDependenciesMeta: { ghost: { optional: true } } },
      packed(["index.js"]),
      new Map(),
    );
    expect(codes(findings)).not.toContain("TF002");
  });

  test("TF003: a peer that is also a runtime dependency is a failure", () => {
    const findings = analyseManifest(
      { name: "x", peerDependencies: { "solid-js": ">=1.9.0" }, dependencies: { "solid-js": "^1.9.0" } },
      packed(["package.json"]),
    );
    const finding = find(findings, "TF003");
    expect(finding?.severity).toBe("error");
    expect(finding?.evidence?.length).toBe(2);
  });

  test("TF003: a devDependency is not a duplicate instance and is not flagged", () => {
    // oc-flight-deck ships solid-js as a peer *and* a devDependency. That is
    // correct: devDependencies are not installed for consumers.
    const findings = analyseManifest(
      {
        name: "oc-flight-deck",
        peerDependencies: { "solid-js": ">=1.9.0" },
        devDependencies: { "solid-js": "1.9.15" },
      },
      packed(["package.json"]),
    );
    expect(codes(findings)).not.toContain("TF003");
  });

  test("TF004: a declared bin that is not packed is a failure", () => {
    const findings = analyseManifest(
      { name: "x", bin: { thing: "./bin/thing.js" } },
      packed(["package.json"]),
    );
    expect(find(findings, "TF004")?.severity).toBe("error");
  });

  test("TF005: a peer bundled into the tarball is a warning", () => {
    const findings = analyseManifest(
      { name: "x", peerDependencies: { "solid-js": "*" } },
      packed(["package.json", "node_modules/solid-js/package.json"]),
    );
    expect(find(findings, "TF005")?.severity).toBe("warn");
  });

  test("TF000: a consistent package reports ok and nothing else", () => {
    const findings = analyseManifest(
      { name: "x", main: "./dist/index.js" },
      packed(["package.json", "dist/index.js"]),
    );
    expect(codes(findings)).toEqual(["TF000"]);
  });
});

// ---------------------------------------------------------------------------
// scanContents — machine-specific paths
// ---------------------------------------------------------------------------

describe("scanContents", () => {
  test("does not mistake an https URL for a Windows drive", () => {
    // Regression: the first version flagged `https://github.com/...` because
    // "s:" looked like a drive letter. That turned a clean package red.
    const texts = new Map([
      ["package.json", `{"url":"git+https://github.com/alice/oc-flight-deck.git"}`],
      ["README.md", `See [the docs](https://opencode.ai/v2/docs/build/plugins/cli).`],
    ]);
    expect(scanContents(texts)).toHaveLength(0);
  });

  test("flags a file:// URL pointing at a real host path as an error", () => {
    const texts = new Map([["src/config.ts", `const p = "file:///C:/Users/alice/project";`]]);
    const findings = scanContents(texts);
    expect(findings[0]?.severity).toBe("error");
    expect(findings[0]?.evidence?.[0]).toContain("src/config.ts:1");
  });

  test("flags a bare absolute Windows path as a warning", () => {
    const texts = new Map([["src/config.ts", 'const home = "C:\\Users\\alice\\thing";']]);
    const findings = scanContents(texts);
    expect(findings[0]?.severity).toBe("warn");
    expect(findings[0]?.title).toContain("absolute Windows path");
  });

  test("flags a bare POSIX home path as a warning", () => {
    const texts = new Map([["README.md", "copy it to /Users/alice/.config/opencode"]]);
    const findings = scanContents(texts);
    expect(findings[0]?.severity).toBe("warn");
  });

  test("a plain file:// URL is a warning, not a failure", () => {
    const findings = scanContents(new Map([["docs.md", "see file:///tmp/out.txt"]]));
    expect(findings[0]?.severity).toBe("warn");
  });

  test("caps evidence so a repeated path cannot flood the report", () => {
    const line = "C:\\Users\\alice\\thing\n";
    const texts = new Map([["a.txt", line.repeat(50)]]);
    expect(scanContents(texts)[0]?.evidence?.length).toBe(5);
  });

  test("a clean package produces no path findings", () => {
    expect(scanContents(new Map([["src/index.ts", "export const x = 1;"]]))).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// file walking and text reading
// ---------------------------------------------------------------------------

describe("walkFiles", () => {
  test("returns relative POSIX paths and skips .git", () => {
    const dir = sandbox();
    writePackage(dir, { name: "x", version: "1.0.0" }, { "src/index.js": "1", "docs/a.md": "2" });
    mkdirSync(join(dir, ".git"), { recursive: true });
    writeFileSync(join(dir, ".git", "HEAD"), "ref: refs/heads/main");

    const paths = walkFiles(dir).map((f) => f.path);
    expect(paths).toContain("src/index.js");
    expect(paths).toContain("docs/a.md");
    expect(paths.some((p) => p.startsWith(".git/"))).toBe(false);
  });
});

describe("readTexts", () => {
  test("reads text files and skips source maps", () => {
    const dir = sandbox();
    writePackage(
      dir,
      { name: "x", version: "1.0.0" },
      { "a.js": "const a = 1;", "a.js.map": '{"version":3}', "logo.png": "binary" },
    );
    const texts = readTexts(walkFiles(dir));
    expect(texts.has("a.js")).toBe(true);
    expect(texts.has("a.js.map")).toBe(false);
    expect(texts.has("logo.png")).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// reporting helpers
// ---------------------------------------------------------------------------

describe("reporting", () => {
  test("summarise counts by severity", () => {
    const findings: Finding[] = [
      { code: "A", severity: "error", title: "t", detail: "d" },
      { code: "B", severity: "warn", title: "t", detail: "d" },
      { code: "C", severity: "warn", title: "t", detail: "d" },
      { code: "D", severity: "info", title: "t", detail: "d" },
    ];
    expect(summarise(findings)).toEqual({ errors: 1, warnings: 2, infos: 1 });
  });

  test("sortFindings puts failures first", () => {
    const findings: Finding[] = [
      { code: "I", severity: "info", title: "t", detail: "d" },
      { code: "E", severity: "error", title: "t", detail: "d" },
      { code: "W", severity: "warn", title: "t", detail: "d" },
    ];
    expect(sortFindings(findings).map((f) => f.code)).toEqual(["E", "W", "I"]);
  });

  test("firstLines drops blanks and gives up after n", () => {
    expect(firstLines("a\n\n  b  \nc\nd", 2)).toBe("a\nb");
  });

  test("formatReport names the failure and refuses to bless the package", () => {
    const report = formatReport({
      findings: [{ code: "TF001", severity: "error", title: "Entry point missing", detail: "d" }],
      sandbox: null,
      packageName: "x",
      packageVersion: "1.0.0",
      fileCount: 3,
      failed: true,
    });
    expect(report).toContain("TF001");
    expect(report).toContain("not safe to publish");
    expect(report).toContain("Does not prove host-runtime behaviour");
  });
});

// ---------------------------------------------------------------------------
// End to end against real tarballs
// ---------------------------------------------------------------------------

describe("check — end to end", () => {
  test("catches the oc-flight-deck@0.1.0 optional-peer release", async () => {
    const dir = sandbox();
    writePackage(
      dir,
      {
        name: "flight-deck-lookalike",
        version: "0.1.0",
        exports: { ".": { import: "./src/index.ts" } },
        files: ["src"],
        peerDependencies: { "@opentui/solid": ">=0.5.10" },
        peerDependenciesMeta: { "@opentui/solid": { optional: true } },
      },
      { "src/index.ts": `import { render } from "@opentui/solid";\nexport default render;` },
    );

    const result = await check(dir, { json: false, keep: false, noInstall: true, doImport: false });
    expect(result.failed).toBe(true);
    expect(result.fatal).toBeUndefined();
    expect(codes(result.findings)).toContain("TF002");
  });

  test("catches a build directory left out of the files whitelist", async () => {
    const dir = sandbox();
    writePackage(
      dir,
      { name: "missing-dist", version: "1.0.0", main: "./dist/index.js", files: ["src"] },
      { "src/index.ts": "export const x = 1;" },
    );

    const result = await check(dir, { json: false, keep: false, noInstall: true, doImport: false });
    expect(result.failed).toBe(true);
    expect(codes(result.findings)).toContain("TF001");
  });

  test("reads the published manifest, not the checkout's", async () => {
    // npm rewrites `files` into the tarball's own package.json; the check must
    // judge what ships. A `prepack` script proves the tarball is the input.
    const dir = sandbox();
    writePackage(
      dir,
      { name: "prepacked", version: "1.0.0", main: "./dist/index.js" },
      { "src/index.ts": "export const x = 1;" },
    );
    writeFileSync(
      join(dir, "package.json"),
      JSON.stringify(
        {
          name: "prepacked",
          version: "1.0.0",
          main: "./dist/index.js",
          scripts: { prepack: "node -e \"require('fs').mkdirSync('dist');require('fs').writeFileSync('dist/index.js','')\"" },
        },
        null,
        2,
      ),
    );

    const result = await check(dir, { json: false, keep: false, noInstall: true, doImport: false });
    expect(codes(result.findings)).not.toContain("TF001");
  });

  test("a clean package passes with only the ok marker", async () => {
    const dir = sandbox();
    writePackage(
      dir,
      { name: "clean-fixture", version: "1.0.0", main: "./src/index.js", files: ["src"] },
      { "src/index.js": "export const x = 1;" },
    );

    const result = await check(dir, { json: false, keep: false, noInstall: true, doImport: false });
    expect(result.failed).toBe(false);
    expect(codes(result.findings)).toEqual(["TF000"]);
    expect(result.packageName).toBe("clean-fixture");
  });

  test("a missing target is a fatal, not a finding", async () => {
    const result = await check(join(sandbox(), "nope"), {
      json: false,
      keep: false,
      noInstall: true,
      doImport: false,
    });
    expect(result.fatal).toContain("no such file or directory");
  });

  test("--keep leaves the sandbox behind", async () => {
    const dir = sandbox();
    writePackage(
      dir,
      { name: "keep-fixture", version: "1.0.0", main: "./src/index.js", files: ["src"] },
      { "src/index.js": "export const x = 1;" },
    );

    const result = await check(dir, {
      json: false,
      keep: true,
      noInstall: true,
      doImport: false,
    });
    expect(result.sandbox).toBeTruthy();
    const kept = result.sandbox as string;
    expect(existsSync(kept)).toBe(true);
    // The tarball, the extracted tree, and the sandbox manifest all survive.
    expect(existsSync(join(kept, "pkg", "package", "package.json"))).toBe(true);
    expect(walkFiles(kept).some((f) => f.path.endsWith(".tgz"))).toBe(true);
  });

  test("installs a dependency-free package for real and passes it", async () => {
    // The step `npm pack --dry-run` cannot do. No dependencies means this
    // resolves offline, so the test stays hermetic.
    const dir = sandbox();
    writePackage(
      dir,
      { name: "installs-cleanly", version: "1.0.0", main: "./src/index.js", files: ["src"] },
      { "src/index.js": "module.exports = { ok: true };" },
    );

    const result = await check(dir, { json: false, keep: false, noInstall: false, doImport: false });
    if (find(result.findings, "TF020")) {
      // Offline or no npm on PATH: report it rather than pretending.
      expect(find(result.findings, "TF020")?.severity).toBe("warn");
    } else {
      expect(result.failed).toBe(false);
    }
  });
});
