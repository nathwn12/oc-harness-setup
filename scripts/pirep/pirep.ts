#!/usr/bin/env bun
/**
 * pirep — which models and agents actually perform, measured from history.
 *
 * One question, answered from real OpenCode turns instead of assumptions:
 * which models and agents do the work, how much they process, how often
 * they fail, and what the metered ones cost.
 *
 * Design rules, in order of importance:
 *
 *  1. Never price an unpriced model. Subscription (limit-based, not
 *     token-based) models record a cost of 0 with real token counts — that
 *     zero is correct, there is no per-token bill (concrete example:
 *     `openai/gpt-5.6-luna`). Real tokens plus zero recorded cost means
 *     "no metered cost recorded". Metered and unpriced models are reported
 *     in separate sections and never summed or averaged together: an
 *     unpriced model would always look free and always "win" a cost
 *     ranking, which is a recommendation engine confidently recommending
 *     the wrong thing. Every cost figure that excludes unpriced turns is
 *     labelled as partial.
 *  2. The host database is opened READ-ONLY and never written.
 *  3. Field names are read defensively, and were verified against the real
 *     database rather than assumed. Assistant turns carry the model nested at
 *     `model.{id,providerID,variant}`, tokens at
 *     `tokens.{input,output,reasoning,cache.{read,write}}`, plus `cost`,
 *     `time.{created,streamed,completed}`, `agent`, and `error`. The flat
 *     `modelID` / `providerID` fields are kept as a fallback but appear on no
 *     row inspected; `mode` is always null and is not read. A row that cannot
 *     be understood is skipped and counted, never guessed at. A row with a
 *     `time` but no `tokens` yet is a mid-stream write, not a zero-token turn,
 *     and is skipped too.
 *  4. Speed is streaming speed. Output tokens-per-second is measured over
 *     `time.streamed - time.created` — the window the model spent producing
 *     output — and never over `time.completed - time.created`, which also
 *     spans tool execution and would report every model as slower than it is.
 *     Where the host recorded no stream completion the turn gets no speed
 *     rather than a number that measures something else.
 *  5. Degrade quietly: a missing or unreadable database, or an unexpected
 *     host schema, prints one clear line and exits non-zero. It never
 *     throws a stack trace at you.
 *
 * Usage:
 *   pirep                    full report: metered models, unpriced models, agents
 *   pirep --models           models only
 *   pirep --agents           agents only
 *   pirep --since=YYYY-MM-DD only turns on or after this date
 *   pirep --limit=N          cap rows per section
 *   pirep --json             machine-readable output
 *   pirep --help             this text
 */

import { Database } from "bun:sqlite";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HOME = homedir();

/** Overridable so the suite can run against fixtures instead of your history. */
const SOURCE_DB =
  process.env["PIREP_SOURCE"] ?? join(HOME, ".local", "share", "opencode", "opencode.db");

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

export interface Turn {
  readonly model: string;
  readonly provider: string;
  readonly modelId: string;
  readonly agent: string;
  readonly sessionId: string;
  /** Millisecond epoch. Falls back to the row's time_created when the payload carries none. */
  readonly ts: number;
  readonly input: number;
  readonly output: number;
  readonly reasoning: number;
  readonly cacheRead: number;
  readonly cacheWrite: number;
  readonly cost: number;
  /**
   * The turn's streaming window: `time.streamed` minus `time.created`.
   *
   * This is time the model spent producing output, which is what a
   * tokens-per-second figure means. It is deliberately NOT
   * `time.completed - time.created`, which also spans tool execution and
   * post-processing and would report a model as slower than it is.
   *
   * Undefined when the host recorded no stream completion — the turn is then
   * reported with no speed rather than given a number that measures something
   * else.
   */
  readonly streamMs: number | undefined;
  /** True when the payload carries a non-null `error` field (includes aborts/cancels). */
  readonly failed: boolean;
}

