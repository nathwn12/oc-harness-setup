// Pirep's behaviour, pinned. The two things that could quietly mislead here —
// a mis-parsed host payload, and a zero-cost subscription model leaking into
// a cost ranking — both fail loudly here instead.

import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  aggregate,
  buildPayload,
  cacheHitRate,
  collectTurns,
  fmtCount,
  formatReport,
  median,
  parseArgs,
  parseTurn,
  turnTokPerSec,
  type Turn,
} from "./pirep.ts";

const CLIENT = join(import.meta.dir, "pirep.ts");

interface Row {
  id: string;
  session_id: string;
  type: string;
  time_created: number;
  time_updated: number;
  data: string;
}

const row = (over: Partial<Row> & { id: string; type: string; data: unknown }): Row => ({
  session_id: "ses_a",
  time_created: 1_783_882_279_705,
  time_updated: 1_783_882_279_705,
  ...over,
  session_id: over.session_id ?? "ses_a",
  data: JSON.stringify(over.data),
});

/**
 * A v2 assistant payload, shaped exactly like the rows in the real database:
 * model nested under `model`, `agent` at the top level, and a `time` carrying
 * `streamed` alongside `completed`.
 */
const v2 = (
  model: string,
  provider: string,
  cost: number,
  input: number,
  output: number,
  extra: Record<string, unknown> = {},
): Record<string, unknown> => ({
  time: { created: 1_783_882_279_705, streamed: 1_783_882_280_705, completed: 1_783_882_280_905 },
  agent: "build",
  model: { id: model, providerID: provider },
  finish: "stop",
  cost,
  tokens: { input, output, reasoning: 10, cache: { read: 500, write: 50 } },
  ...extra,
});

/** An older assistant payload: explicit role, flat modelID / providerID. */
const v1 = (
  model: string,
  provider: string,
  cost: number,
  input: number,
  output: number,
): Record<string, unknown> => ({
  role: "assistant",
  modelID: model,
  providerID: provider,
  agent: "plan",
  cost,
  tokens: { input, output, reasoning: 0, cache: { read: 0, write: 0 } },
  time: { created: 1_783_882_279_705, streamed: 1_783_882_281_705 },
});

/**
 * A miniature of the real host database: the tables pirep reads, and only
 * the columns it reads. If the host schema moves, these tests keep passing
 * while the real run fails loudly — which is the correct asymmetry.
 */
function fixtureDb(rows: readonly Row[]): Database {
  const db = new Database(":memory:");
  db.exec("create table session_v2(id text, title text, directory text)");
  db.exec(
    "create table session_message(id text, session_id text, type text, seq integer, time_created integer, time_updated integer, data text)",
  );
  db.exec("insert into session_v2 values('ses_a', 'Flight deck', 'C:/Users/alice/foo')");
  db.exec("insert into session_v2 values('ses_b', 'Planner', 'C:/Users/alice/bar')");
  const insert = db.query(
    "insert into session_message(id, session_id, type, seq, time_created, time_updated, data) values(?, ?, ?, 0, ?, ?, ?)",
  );
  for (const r of rows) {
    insert.run(r.id, r.session_id, r.type, r.time_created, r.time_updated, r.data);
  }
  return db;
}

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), "pirep-test-"));
}