export interface ModelStat {
  readonly model: string;
  readonly provider: string;
  readonly id: string;
  readonly metered: boolean;
  readonly turns: number;
  readonly sessions: number;
  readonly input: number;
  readonly output: number;
  readonly reasoning: number;
  readonly cacheRead: number;
  readonly cacheWrite: number;
  readonly cacheHitRate: number | undefined;
  readonly medianTokPerSec: number | undefined;
  readonly totalCost: number;
  /** Metered models only; undefined for unpriced models (never invent a price). */
  readonly medianTurnCost: number | undefined;
  readonly failureRate: number;
}

export interface AgentStat {
  readonly agent: string;
  readonly turns: number;
  readonly sessions: number;
  readonly input: number;
  readonly output: number;
  readonly reasoning: number;
  readonly cacheRead: number;
  readonly cacheWrite: number;
  readonly cacheHitRate: number | undefined;
  readonly medianTokPerSec: number | undefined;
  /** Sum of recorded costs on metered turns only; excludes unpriced turns, so partial. */
  readonly meteredCostPartial: number;
  readonly failureRate: number;
}

export interface Report {
  readonly scanned: number;
  readonly skipped: number;
  readonly turns: number;
  readonly sessions: number;
  readonly metered: readonly ModelStat[];
  readonly unpriced: readonly ModelStat[];
  /** Sum over metered turns only. Partial by construction. */
  readonly totalMeteredCost: number;
  readonly unpricedTurns: number;
  readonly agents: readonly AgentStat[];
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/** Minimal shape checks — the host schema is not ours and must not be trusted. */
function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : undefined;
}

function asText(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  // Untrusted host rows are text, never terminal instructions: strip C0 control
  // characters (including ESC) so a crafted field cannot emit an escape
  // sequence (e.g. OSC-52 clipboard writes) into the terminal.
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, "");
  return cleaned.trim().length > 0 ? cleaned.trim() : undefined;
}

/** A finite, non-negative number, or zero. Negatives are clamped, not rejected. */
function asCount(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}

function asMillis(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

export interface TurnRow {
  readonly id: string;
  readonly session_id: string;
  readonly type: string;
  readonly time_created: number;
  readonly data: string;
}

/**
 * One `session_message` row becomes zero or one turns. Anything ambiguous —
 * bad JSON, no resolvable model, a non-assistant role — is skipped (the
 * caller counts it) rather than guessed at.
 */
export function parseTurn(row: TurnRow): Turn | undefined {
  if (row.type !== "assistant") return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(row.data);
  } catch {
    return undefined;
  }
  const message = asRecord(parsed);
  if (message === undefined) return undefined;

  // v1 rows carry an explicit role; v2 rows omit it (the SQL type column
  // already filtered to assistant), so only a present non-assistant role rejects.
  const role = message["role"];
  if (role !== undefined && role !== "assistant") return undefined;

  // The nested `model` object is what this host writes (verified against
  // session_message rows). The flat v1 fields are kept as a fallback for older
  // rows; they are absent on every row inspected here.
  const nested = asRecord(message["model"]);
  const modelId = asText(nested?.["id"]) ?? asText(message["modelID"]);
  if (modelId === undefined) return undefined;
  const provider = asText(nested?.["providerID"]) ?? asText(message["providerID"]) ?? "unknown";

  // A turn with no token accounting is not a turn with zero tokens. The host
  // writes assistant rows mid-stream with `time` but no `tokens` yet; counting
  // those as zero-token turns would skew every average, so they are skipped and
  // counted instead.
  const tokens = asRecord(message["tokens"]);
  if (tokens === undefined) return undefined;

  const cache = asRecord(tokens["cache"]);
  const input = asCount(tokens["input"]);
  const output = asCount(tokens["output"]);
  const reasoning = asCount(tokens["reasoning"]);
  const cacheRead = asCount(cache?.["read"]);
  const cacheWrite = asCount(cache?.["write"]);

  const cost = asCount(message["cost"]);

  const time = asRecord(message["time"]);
  const created = asMillis(time?.["created"]) ?? asMillis(row.time_created) ?? 0;
  const streamed = asMillis(time?.["streamed"]);
  const streamMs = streamed !== undefined && streamed > created ? streamed - created : undefined;

  // `agent` is the field this host writes; `mode` is never populated.
  const agent = asText(message["agent"]) ?? "unknown";
  const failed = message["error"] !== undefined && message["error"] !== null;

  return {
    model: `${provider}/${modelId}`,
    provider,
    modelId,
    agent,
    sessionId: row.session_id,
    ts: created,
    input,
    output,
    reasoning,
    cacheRead,
    cacheWrite,
    cost,
    streamMs,
    failed,
  };
}