describe("parseTurn", () => {
  test("reads the v2 nested shape: model.id, tokens, cost, time, agent", () => {
    const turn = parseTurn(row({ id: "m1", type: "assistant", data: v2("claude-sonnet-4", "anthropic", 0.0123, 5519, 20) }));
    expect(turn?.model).toBe("anthropic/claude-sonnet-4");
    expect(turn?.provider).toBe("anthropic");
    expect(turn?.input).toBe(5519);
    expect(turn?.output).toBe(20);
    expect(turn?.reasoning).toBe(10);
    expect(turn?.cacheRead).toBe(500);
    expect(turn?.cacheWrite).toBe(50);
    expect(turn?.cost).toBe(0.0123);
    expect(turn?.agent).toBe("build");
    expect(turn?.streamMs).toBe(1000);
    expect(turn?.failed).toBe(false);
  });

  test("reads the older flat shape", () => {
    const turn = parseTurn(row({ id: "m2", type: "assistant", data: v1("gpt-5", "openai", 0.05, 100, 50) }));
    expect(turn?.model).toBe("openai/gpt-5");
    expect(turn?.agent).toBe("plan");
    expect(turn?.streamMs).toBe(2000);
  });

  test("the nested model object wins over the flat fields", () => {
    // Verified against the database: every assistant row carries `model`, and
    // the flat `modelID` / `providerID` fields appear on none of them.
    const turn = parseTurn(
      row({
        id: "m3",
        type: "assistant",
        data: {
          ...v2("nested-model", "nested-provider", 0.01, 10, 5),
          role: "assistant",
          modelID: "top-level-model",
          providerID: "top-level-provider",
        },
      }),
    );
    expect(turn?.model).toBe("nested-provider/nested-model");
  });

  test("reads agent and ignores mode, which this host never populates", () => {
    const withMode = parseTurn(
      row({ id: "m4", type: "assistant", data: v2("m", "p", 0, 10, 5, { mode: "general", agent: "build" }) }),
    );
    expect(withMode?.agent).toBe("build");
    const bare = parseTurn(
      row({
        id: "m5",
        type: "assistant",
        data: { model: { id: "m", providerID: "p" }, cost: 0, tokens: { input: 1, output: 1 }, time: { created: 100 } },
      }),
    );
    expect(bare?.agent).toBe("unknown");
  });

  test("marks a non-null error field as failed, including aborts", () => {
    const failed = parseTurn(
      row({ id: "m6", type: "assistant", data: v2("m", "p", 0, 10, 5, { error: { message: "boom" } }) }),
    );
    expect(failed?.failed).toBe(true);
  });

  test("skips rows it cannot understand instead of guessing", () => {
    expect(parseTurn(row({ id: "u1", type: "user", data: { text: "hello" } }))).toBeUndefined();
    expect(
      parseTurn(row({ id: "w1", type: "assistant", data: { role: "user", text: "not a turn" } })),
    ).toBeUndefined();
    expect(
      parseTurn({ id: "j1", session_id: "s", type: "assistant", time_created: 0, data: "{not json" }),
    ).toBeUndefined();
    expect(
      parseTurn(row({ id: "n1", type: "assistant", data: { cost: 1, tokens: { input: 5, output: 5 } } })),
    ).toBeUndefined();
  });

  test("clamps negative tokens and cost to zero rather than propagating them", () => {
    const turn = parseTurn(
      row({
        id: "n2",
        type: "assistant",
        data: {
          model: { id: "m", providerID: "p" },
          cost: -1,
          tokens: { input: -100, output: -50, reasoning: -25, cache: { read: -200, write: -10 } },
          time: { created: 1_783_882_279_705 },
        },
      }),
    );
    expect(turn?.input).toBe(0);
    expect(turn?.output).toBe(0);
    expect(turn?.reasoning).toBe(0);
    expect(turn?.cacheRead).toBe(0);
    expect(turn?.cacheWrite).toBe(0);
    expect(turn?.cost).toBe(0);
  });

  test("leaves the streaming window absent when streamed is missing or not after created", () => {
    const missing = parseTurn(
      row({
        id: "d1",
        type: "assistant",
        data: { model: { id: "m", providerID: "p" }, cost: 0, tokens: { input: 1, output: 5 }, time: { created: 100 } },
      }),
    );
    expect(missing?.streamMs).toBeUndefined();
    const backwards = parseTurn(
      row({
        id: "d2",
        type: "assistant",
        data: {
          model: { id: "m", providerID: "p" },
          cost: 0,
          tokens: { input: 1, output: 5 },
          time: { created: 200, streamed: 100 },
        },
      }),
    );
    expect(backwards?.streamMs).toBeUndefined();
  });

  test("never measures speed from completed, which includes tool execution", () => {
    // `completed` runs long past the last token. Using it would report a model
    // as slower than it is, so a turn with only `completed` gets no speed.
    const turn = parseTurn(
      row({
        id: "d3",
        type: "assistant",
        data: {
          model: { id: "m", providerID: "p" },
          cost: 0,
          tokens: { input: 10, output: 500 },
          time: { created: 1_000, completed: 61_000 },
        },
      }),
    );
    expect(turn?.streamMs).toBeUndefined();
    expect(turn).toBeDefined();
    expect(turnTokPerSec(turn as Turn)).toBeUndefined();
  });

  test("skips a mid-stream row that has time but no tokens yet", () => {
    // The host writes these while a turn is still streaming. Counting one as a
    // zero-token turn would drag down every average it touches.
    const turn = parseTurn(
      row({
        id: "d4",
        type: "assistant",
        data: { model: { id: "m", providerID: "p" }, agent: "build", time: { created: 1_000, streamed: 2_000 } },
      }),
    );
    expect(turn).toBeUndefined();
  });

  test("falls back to the row timestamp when the payload carries no time", () => {
    const turn = parseTurn(
      row({
        id: "t1",
        type: "assistant",
        time_created: 1_700_000_000_000,
        data: { model: { id: "m", providerID: "p" }, cost: 0, tokens: { input: 1, output: 1 } },
      }),
    );
    expect(turn?.ts).toBe(1_700_000_000_000);
  });

  test("strips C0 control characters from untrusted fields before rendering", () => {
    // A crafted model.id could otherwise carry an OSC-52/clipboard escape into
    // the terminal. Untrusted rows are text, never terminal instructions.
    const turn = parseTurn(
      row({ id: "c1", type: "assistant", data: v2("\u001b]52;c;x", "p", 0.01, 10, 5) }),
    );
    expect(turn).toBeDefined();
    expect(turn?.model ?? "").not.toContain("\u001b");
    expect(turn?.modelId ?? "").not.toContain("\u001b");
  });
});

describe("maths", () => {
  test("median handles odd, even and empty sets", () => {
    expect(median([100])).toBe(100);
    expect(median([300, 100, 200])).toBe(200);
    expect(median([100, 300])).toBe(200);
    expect(median([])).toBeUndefined();
  });

  test("cache hit rate is read over read plus input", () => {
    expect(cacheHitRate(2000, 6000)).toBe(0.25);
    expect(cacheHitRate(0, 0)).toBeUndefined();
  });

  test("turn speed needs output and a real streaming window", () => {
    const base: Turn = {
      model: "p/m",
      provider: "p",
      modelId: "m",
      agent: "build",
      sessionId: "s",
      ts: 1,
      input: 10,
      output: 200,
      reasoning: 0,
      cacheRead: 0,
      cacheWrite: 0,
      cost: 0,
      streamMs: 1000,
      failed: false,
    };
    expect(turnTokPerSec(base)).toBe(200);
    expect(turnTokPerSec({ ...base, streamMs: undefined })).toBeUndefined();
    expect(turnTokPerSec({ ...base, output: 0 })).toBeUndefined();
  });
});

describe("fmtCount", () => {
  test("abbreviates without ever rounding up into the wrong unit", () => {
    expect(fmtCount(0)).toBe("0");
    expect(fmtCount(999)).toBe("999");
    expect(fmtCount(999_999)).toBe("1M");
    expect(fmtCount(1_000_000)).toBe("1M");
    expect(fmtCount(1_000_000_000)).toBe("1B");
  });

  test("trims the .0 and .00 branches, and keeps real decimals", () => {
    expect(fmtCount(2_000_000)).toBe("2M");
    expect(fmtCount(2_000_000_000)).toBe("2B");
    expect(fmtCount(1_500_000)).toBe("1.5M");
    expect(fmtCount(1_250_000_000)).toBe("1.25B");
  });
});

const METERED = "claude-sonnet-4";
const UNPRICED = "gpt-5.6-luna";

function mixedTurns(): Turn[] {
  const source = fixtureDb([
    row({ id: "a1", type: "assistant", data: v2(METERED, "anthropic", 0.01, 1000, 100) }),
    row({
      id: "a2",
      type: "assistant",
      data: v2(METERED, "anthropic", 0.02, 2000, 200, {
        time: { created: 1_783_882_279_705, streamed: 1_783_882_281_705 },
        tokens: { input: 2000, output: 200, reasoning: 10, cache: { read: 0, write: 0 } },
      }),
    }),
    row({
      id: "a3",
      type: "assistant",
      data: v2(METERED, "anthropic", 0.03, 3000, 300, { error: { message: "overloaded" } }),
    }),
    row({
      id: "b1",
      session_id: "ses_b",
      type: "assistant",
      data: { ...v2(UNPRICED, "openai", 0, 4000, 400, { agent: "plan" }), time: { created: 1_783_882_279_705 } },
    }),
    row({
      id: "b2",
      session_id: "ses_b",
      type: "assistant",
      data: { ...v2(UNPRICED, "openai", 0, 5000, 500, { agent: "plan" }), time: { created: 1_783_882_279_705 } },
    }),
  ]);
  const { turns } = collectTurns(source);
  source.close();
  return turns;
}