/** Median of a set of samples; undefined when there is nothing to summarise. */
export function median(values: readonly number[]): number | undefined {
  if (values.length === 0) return undefined;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) return sorted[mid];
  const lo = sorted[mid - 1] ?? 0;
  const hi = sorted[mid] ?? 0;
  return (lo + hi) / 2;
}

/** Cache hit rate, the same definition `opencode stats` uses: read / (read + input). */
export function cacheHitRate(read: number, input: number): number | undefined {
  return read + input > 0 ? read / (read + input) : undefined;
}

/** Output speed for one turn, measured over its streaming window. */
export function turnTokPerSec(turn: Turn): number | undefined {
  if (turn.streamMs === undefined || turn.streamMs <= 0 || turn.output <= 0) return undefined;
  return turn.output / (turn.streamMs / 1000);
}

// ---------------------------------------------------------------------------
// Collection and aggregation
// ---------------------------------------------------------------------------

export function collectTurns(
  source: Database,
  sinceMs?: number,
): { turns: Turn[]; scanned: number; skipped: number } {
  const turns: Turn[] = [];
  let scanned = 0;
  let skipped = 0;
  const consume = (row: TurnRow): void => {
    scanned += 1;
    try {
      const turn = parseTurn(row);
      if (turn === undefined) skipped += 1;
      else turns.push(turn);
    } catch {
      // One unreadable message must not abandon the other tens of thousands.
      skipped += 1;
    }
  };
  // `--since` is a SQL predicate, not a JS filter: with the index on
  // time_created this is a range scan instead of a full-table read that then
  // throws most rows away.
  if (sinceMs === undefined) {
    const rows = source.query<TurnRow, []>(
      `select id, session_id, type, time_created, data from session_message where type = 'assistant'`,
    );
    for (const row of rows.iterate()) consume(row);
  } else {
    const rows = source.query<TurnRow, [number]>(
      `select id, session_id, type, time_created, data from session_message where type = 'assistant' and time_created >= ?`,
    );
    for (const row of rows.iterate(sinceMs)) consume(row);
  }
  return { turns, scanned, skipped };
}

function statForModel(model: string, provider: string, id: string, turns: readonly Turn[]): ModelStat {
  const sessions = new Set(turns.map((turn) => turn.sessionId)).size;
  let input = 0;
  let output = 0;
  let reasoning = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let failed = 0;
  let totalCost = 0;
  const speeds: number[] = [];
  const costs: number[] = [];
  for (const turn of turns) {
    input += turn.input;
    output += turn.output;
    reasoning += turn.reasoning;
    cacheRead += turn.cacheRead;
    cacheWrite += turn.cacheWrite;
    if (turn.failed) failed += 1;
    totalCost += turn.cost;
    costs.push(turn.cost);
    const speed = turnTokPerSec(turn);
    if (speed !== undefined) speeds.push(speed);
  }
  // The hard rule: any recorded cost makes the model metered; real tokens
  // with zero recorded cost is a subscription-style model, not a free one.
  const metered = totalCost > 0;
  return {
    model,
    provider,
    id,
    metered,
    turns: turns.length,
    sessions,
    input,
    output,
    reasoning,
    cacheRead,
    cacheWrite,
    cacheHitRate: cacheHitRate(cacheRead, input),
    medianTokPerSec: median(speeds),
    totalCost,
    medianTurnCost: metered ? median(costs) : undefined,
    failureRate: turns.length > 0 ? failed / turns.length : 0,
  };
}