describe("aggregation and the metering split", () => {
  test("collects assistant turns and counts what it skips", () => {
    const source = fixtureDb([
      row({ id: "a1", type: "assistant", data: v2("m", "p", 0.01, 10, 5) }),
      row({ id: "u1", type: "user", data: { text: "hello" } }),
      { id: "j1", session_id: "ses_a", type: "assistant", time_created: 0, time_updated: 0, data: "{broken" },
    ]);
    const { turns, scanned, skipped } = collectTurns(source);
    // The user row never reaches the parser: the SQL already filters to assistant.
    expect(scanned).toBe(2);
    expect(turns).toHaveLength(1);
    expect(skipped).toBe(1);
    source.close();
  });

  test("a zero-cost model with real tokens is unpriced, labelled, and out of the cost maths", () => {
    const report = aggregate(mixedTurns());
    expect(report.metered.map((s) => s.model)).toEqual(["anthropic/claude-sonnet-4"]);
    expect(report.unpriced.map((s) => s.model)).toEqual(["openai/gpt-5.6-luna"]);
    expect(report.unpriced[0]?.metered).toBe(false);
    expect(report.unpriced[0]?.medianTurnCost).toBeUndefined();
    expect(report.unpriced[0]?.totalCost).toBe(0);
    // The metered side never sees the unpriced turns.
    expect(report.totalMeteredCost).toBeCloseTo(0.06, 10);
    expect(report.unpricedTurns).toBe(2);
    expect(report.metered[0]?.medianTurnCost).toBeCloseTo(0.02, 10);
  });

  test("per-model counts, cache hit rate, failure rate and streaming speed", () => {
    const report = aggregate(mixedTurns());
    const metered = report.metered[0];
    expect(metered?.turns).toBe(3);
    expect(metered?.sessions).toBe(1);
    expect(metered?.input).toBe(6000);
    expect(metered?.output).toBe(600);
    // cache reads: 500 + 0 + 500 over inputs of 6000.
    expect(metered?.cacheHitRate).toBeCloseTo(1000 / 7000, 10);
    expect(metered?.failureRate).toBeCloseTo(1 / 3, 10);
    // Streaming windows: 1s/100, 2s/200, 1s/300 -> 100, 100, 300 tok/s.
    expect(metered?.medianTokPerSec).toBe(100);
    // The unpriced turns record no streamed time, so they get no speed at all
    // rather than one measured against the wrong clock.
    expect(report.unpriced[0]?.medianTokPerSec).toBeUndefined();
  });

  test("agents aggregate turns but only ever carry a partial metered cost", () => {
    const report = aggregate(mixedTurns());
    const build = report.agents.find((a) => a.agent === "build");
    const plan = report.agents.find((a) => a.agent === "plan");
    expect(build?.turns).toBe(3);
    expect(build?.meteredCostPartial).toBeCloseTo(0.06, 10);
    expect(plan?.turns).toBe(2);
    expect(plan?.meteredCostPartial).toBe(0);
  });

  test("the SQL --since boundary is inclusive: a row exactly at the cutoff is kept, one ms under is dropped", () => {
    const sinceMs = Date.parse("2026-06-01T00:00:00Z");
    const source = fixtureDb([
      row({
        id: "at",
        type: "assistant",
        time_created: sinceMs,
        data: v2("m", "p", 0.01, 10, 5, { time: { created: sinceMs } }),
      }),
      row({
        id: "under",
        type: "assistant",
        time_created: sinceMs - 1,
        data: v2("m", "p", 0.01, 10, 5, { time: { created: sinceMs - 1 } }),
      }),
    ]);
    const { turns } = collectTurns(source, sinceMs);
    // `time_created >= ?` keeps the equal row and rejects the earlier one.
    expect(turns.map((t) => t.ts)).toEqual([sinceMs]);
    source.close();
  });

  test("pushes --since into SQL so pre-cutoff rows are never scanned", () => {
    const source = fixtureDb([
      row({ id: "new", type: "assistant", time_created: 1_783_882_279_705, data: v2("m", "p", 0.01, 10, 5) }),
      row({ id: "old", type: "assistant", time_created: 1_700_000_000_000, data: v2("m", "p", 0.01, 10, 5) }),
    ]);
    const { turns, scanned } = collectTurns(source, Date.parse("2026-06-01T00:00:00Z"));
    // The old row is excluded by the WHERE clause, not read and dropped in JS.
    expect(scanned).toBe(1);
    expect(turns).toHaveLength(1);
    source.close();
  });
});

describe("parseArgs", () => {
  test("empty flags mean the full report", () => {
    const args = parseArgs([]);
    expect(args).toMatchObject({ json: false, modelsOnly: false, agentsOnly: false, help: false });
    expect(args.error).toBeUndefined();
    expect(args.limit).toBeUndefined();
    expect(args.sinceMs).toBeUndefined();
  });

  test("accepts every documented flag", () => {
    const args = parseArgs(["--json", "--since=2026-06-01", "--limit=5", "--models", "--agents"]);
    expect(args.json).toBe(true);
    expect(args.sinceLabel).toBe("2026-06-01");
    expect(args.sinceMs).toBe(Date.parse("2026-06-01T00:00:00Z"));
    expect(args.limit).toBe(5);
    expect(args.modelsOnly).toBe(true);
    expect(args.agentsOnly).toBe(true);
    expect(args.error).toBeUndefined();
  });

  test("rejects bad dates, bad limits, unknown flags and positionals", () => {
    expect(parseArgs(["--since=06-01-2026"]).error).toMatch(/since/);
    expect(parseArgs(["--since=2026-13-40"]).error).toMatch(/since/);
    expect(parseArgs(["--limit=0"]).error).toMatch(/limit/);
    expect(parseArgs(["--limit=many"]).error).toMatch(/limit/);
    expect(parseArgs(["--frobnicate"]).error).toMatch(/unknown flag/);
    expect(parseArgs(["claude"]).error).toMatch(/flags only/);
  });
});

describe("payload and text shape", () => {
  test("the JSON shape carries the split, partial totals and the reason why", () => {
    const report = { ...aggregate(mixedTurns()), scanned: 5, skipped: 0 };
    const payload = buildPayload(report, "/fake/opencode.db", undefined, undefined);
    expect(payload.turns).toBe(5);
    expect(payload.sessions).toBe(2);
    expect(payload.metered).toHaveLength(1);
    expect(payload.unpriced).toHaveLength(1);
    expect(payload.unpriced[0]?.medianTurnCost).toBeUndefined();
    expect(payload.totalMeteredCostPartial).toBeCloseTo(0.06, 10);
    expect(payload.unpricedTurns).toBe(2);
    expect(payload.agents.length).toBeGreaterThan(0);
    expect(payload.notes.join(" ")).toMatch(/never summed or averaged together/);
    expect(payload.notes.join(" ")).toMatch(/partial/);
    // Serialises cleanly: no undefined fields, no functions.
    expect(() => JSON.stringify(payload)).not.toThrow();
  });

  test("a limit caps every section", () => {
    const report = { ...aggregate(mixedTurns()), scanned: 5, skipped: 0 };
    const payload = buildPayload(report, "/fake/opencode.db", undefined, 1);
    expect(payload.limit).toBe(1);
    expect(payload.metered).toHaveLength(1);
    expect(payload.unpriced).toHaveLength(1);
    expect(payload.agents).toHaveLength(1);
  });

  test("the text report labels the unpriced section and marks every cost partial", () => {
    const report = { ...aggregate(mixedTurns()), scanned: 5, skipped: 0 };
    const out = formatReport(
      report,
      "/fake/opencode.db",
      { modelsOnly: false, agentsOnly: false, limit: 10, sinceLabel: undefined },
    );
    expect(out).toContain("Metered models");
    expect(out).toContain("Unpriced models");
    expect(out).toContain("no metered cost recorded");
    const unpricedAt = out.indexOf("Unpriced models");
    expect(out.indexOf("openai/gpt-5.6-luna")).toBeGreaterThan(unpricedAt);
    expect(out).toContain("partial");
    expect(out).toContain("streaming window");
    expect(out).toContain("Agents");
  });

  test("--models and --agents narrow the text report", () => {
    const report = { ...aggregate(mixedTurns()), scanned: 5, skipped: 0 };
    const models = formatReport(
      report,
      "/fake/opencode.db",
      { modelsOnly: true, agentsOnly: false, limit: 10, sinceLabel: undefined },
    );
    expect(models).toContain("Metered models");
    expect(models).not.toContain("Agents (");
    const agents = formatReport(
      report,
      "/fake/opencode.db",
      { modelsOnly: false, agentsOnly: true, limit: 10, sinceLabel: undefined },
    );
    expect(agents).toContain("Agents (");
    expect(agents).not.toContain("Metered models");
  });
});