function statForAgent(agent: string, turns: readonly Turn[]): AgentStat {
  const sessions = new Set(turns.map((turn) => turn.sessionId)).size;
  let input = 0;
  let output = 0;
  let reasoning = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let failed = 0;
  let meteredCostPartial = 0;
  const speeds: number[] = [];
  for (const turn of turns) {
    input += turn.input;
    output += turn.output;
    reasoning += turn.reasoning;
    cacheRead += turn.cacheRead;
    cacheWrite += turn.cacheWrite;
    if (turn.failed) failed += 1;
    // Agent turns mix metered and unpriced models, so no median and no
    // total: only the metered slice, labelled partial.
    if (turn.cost > 0) meteredCostPartial += turn.cost;
    const speed = turnTokPerSec(turn);
    if (speed !== undefined) speeds.push(speed);
  }
  return {
    agent,
    turns: turns.length,
    sessions,
    input,
    output,
    reasoning,
    cacheRead,
    cacheWrite,
    cacheHitRate: cacheHitRate(cacheRead, input),
    medianTokPerSec: median(speeds),
    meteredCostPartial,
    failureRate: turns.length > 0 ? failed / turns.length : 0,
  };
}

function byTurnsDesc(a: { turns: number; model?: string; agent?: string }, b: { turns: number; model?: string; agent?: string }): number {
  return b.turns - a.turns || String(a.model ?? a.agent).localeCompare(String(b.model ?? b.agent));
}