describe("cli", () => {
  function fixtureFile(): { dir: string; sourcePath: string } {
    const dir = tempDir();
    const sourcePath = join(dir, "source.db");
    const source = new Database(sourcePath);
    source.exec("create table session_v2(id text, title text, directory text)");
    source.exec(
      "create table session_message(id text, session_id text, type text, seq integer, time_created integer, time_updated integer, data text)",
    );
    source.exec("insert into session_v2 values('ses_a', 'Flight deck', 'C:/Users/alice/foo')");
    source.exec("insert into session_v2 values('ses_b', 'Planner', 'C:/Users/alice/bar')");
    const insert = source.query(
      "insert into session_message(id, session_id, type, seq, time_created, time_updated, data) values(?, ?, ?, 0, ?, ?, ?)",
    );
    const put = (id: string, session: string, type: string, ts: number, data: unknown): void => {
      insert.run(id, session, type, ts, ts, JSON.stringify(data));
    };
    put("a1", "ses_a", "assistant", 1_783_882_279_705, v2(METERED, "anthropic", 0.01, 1000, 100));
    put("a2", "ses_a", "assistant", 1_783_882_279_705, v2(METERED, "anthropic", 0.02, 2000, 200));
    put(
      "b1",
      "ses_b",
      "assistant",
      1_783_882_279_705,
      { ...v2(UNPRICED, "openai", 0, 4000, 400, { agent: "plan" }), time: { created: 1_783_882_279_705 } },
    );
    // Predates any plausible --since filter.
    put("old", "ses_a", "assistant", 1_700_000_000_000, {
      ...v2(METERED, "anthropic", 0.05, 500, 50),
      time: { created: 1_700_000_000_000, completed: 1_700_000_001_000 },
    });
    source.close();
    return { dir, sourcePath };
  }

  function run(args: readonly string[], sourcePath: string) {
    return Bun.spawnSync({
      cmd: ["bun", CLIENT, ...args],
      env: { ...process.env, PIREP_SOURCE: sourcePath },
      stdout: "pipe",
      stderr: "pipe",
    });
  }

  /** A source database with the one table pirep reads and no rows in it yet. */
  function bareDb(sourcePath: string): Database {
    const source = new Database(sourcePath);
    source.exec("create table session_v2(id text, title text, directory text)");
    source.exec(
      "create table session_message(id text, session_id text, type text, seq integer, time_created integer, time_updated integer, data text)",
    );
    return source;
  }

  test("no flags prints the full report with the metering split enforced", () => {
    const { dir, sourcePath } = fixtureFile();
    const ok = run([], sourcePath);
    expect(ok.exitCode).toBe(0);
    const out = ok.stdout.toString();
    expect(out).toContain("pirep");
    expect(out).toContain("Metered models");
    expect(out).toContain("Unpriced models");
    expect(out).toContain("no metered cost recorded");
    expect(out).toContain("anthropic/claude-sonnet-4");
    expect(out).toContain("openai/gpt-5.6-luna");
    expect(out).toContain("partial");
    expect(out).toContain("Agents");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--json reports the same split in machine-readable shape", () => {
    const { dir, sourcePath } = fixtureFile();
    const ok = run(["--json"], sourcePath);
    expect(ok.exitCode).toBe(0);
    const payload = JSON.parse(ok.stdout.toString());
    expect(payload.turns).toBe(4);
    expect(payload.metered).toHaveLength(1);
    expect(payload.unpriced).toHaveLength(1);
    expect(payload.unpriced[0].model).toBe("openai/gpt-5.6-luna");
    expect(payload.unpriced[0].medianTurnCost).toBeUndefined();
    expect(payload.totalMeteredCostPartial).toBeCloseTo(0.08, 10);
    expect(payload.notes.join(" ")).toMatch(/never summed or averaged together/);
    rmSync(dir, { recursive: true, force: true });
  });

  test("--since drops the old turn end to end", () => {
    const { dir, sourcePath } = fixtureFile();
    const ok = run(["--json", "--since=2026-06-01"], sourcePath);
    expect(ok.exitCode).toBe(0);
    const payload = JSON.parse(ok.stdout.toString());
    expect(payload.since).toBe("2026-06-01");
    expect(payload.turns).toBe(3);
    expect(payload.totalMeteredCostPartial).toBeCloseTo(0.03, 10);
    rmSync(dir, { recursive: true, force: true });
  });

  test("--limit caps each section end to end", () => {
    const { dir, sourcePath } = fixtureFile();
    const ok = run(["--json", "--limit=1"], sourcePath);
    expect(ok.exitCode).toBe(0);
    const payload = JSON.parse(ok.stdout.toString());
    expect(payload.metered).toHaveLength(1);
    rmSync(dir, { recursive: true, force: true });
  });

  test("a bad flag explains itself instead of throwing", () => {
    const { dir, sourcePath } = fixtureFile();
    const bad = run(["--bogus"], sourcePath);
    expect(bad.exitCode).toBe(1);
    expect(bad.stderr.toString()).toContain("unknown flag");
    rmSync(dir, { recursive: true, force: true });
  });

  test("explains itself instead of throwing when there is no history to read", () => {
    const dir = tempDir();
    const missing = run([], join(dir, "does-not-exist.db"));
    expect(missing.exitCode).toBe(1);
    expect(missing.stderr.toString()).toContain("no history found");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--help does not touch a database at all", () => {
    const dir = tempDir();
    const help = run(["--help"], join(dir, "nope.db"));
    expect(help.exitCode).toBe(0);
    expect(help.stdout.toString()).toContain("pirep");
    rmSync(dir, { recursive: true, force: true });
  });

  test("an existing database with only user rows is an empty scope, not an error", () => {
    const dir = tempDir();
    const sourcePath = join(dir, "source.db");
    const source = bareDb(sourcePath);
    source.exec("insert into session_message values('u1', 'ses_a', 'user', 0, 1, 1, '{\"text\":\"hi\"}')");
    source.close();
    const ok = run([], sourcePath);
    expect(ok.exitCode).toBe(0);
    expect(ok.stdout.toString()).toContain("no assistant turns found");
    rmSync(dir, { recursive: true, force: true });
  });

  test("--json keeps its contract on an empty scope", () => {
    const { dir, sourcePath } = fixtureFile();
    const ok = run(["--json", "--since=2999-01-01"], sourcePath);
    expect(ok.exitCode).toBe(0);
    // stdout must be valid JSON even when there is nothing to report.
    const payload = JSON.parse(ok.stdout.toString());
    expect(payload.turns).toBe(0);
    expect(payload.metered).toEqual([]);
    expect(payload.unpriced).toEqual([]);
    expect(payload.agents).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  test("a crafted model id cannot emit terminal escapes", () => {
    const dir = tempDir();
    const sourcePath = join(dir, "source.db");
    const source = bareDb(sourcePath);
    const insert = source.query(
      "insert into session_message(id, session_id, type, seq, time_created, time_updated, data) values(?, ?, ?, 0, ?, ?, ?)",
    );
    insert.run(
      "e1",
      "ses_a",
      "assistant",
      1_783_882_279_705,
      1_783_882_279_705,
      JSON.stringify(v2("\u001b]52;c;x", "evil", 0.01, 10, 5)),
    );
    source.close();
    const ok = run([], sourcePath);
    expect(ok.exitCode).toBe(0);
    expect(ok.stdout.toString()).not.toContain("\u001b");
    rmSync(dir, { recursive: true, force: true });
  });
});