export function aggregate(turns: readonly Turn[]): Report {
  const byModel = new Map<string, Turn[]>();
  const byAgent = new Map<string, Turn[]>();
  for (const turn of turns) {
    const models = byModel.get(turn.model);
    if (models === undefined) byModel.set(turn.model, [turn]);
    else models.push(turn);
    const agents = byAgent.get(turn.agent);
    if (agents === undefined) byAgent.set(turn.agent, [turn]);
    else agents.push(turn);
  }

  const metered: ModelStat[] = [];
  const unpriced: ModelStat[] = [];
  let totalMeteredCost = 0;
  let unpricedTurns = 0;
  for (const [model, modelTurns] of byModel) {
    const first = modelTurns[0];
    if (first === undefined) continue;
    const stat = statForModel(model, first.provider, first.modelId, modelTurns);
    if (stat.metered) {
      metered.push(stat);
      totalMeteredCost += stat.totalCost;
    } else {
      unpriced.push(stat);
      unpricedTurns += stat.turns;
    }
  }
  metered.sort(byTurnsDesc);
  unpriced.sort(byTurnsDesc);

  const agents: AgentStat[] = [...byAgent].map(([agent, agentTurns]) => statForAgent(agent, agentTurns));
  agents.sort(byTurnsDesc);

  return {
    scanned: 0,
    skipped: 0,
    turns: turns.length,
    sessions: new Set(turns.map((turn) => turn.sessionId)).size,
    metered,
    unpriced,
    totalMeteredCost,
    unpricedTurns,
    agents,
  };
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

function fmtInt(n: number): string {
  return Math.round(n).toString();
}

function fmtCost(n: number): string {
  if (n === 0) return "$0";
  if (n >= 1) return `$${n.toFixed(2)}`;
  return `$${n.toFixed(4)}`;
}

function fmtPct(rate: number | undefined): string {
  return rate === undefined ? "-" : `${(rate * 100).toFixed(1)}%`;
}

function fmtSpeed(speed: number | undefined): string {
  return speed === undefined ? "-" : speed.toFixed(1);
}

/**
 * Column padding that never hides data.
 *
 * The first version sliced an over-long value down to the column width, which
 * silently corrupted exactly the numbers this report exists to show — a ten
 * digit token total came out as its last nine digits with no indication. A
 * column that is too narrow should look ragged, not lie.
 */
function padEnd(text: string, width: number): string {
  return text.length >= width ? text : text + " ".repeat(width - text.length);
}

function padStart(text: string, width: number): string {
  return text.length >= width ? text : " ".repeat(width - text.length) + text;
}

/**
 * Token totals are abbreviated for the report (`518`, `83.2M`, `1.4B`).
 *
 * They have to be: a single model's lifetime input can run to ten digits, which
 * would either blow the table apart or get truncated. `--json` carries the exact
 * integer counts for anything that needs them.
 */
export function fmtCount(n: number): string {
  const value = Math.round(n);
  if (value < 1_000) return String(value);
  // Round at each step and only stay in a unit while the rounded value fits —
  // 999_999 rounds to 1000k, which must promote to 1M rather than print "1000k".
  const thousands = Math.round(value / 1_000);
  if (thousands < 1_000) return `${thousands}k`;
  const millions = (value / 1_000_000).toFixed(1);
  if (Number(millions) < 1_000) {
    return `${millions.endsWith(".0") ? millions.slice(0, -2) : millions}M`;
  }
  const billions = (value / 1_000_000_000).toFixed(2);
  return `${billions.endsWith(".00") ? billions.slice(0, -3) : billions}B`;
}

export interface ViewOptions {
  readonly modelsOnly: boolean;
  readonly agentsOnly: boolean;
  readonly limit: number;
  readonly sinceLabel: string | undefined;
}

const METERING_NOTE =
  "metered and unpriced models are never summed or averaged together: a model with no metered cost would always look free and always win a cost ranking.";
const PARTIAL_NOTE = "every cost figure excludes unpriced turns and is partial.";
const SPEED_NOTE =
  "out-tok/s is measured over each turn's streaming window (time.streamed minus time.created), so it is model throughput and excludes tool execution; - means the host recorded no stream completion for that turn.";
const COUNTS_NOTE =
  "token columns are abbreviated (k/M/B) so a lifetime total fits the table; --json carries the exact integers.";
const FAILURE_NOTE = "failure rate counts turns with a non-null error field (includes aborts/cancels), not judged quality.";

interface Column {
  readonly head: string;
  readonly width: number;
  /** Numbers right-align; the trailing model/agent name is left-aligned. */
  readonly align?: "left" | "right";
}

/**
 * One definition per table, so the header and the body cannot drift apart and no
 * cell is ever cut to fit. The name goes last because it is the only
 * variable-width field: an unexpectedly long model name then pushes outwards
 * instead of shoving every number out of its column.
 */
function renderTable(columns: readonly Column[], rows: readonly (readonly string[])[]): string[] {
  const pad = (text: string, column: Column | undefined): string => {
    if (column === undefined) return text;
    return column.align === "left" ? padEnd(text, column.width) : padStart(text, column.width);
  };
  const line = (cells: readonly string[]) =>
    cells.map((value, index) => pad(value, columns[index])).join("  ").trimEnd();
  return [line(columns.map((column) => column.head)), ...rows.map(line)];
}

const MODEL_COLUMNS: readonly Column[] = [
  { head: "turns", width: 6 },
  { head: "sess", width: 5 },
  { head: "in", width: 7 },
  { head: "out", width: 7 },
  { head: "cache-r", width: 7 },
  { head: "hit%", width: 6 },
  { head: "tok/s", width: 6 },
  { head: "cost", width: 9 },
  { head: "med-cost", width: 9 },
  { head: "fail%", width: 6 },
  { head: "model", width: 0, align: "left" },
];

const UNPRICED_MODEL_COLUMNS: readonly Column[] = MODEL_COLUMNS.filter(
  (column) => column.head !== "cost" && column.head !== "med-cost",
);

const AGENT_COLUMNS: readonly Column[] = [
  { head: "turns", width: 6 },
  { head: "sess", width: 5 },
  { head: "in", width: 7 },
  { head: "out", width: 7 },
  { head: "cache-r", width: 7 },
  { head: "hit%", width: 6 },
  { head: "tok/s", width: 6 },
  { head: "metered$*", width: 10 },
  { head: "fail%", width: 6 },
  { head: "agent", width: 0, align: "left" },
];

function modelCells(stat: ModelStat, showCost: boolean): string[] {
  const cells = [
    fmtInt(stat.turns),
    fmtInt(stat.sessions),
    fmtCount(stat.input),
    fmtCount(stat.output),
    fmtCount(stat.cacheRead),
    fmtPct(stat.cacheHitRate),
    fmtSpeed(stat.medianTokPerSec),
  ];
  if (showCost) cells.push(fmtCost(stat.totalCost), fmtCost(stat.medianTurnCost ?? 0));
  cells.push(fmtPct(stat.failureRate), stat.model);
  return cells;
}

function modelRows(stats: readonly ModelStat[], limit: number, showCost: boolean): string[] {
  const columns = showCost ? MODEL_COLUMNS : UNPRICED_MODEL_COLUMNS;
  const rows = stats.slice(0, limit).map((stat) => modelCells(stat, showCost));
  return renderTable(columns, rows.length > 0 ? rows : [["(none)"]]);
}

function agentRows(stats: readonly AgentStat[], limit: number): string[] {
  const rows = stats.slice(0, limit).map((stat) => [
    fmtInt(stat.turns),
    fmtInt(stat.sessions),
    fmtCount(stat.input),
    fmtCount(stat.output),
    fmtCount(stat.cacheRead),
    fmtPct(stat.cacheHitRate),
    fmtSpeed(stat.medianTokPerSec),
    fmtCost(stat.meteredCostPartial),
    fmtPct(stat.failureRate),
    stat.agent,
  ]);
  return renderTable(AGENT_COLUMNS, rows.length > 0 ? rows : [["(none)"]]);
}

export function formatReport(report: Report, source: string, opts: ViewOptions): string {
  const lines: string[] = [];
  const scope = opts.sinceLabel === undefined ? "all history" : `since ${opts.sinceLabel}`;
  lines.push("pirep — measured model and agent performance");
  lines.push(`source (read-only): ${source}`);
  lines.push(`scope: ${scope}`);
  lines.push(
    `scanned ${report.scanned} assistant messages: ${report.turns} turns across ${report.sessions} sessions` +
      (report.skipped > 0 ? `, ${report.skipped} skipped (unreadable)` : ""),
  );
  lines.push("");

  const showModels = !opts.agentsOnly;
  const showAgents = !opts.modelsOnly;

  if (showModels) {
    lines.push("Metered models (recorded cost above zero; med-cost is per-turn median of recorded cost):");
    lines.push(...modelRows(report.metered, opts.limit, true));
    lines.push(
      `total metered cost ${fmtCost(report.totalMeteredCost)} (partial: excludes ${report.unpricedTurns} unpriced turns)`,
    );
    lines.push("");
    lines.push("Unpriced models (no metered cost recorded — real tokens, zero cost, e.g. subscription models):");
    lines.push(...modelRows(report.unpriced, opts.limit, false));
    lines.push("cost columns omitted here on purpose: a zero-cost model would always win a cost ranking.");
    lines.push("");
  }

  if (showAgents) {
    lines.push("Agents (turns mix models; metered$* counts metered turns only, partial):");
    lines.push(...agentRows(report.agents, opts.limit));
    lines.push("");
  }

  lines.push(`notes: ${METERING_NOTE}`);
  lines.push(`notes: ${COUNTS_NOTE}`);
  lines.push(`notes: ${PARTIAL_NOTE}`);
  lines.push(`notes: ${SPEED_NOTE}`);
  lines.push(`notes: ${FAILURE_NOTE}`);
  return lines.join("\n");
}

export interface JsonPayload {
  readonly source: string;
  readonly since: string | null;
  readonly scanned: number;
  readonly skipped: number;
  readonly turns: number;
  readonly sessions: number;
  readonly limit: number | null;
  readonly totalMeteredCostPartial: number;
  readonly unpricedTurns: number;
  readonly metered: readonly ModelStat[];
  readonly unpriced: readonly ModelStat[];
  readonly agents: readonly AgentStat[];
  readonly notes: readonly string[];
}

export function buildPayload(
  report: Report,
  source: string,
  sinceLabel: string | undefined,
  limit: number | undefined,
): JsonPayload {
  return {
    source,
    since: sinceLabel ?? null,
    scanned: report.scanned,
    skipped: report.skipped,
    turns: report.turns,
    sessions: report.sessions,
    limit: limit ?? null,
    totalMeteredCostPartial: report.totalMeteredCost,
    unpricedTurns: report.unpricedTurns,
    metered: limit === undefined ? report.metered : report.metered.slice(0, limit),
    unpriced: limit === undefined ? report.unpriced : report.unpriced.slice(0, limit),
    agents: limit === undefined ? report.agents : report.agents.slice(0, limit),
    notes: [METERING_NOTE, PARTIAL_NOTE, SPEED_NOTE, FAILURE_NOTE],
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

export interface Args {
  readonly json: boolean;
  readonly sinceLabel: string | undefined;
  readonly sinceMs: number | undefined;
  readonly limit: number | undefined;
  readonly modelsOnly: boolean;
  readonly agentsOnly: boolean;
  readonly help: boolean;
  readonly error: string | undefined;
}

export function parseArgs(argv: readonly string[]): Args {
  let json = false;
  let sinceLabel: string | undefined;
  let sinceMs: number | undefined;
  let limit: number | undefined;
  let modelsOnly = false;
  let agentsOnly = false;
  let help = false;
  let error: string | undefined;

  for (const arg of argv) {
    if (arg === "--json") json = true;
    else if (arg === "--models") modelsOnly = true;
    else if (arg === "--agents") agentsOnly = true;
    else if (arg === "--help" || arg === "-h") help = true;
    else if (arg.startsWith("--since=")) {
      const value = arg.slice("--since=".length);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) {
        error = `bad --since value ${JSON.stringify(value)} (want YYYY-MM-DD)`;
        break;
      }
      sinceLabel = value;
      sinceMs = Date.parse(`${value}T00:00:00Z`);
    } else if (arg.startsWith("--limit=")) {
      const value = Number(arg.slice("--limit=".length));
      if (!Number.isInteger(value) || value <= 0) {
        error = `bad --limit value ${JSON.stringify(arg.slice("--limit=".length))} (want a positive integer)`;
        break;
      }
      limit = value;
    } else if (arg.startsWith("--")) {
      error = `unknown flag ${JSON.stringify(arg)}`;
      break;
    } else {
      error = `unexpected argument ${JSON.stringify(arg)} (pirep takes flags only)`;
      break;
    }
  }

  return { json, sinceLabel, sinceMs, limit, modelsOnly, agentsOnly, help, error };
}

const USAGE = `pirep — which models and agents actually perform, measured from history

  pirep                    full report: metered models, unpriced models, agents
  pirep --models           models only
  pirep --agents           agents only
  pirep --since=YYYY-MM-DD only turns on or after this date
  pirep --limit=N          cap rows per section
  pirep --json             machine-readable output
  pirep --help             this text

Source (read-only): ${SOURCE_DB}`;

async function main(): Promise<number> {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    console.log(USAGE);
    return 0;
  }
  if (args.error !== undefined) {
    console.error(`pirep: ${args.error}`);
    console.error(USAGE);
    return 1;
  }

  if (!existsSync(SOURCE_DB)) {
    console.error(`pirep: no history found at ${SOURCE_DB}`);
    return 1;
  }

  let source: Database;
  try {
    // The one promise that matters: this is a reader, never a writer.
    source = new Database(SOURCE_DB, { readonly: true });
  } catch {
    console.error(`pirep: cannot read history at ${SOURCE_DB}`);
    return 1;
  }

  let collected: { turns: Turn[]; scanned: number; skipped: number };
  try {
    collected = collectTurns(source, args.sinceMs);
  } catch {
    console.error(`pirep: cannot read history at ${SOURCE_DB}`);
    return 1;
  } finally {
    try {
      source.close();
    } catch {
      /* closing a read-only handle must not fail the report */
    }
  }

  const report = aggregate(collected.turns);
  const full: Report = { ...report, scanned: collected.scanned, skipped: collected.skipped };

  // The human string is for text mode only: --json must always emit a valid
  // payload (an empty one when the scope has no turns) so JSON consumers never
  // receive prose.
  if (full.turns === 0 && !args.json) {
    console.log("no assistant turns found for this scope.");
    return 0;
  }

  if (args.json) {
    console.log(JSON.stringify(buildPayload(full, SOURCE_DB, args.sinceLabel, args.limit), null, 2));
    return 0;
  }
  console.log(
    formatReport(full, SOURCE_DB, {
      modelsOnly: args.modelsOnly,
      agentsOnly: args.agentsOnly,
      limit: args.limit ?? Number.MAX_SAFE_INTEGER,
      sinceLabel: args.sinceLabel,
    }),
  );
  return 0;
}

// Importing this module (from the test suite) must not run the CLI.
if (import.meta.main) process.exit(await main());
