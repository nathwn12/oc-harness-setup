#!/usr/bin/env bun
/**
 * logbook — the readable half of your OpenCode history.
 *
 * Every session you have ever run is still on disk, but it is write-only:
 * nothing can search it, so problems get solved for the first time, every time.
 * This makes it readable.
 *
 * Design rules, in order of importance:
 *
 *  1. The host database is opened READ-ONLY and never written. The index is a
 *     separate file this tool owns.
 *  2. The index is derived data. If it is ever wrong or corrupt, deleting it and
 *     re-running is always safe — `--reindex` does exactly that.
 *  3. Secret-shaped strings are scrubbed before they are indexed. Your messages
 *     contain pasted tokens; an index is a new place for them to leak from.
 *  4. Degrade quietly: a missing index, an unreadable database, or an unexpected
 *     host schema prints a clear message and exits non-zero. It never throws a
 *     stack trace at you.
 *
 * Usage:
 *   logbook "lastexitcode"          search
 *   logbook --precedent "<error>"   find prior occurrences of a failure
 *   logbook --precedent             ...reading the error from stdin
 *   logbook --stats                 what is in the index
 *   logbook --reindex               rebuild from scratch
 *   logbook --json                  machine-readable output
 */

import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HOME = homedir();

/** Overridable so the suite can run against fixtures instead of your history. */
const SOURCE_DB =
  process.env["LOGBOOK_SOURCE"] ?? join(HOME, ".local", "share", "opencode", "opencode.db");
const INDEX_DB = process.env["LOGBOOK_INDEX"] ?? join(HOME, ".opencode", "logbook", "index.db");

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

/**
 * A seatbelt, not a guarantee — same tradeoff as any secret scanner. The goal is
 * that the index is not a *new* place for credentials to accumulate. Unknown
 * formats will get through; that is stated rather than hidden.
 */
const SECRET_PATTERNS: readonly RegExp[] = [
  /\b(?:npm|ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}\b/g,
  /\bsk-[A-Za-z0-9_-]{16,}\b/g,
  /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bAIza[0-9A-Za-z_-]{30,}\b/g,
  /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, // JWT
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
];

/** `key=value` / `key: value` forms keep the key so the context survives. */
const KEYED_SECRET =
  /\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|_authToken|client[_-]?secret|password|secret)\s*[=:]\s*)(["']?)([^\s"',;]{8,})\2/gi;

export function redact(text: string): string {
  let out = text;
  for (const pattern of SECRET_PATTERNS) out = out.replace(pattern, "[redacted]");
  out = out.replace(KEYED_SECRET, (_match, prefix: string) => `${prefix}[redacted]`);
  return out;
}

// ---------------------------------------------------------------------------
// Index schema
// ---------------------------------------------------------------------------

/**
 * Plain FTS5 (not contentless) so rows can be deleted on re-sync — a message's
 * tool output changes from "running" to "completed" and must replace its old
 * row rather than duplicate it.
 */
const SCHEMA = `
create virtual table if not exists docs using fts5(
  text,
  doc_key unindexed,
  session_id unindexed,
  kind unindexed,
  ts unindexed,
  title unindexed,
  dir unindexed
);
create table if not exists meta(key text primary key, value text);
`;

type Kind = "user" | "assistant" | "note" | "error";

interface Doc {
  readonly key: string;
  readonly sessionId: string;
  readonly kind: Kind;
  readonly ts: number;
  readonly title: string;
  readonly dir: string;
  readonly text: string;
}

interface SessionMeta {
  readonly title: string;
  readonly dir: string;
}

/** One message, in the same shape whether it came from the host table or the API adapter. */
interface MessageRow {
  readonly id: string;
  readonly session_id: string;
  readonly type: string;
  readonly time_created: number;
  readonly data: string;
}

export function openIndex(path: string = INDEX_DB): Database {
  mkdirSync(join(path, ".."), { recursive: true });
  const index = new Database(path);
  // WAL lets a search run while a background sync writes, and busy_timeout makes
  // a second invocation wait its turn instead of failing with SQLITE_BUSY.
  index.exec("pragma journal_mode = wal");
  index.exec("pragma busy_timeout = 15000");
  index.exec("pragma synchronous = normal");
  index.exec(SCHEMA);
  return index;
}

function getMeta(index: Database, key: string): string | undefined {
  const row = index.query<{ value: string }, [string]>("select value from meta where key = ?").get(key);
  return row?.value;
}

function setMeta(index: Database, key: string, value: string): void {
  index
    .query("insert into meta(key, value) values(?, ?) on conflict(key) do update set value = excluded.value")
    .run(key, value);
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/** Minimal shape checks — the host schema is not ours and must not be trusted. */
function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : undefined;
}

function asText(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value : undefined;
}

/** Tool results arrive as content blocks, exactly like assistant messages do. */
function blockText(content: unknown): string | undefined {
  if (!Array.isArray(content)) return undefined;
  const parts: string[] = [];
  for (const block of content) {
    const record = asRecord(block);
    if (record?.["type"] === "text") {
      const text = asText(record["text"]);
      if (text !== undefined) parts.push(text);
    }
  }
  return parts.length === 0 ? undefined : parts.join("\n");
}

const MAX_DOC_CHARS = 8_000;

/**
 * Long documents are clamped head-and-tail rather than head-only: failures
 * report at the *end* of output, so truncating from the tail would delete
 * exactly what a precedent search came looking for.
 */
function clamp(text: string): string {
  if (text.length <= MAX_DOC_CHARS) return text;
  const head = text.slice(0, 4_800);
  const tail = text.slice(-3_200);
  return `${head}\n…\n${tail}`;
}

/**
 * One message becomes several documents, because the parts have different jobs:
 * the model's prose explains *why*, while a failed tool result holds the *what*.
 * Keeping them separate gives precise hits and readable snippets.
 */
export function docsFromMessage(row: MessageRow, meta: SessionMeta): Doc[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(row.data);
  } catch {
    return [];
  }
  const message = asRecord(parsed);
  if (message === undefined) return [];

  const out: Doc[] = [];
  let slot = 0;
  const push = (kind: Kind, text: string | undefined): void => {
    if (text === undefined) return;
    const clean = clamp(redact(text)).trim();
    // Short fragments are pure noise in a search index.
    if (clean.length < 12) return;
    out.push({
      key: `${row.id}:${slot++}`,
      sessionId: row.session_id,
      kind,
      ts: row.time_created,
      title: meta.title,
      dir: meta.dir,
      text: clean,
    });
  };

  if (row.type === "user" || row.type === "synthetic") {
    push(row.type === "synthetic" ? "note" : "user", asText(message["text"]));
    return out;
  }

  const content = message["content"];
  if (Array.isArray(content)) {
    for (const block of content) {
      const part = asRecord(block);
      if (part === undefined) continue;
      const type = part["type"];
      if (type === "text") {
        push("assistant", asText(part["text"]));
      } else if (type === "tool") {
        const state = asRecord(part["state"]);
        // Only failures are indexed. Successful tool output is ~52k documents of
        // file listings and command results — the bulk of the corpus and almost
        // none of the retrieval value — and short `shell ...` fragments would
        // outrank long explanations under bm25. Revisit if you ever want to
        // search for a command you ran rather than a problem you solved.
        if (asText(state?.["status"]) === "error") push("error", blockText(state?.["content"]));
      }
      // `reasoning` is deliberately skipped: high volume, low retrieval value.
    }
  }

  // Compaction summaries and similar carry their payload in plain `text`.
  push(row.type === "compaction" ? "note" : "assistant", asText(message["text"]));
  return out;
}

// ---------------------------------------------------------------------------
// Sync
// ---------------------------------------------------------------------------

function loadSessionMeta(source: Database): Map<string, SessionMeta> {
  const meta = new Map<string, SessionMeta>();
  // Two tables hold sessions across host versions; whichever is present wins.
  for (const table of ["session_v2", "session"]) {
    let rows: { id: string; title: string | null; directory: string | null }[];
    try {
      rows = source
        .query<{ id: string; title: string | null; directory: string | null }, []>(
          `select id, title, directory from ${table}`,
        )
        .all();
    } catch {
      continue; // table absent on this host version
    }
    for (const row of rows) {
      if (meta.has(row.id)) continue;
      meta.set(row.id, { title: row.title ?? "", dir: row.directory ?? "" });
    }
  }
  return meta;
}

interface SyncResult {
  readonly indexed: number;
  readonly scanned: number;
  readonly skipped: number;
}

export function sync(index: Database, source: Database, force: boolean): SyncResult {
  const cursor = force ? "0" : (getMeta(index, "cursor") ?? "0");
  const meta = loadSessionMeta(source);

  const statement = source.query<
    { id: string; session_id: string; type: string; time_created: number; time_updated: number; data: string },
    [string]
  >(
    `select id, session_id, type, time_created, time_updated, data
       from session_message
      where time_updated > ?
      order by time_updated`,
  );

  const remove = index.query("delete from docs where doc_key = ?");
  const insert = index.query(
    "insert into docs(text, doc_key, session_id, kind, ts, title, dir) values(?, ?, ?, ?, ?, ?, ?)",
  );

  let indexed = 0;
  let scanned = 0;
  let skipped = 0;
  let high = Number(cursor);

  // ONE transaction for the whole batch, deliberately.
  //
  // Committing per message turned a 40k-document build into a 220-second fsync
  // storm. It also meant an interrupted run could leave documents in the index
  // while the cursor still pointed behind them. Now a run is applied whole or
  // not at all, and an interrupted sync simply redoes its work next time.
  const write = index.transaction(() => {
    for (const row of statement.iterate(cursor)) {
      scanned += 1;
      try {
        const sessionMeta = meta.get(row.session_id) ?? { title: "", dir: "" };
        for (const doc of docsFromMessage(row, sessionMeta)) {
          remove.run(doc.key);
          insert.run(doc.text, doc.key, doc.sessionId, doc.kind, doc.ts, doc.title, doc.dir);
          indexed += 1;
        }
      } catch {
        // One unreadable message must not abandon the other forty thousand.
        skipped += 1;
      }
      if (row.time_updated > high) high = row.time_updated;
    }
    setMeta(index, "cursor", String(high));
    setMeta(index, "synced_at", String(Date.now()));
  });

  write();
  return { indexed, scanned, skipped };
}

// ---------------------------------------------------------------------------
// V2 API source (primary)
// ---------------------------------------------------------------------------

/**
 * The documented `opencode api` CLI, shelled directly — no token, port, or
 * header scheme is invented here; the CLI owns the host's auth. The override
 * exists so tests and the forced-fallback demonstration can point the API at a
 * binary that does not exist; unset, it shells the `opencode` on PATH.
 */
function apiBin(): string {
  return process.env["LOGBOOK_API_BIN"] ?? Bun.which("opencode") ?? "opencode";
}

/** An API read that failed or returned something unusable. Triggers fallback. */
class ApiUnavailable extends Error {}

/** One `opencode api get <path>`. Never throws: the caller decides what a failure means. */
function apiGet(path: string): { ok: true; body: unknown } | { ok: false; reason: string } {
  try {
    const proc = Bun.spawnSync([apiBin(), "api", "get", path], { stdout: "pipe", stderr: "pipe" });
    if (proc.exitCode !== 0) {
      return { ok: false, reason: proc.stderr.toString().trim().slice(0, 200) || `exit ${proc.exitCode}` };
    }
    const text = proc.stdout.toString().trim();
    if (text === "") return { ok: false, reason: "empty response" };
    return { ok: true, body: JSON.parse(text) };
  } catch (error) {
    return { ok: false, reason: String(error).slice(0, 200) };
  }
}

interface ApiPage {
  readonly items: Record<string, unknown>[];
  readonly next: string | undefined;
}

/** Every list endpoint shares `{ data: [...], cursor: { next } }`. */
function readPage(body: unknown, what: string): ApiPage {
  const record = asRecord(body);
  const data = record?.["data"];
  if (!Array.isArray(data)) throw new ApiUnavailable(`${what}: unexpected response shape`);
  const cursor = asRecord(record?.["cursor"]);
  return {
    items: data.filter((item): item is Record<string, unknown> => asRecord(item) !== undefined),
    next: asText(cursor?.["next"]),
  };
}

/**
 * Walks a list endpoint newest-first until `visit` returns false or the cursor
 * is exhausted. Each call carries a single query parameter on purpose: on
 * Windows `opencode` is a `.cmd` shim and Bun refuses to pass `&` to it, so
 * `?limit=…&cursor=…` cannot be used. Newest-first is also the order ingest
 * wants, so no `order` parameter is needed either.
 */
function apiWalk(
  what: string,
  firstPage: string,
  cursorPage: (cursor: string) => string,
  visit: (item: Record<string, unknown>) => boolean,
): void {
  let path = firstPage;
  for (let page = 0; page < 100_000; page += 1) {
    const response = apiGet(path);
    if (!response.ok) throw new ApiUnavailable(`${what}: ${response.reason}`);
    const { items, next } = readPage(response.body, what);
    let goOn = true;
    for (const item of items) if (!visit(item)) goOn = false;
    if (!goOn || next === undefined || items.length === 0) return;
    path = cursorPage(next);
  }
  throw new ApiUnavailable(`${what}: pagination did not terminate`);
}

/** The session fields the index needs, as the API exposes them. */
interface ApiSession {
  readonly id: string;
  readonly title: string;
  readonly dir: string;
  readonly created: number;
}

/** The API reports native path separators; the host table stores forward slashes.
 *  Normalise so switching sources never changes an indexed value. */
export const normDir = (value: unknown): string => (asText(value) ?? "").replace(/\\/g, "/");

function sessionFromApi(raw: Record<string, unknown>): ApiSession {
  const id = asText(raw["id"]);
  const created = asRecord(raw["time"])?.["created"];
  if (id === undefined || typeof created !== "number") throw new ApiUnavailable("session list: missing id or time");
  const location = asRecord(raw["location"]);
  return { id, title: asText(raw["title"]) ?? "", dir: normDir(location?.["directory"]), created };
}

/** Ids of the sessions the host currently reports as running. */
function apiActiveIds(): Set<string> {
  const response = apiGet("/api/session/active");
  if (!response.ok) throw new ApiUnavailable(`active sessions: ${response.reason}`);
  const data = asRecord(asRecord(response.body)?.["data"]);
  return new Set(data === undefined ? [] : Object.keys(data));
}

/**
 * Adapts an API message to the row shape `docsFromMessage` already understands.
 * The API flattens the payload to the top level and moves the timestamp into
 * `time`; removing exactly those three keys reproduces the host's `data` blob,
 * so both sources feed identical extraction.
 */
export function rowFromApiMessage(sessionId: string, raw: Record<string, unknown>): MessageRow | undefined {
  const id = asText(raw["id"]);
  const type = asText(raw["type"]);
  const created = asRecord(raw["time"])?.["created"];
  if (id === undefined || type === undefined || typeof created !== "number") return undefined;
  const payload: Record<string, unknown> = { ...raw };
  delete payload["id"];
  delete payload["time"];
  delete payload["type"];
  return { id, session_id: sessionId, type, time_created: created, data: JSON.stringify(payload) };
}

const API_FLUSH_DOCS = 2_000;

/**
 * Builds the index from the V2 API.
 *
 * Change detection is per session, because the API exposes no global
 * "messages since" cursor and a session's `time.updated` does not move when it
 * gains messages. Candidates are: sessions created since the last run, plus
 * sessions the host reports as running. Messages are read newest-first and stop
 * at a per-session high-water mark, so a re-run only pays for new messages.
 * `--reindex` (force) walks every session.
 */
function syncFromApi(index: Database, force: boolean): SyncResult {
  const active = apiActiveIds();
  const storedCursor = force ? 0 : Number(getMeta(index, "api_session_cursor") ?? "0");

  const sessions = new Map<string, ApiSession>();
  const candidates = new Set<string>();
  let highestCreated = 0;
  let enumerated = 0;

  apiWalk(
    "session list",
    "/api/session?limit=100",
    (cursor) => `/api/session?cursor=${encodeURIComponent(cursor)}`,
    (raw) => {
      const session = sessionFromApi(raw);
      enumerated += 1;
      if (session.created > highestCreated) highestCreated = session.created;
      sessions.set(session.id, session);
      const isNew = session.created > storedCursor;
      if (force || isNew || active.has(session.id)) candidates.add(session.id);
      return force || isNew; // newest-first: past the cursor, nothing older is new
    },
  );
  if (enumerated === 0) throw new ApiUnavailable("session list: empty");

  // A session can be running long before the cursor was set; pick those up too.
  for (const id of active) {
    if (sessions.has(id)) continue;
    candidates.add(id);
    const response = apiGet(`/api/session/${encodeURIComponent(id)}`);
    if (!response.ok) throw new ApiUnavailable(`session ${id}: ${response.reason}`);
    const wrapped = asRecord(response.body);
    const raw = asRecord(wrapped?.["data"]) ?? wrapped;
    const location = asRecord(raw?.["location"]);
    sessions.set(id, { id, title: asText(raw?.["title"]) ?? "", dir: normDir(location?.["directory"]), created: 0 });
  }

  const remove = index.query("delete from docs where doc_key = ?");
  const insert = index.query(
    "insert into docs(text, doc_key, session_id, kind, ts, title, dir) values(?, ?, ?, ?, ?, ?, ?)",
  );

  let buffered: Doc[] = [];
  const marks = new Map<string, number>();
  let indexed = 0;
  let scanned = 0;
  let skipped = 0;

  // Batched so a full scan neither holds the corpus in memory nor fsyncs once
  // per document. The session cursor advances only once the whole walk
  // succeeded, so an interrupted run re-enumerates rather than skipping.
  const flush = (advanceCursor: boolean): void => {
    index.transaction(() => {
      for (const doc of buffered) {
        remove.run(doc.key);
        insert.run(doc.text, doc.key, doc.sessionId, doc.kind, doc.ts, doc.title, doc.dir);
        indexed += 1;
      }
      buffered = [];
      for (const [id, mark] of marks) setMeta(index, `api_seen:${id}`, String(mark));
      marks.clear();
      if (advanceCursor) setMeta(index, "api_session_cursor", String(Math.max(storedCursor, highestCreated)));
      setMeta(index, "synced_at", String(Date.now()));
    })();
  };

  for (const id of candidates) {
    const session = sessions.get(id);
    const sessionMeta: SessionMeta =
      session === undefined ? { title: "", dir: "" } : { title: session.title, dir: session.dir };
    const mark = force ? 0 : Number(getMeta(index, `api_seen:${id}`) ?? "0");
    let newest = mark;
    apiWalk(
      `messages for ${id}`,
      `/api/session/${encodeURIComponent(id)}/message?limit=100`,
      (cursor) => `/api/session/${encodeURIComponent(id)}/message?cursor=${encodeURIComponent(cursor)}`,
      (raw) => {
        const row = rowFromApiMessage(id, raw);
        if (row === undefined) return true; // tolerate one odd message
        if (row.time_created <= mark && !force) return false; // older pages are already indexed
        if (row.time_created > newest) newest = row.time_created;
        scanned += 1;
        try {
          buffered.push(...docsFromMessage(row, sessionMeta));
        } catch {
          skipped += 1;
        }
        return true;
      },
    );
    marks.set(id, newest);
    if (buffered.length >= API_FLUSH_DOCS) flush(false);
  }
  flush(true);

  return { indexed, scanned, skipped };
}

export interface IngestResult extends SyncResult {
  readonly source: "api" | "db";
  readonly fallbackReason?: string;
}

/**
 * Ingest from the V2 API, falling back to the read-only host database when the
 * API is unavailable, errors, or returns nothing usable. The fallback is
 * recorded in `meta` and returned to the caller; it is never silent.
 */
export function ingest(index: Database, source: Database | undefined, force: boolean): IngestResult {
  try {
    const result = syncFromApi(index, force);
    setMeta(index, "last_source", "api");
    return { ...result, source: "api" };
  } catch (error) {
    if (!(error instanceof ApiUnavailable) || source === undefined) throw error;
    const result = sync(index, source, force);
    const reason = error.message === "" ? "api unavailable" : error.message;
    setMeta(index, "last_source", "db");
    setMeta(index, "last_fallback_reason", reason);
    return { ...result, source: "db", fallbackReason: reason };
  }
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

/**
 * FTS5 treats punctuation as syntax, and error messages are full of it. Every
 * term is quoted, so an input like `bun test (fail)` is a search rather than a
 * parse error.
 */
export function toMatchQuery(input: string, mode: "all" | "any"): string {
  const tokens = input.toLowerCase().match(/[a-z0-9_]{3,}/g) ?? [];
  const unique = [...new Set(tokens)].slice(0, 24);
  if (unique.length === 0) return "";
  const joiner = mode === "any" ? " OR " : " AND ";
  return unique.map((token) => `"${token}"`).join(joiner);
}

export interface Hit {
  readonly sessionId: string;
  readonly kind: string;
  readonly ts: number;
  readonly title: string;
  readonly dir: string;
  readonly snippet: string;
}

export function search(index: Database, match: string, limit: number): Hit[] {
  if (match === "") return [];
  return index
    .query<Hit, [string, number]>(
      `select session_id as sessionId, kind, ts, title, dir,
              snippet(docs, 0, '<<', '>>', ' … ', 16) as snippet
         from docs
        where docs match ?
        order by bm25(docs), ts desc
        limit ?`,
    )
    .all(match, limit);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

const shortId = (id: string): string => id.slice(0, 8);
const day = (ts: number): string => new Date(ts).toISOString().slice(0, 10);

function printHits(hits: readonly Hit[]): void {
  if (hits.length === 0) {
    console.log("no matches.");
    return;
  }
  const sessions = new Set(hits.map((hit) => hit.sessionId)).size;
  console.log(`${hits.length} hit(s) across ${sessions} session(s)\n`);
  for (const hit of hits) {
    const title = hit.title.trim() === "" ? "(untitled)" : hit.title.trim();
    console.log(`${shortId(hit.sessionId)}  ${day(hit.ts)}  [${hit.kind}]  ${title}`);
    console.log(`  ${hit.snippet.replace(/\s+/g, " ").trim()}\n`);
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

interface Args {
  readonly command: "search" | "precedent" | "stats" | "reindex" | "help";
  readonly query: string;
  readonly json: boolean;
  readonly limit: number;
}

function parseArgs(argv: readonly string[]): Args {
  const rest: string[] = [];
  let command: Args["command"] = "search";
  let json = false;
  let limit = 0;

  for (const arg of argv) {
    if (arg === "--json") json = true;
    else if (arg === "--stats") command = "stats";
    else if (arg === "--reindex") command = "reindex";
    else if (arg === "--help" || arg === "-h") command = "help";
    else if (arg === "--precedent") command = command === "search" ? "precedent" : command;
    else if (arg.startsWith("--limit=")) limit = Number(arg.slice(8)) || 0;
    else rest.push(arg);
  }

  return { command, query: rest.join(" ").trim(), json, limit };
}

const USAGE = `logbook — search your OpenCode history

  logbook "<query>"            search every session you have run
  logbook --precedent "<err>"  find prior occurrences of a failure
  logbook --precedent          read the failure from stdin
  logbook --stats              what is indexed
  logbook --reindex            rebuild the index from scratch
  logbook --json               machine-readable output
  logbook --limit=N            cap the number of hits

Index: ${INDEX_DB}
Primary source:  the running host's V2 session API (via \`opencode api\`)
Fallback source: ${SOURCE_DB} (read-only)`;

async function readStdin(): Promise<string> {
  if (process.stdin.isTTY) return "";
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}

async function main(): Promise<number> {
  const args = parseArgs(process.argv.slice(2));

  if (args.command === "help") {
    console.log(USAGE);
    return 0;
  }

  if (args.command === "reindex") {
    if (existsSync(INDEX_DB)) rmSync(INDEX_DB, { force: true });
    console.log("index cleared.");
  }

  const index = openIndex();

  // The database is the fallback now, so its absence is not fatal on its own —
  // the API may still serve history. Opened read-only, as always.
  let source: Database | undefined;
  if (existsSync(SOURCE_DB)) {
    try {
      // The one promise that matters: this is a reader, never a writer.
      source = new Database(SOURCE_DB, { readonly: true });
    } catch {
      source = undefined;
    }
  }

  let stats: IngestResult;
  try {
    stats = ingest(index, source, args.command === "reindex");
  } catch (error) {
    console.error(`logbook: no history found at ${SOURCE_DB} (${String(error)})`);
    return 1;
  }

  if (stats.fallbackReason !== undefined) {
    console.error(`logbook: V2 API unavailable (${stats.fallbackReason}); read from ${SOURCE_DB} instead.`);
  }

  if (args.command === "stats") {
    const totals = index
      .query<{ docs: number; sessions: number; first: number; last: number }, []>(
        "select count(*) as docs, count(distinct session_id) as sessions, min(ts) as first, max(ts) as last from docs",
      )
      .get();
    const payload = {
      documents: totals?.docs ?? 0,
      sessions: totals?.sessions ?? 0,
      first: totals?.first ?? 0,
      last: totals?.last ?? 0,
      syncedNow: stats.indexed,
      skipped: stats.skipped,
      index: INDEX_DB,
      source: SOURCE_DB,
      ingest: stats.source,
      fallback: stats.fallbackReason ?? null,
    };
    if (args.json) console.log(JSON.stringify(payload, null, 2));
    else {
      console.log(`documents  ${payload.documents}`);
      console.log(`sessions   ${payload.sessions}`);
      console.log(`range      ${day(payload.first)} .. ${day(payload.last)}`);
      console.log(`new now    ${payload.syncedNow}`);
      if (payload.skipped > 0) console.log(`skipped    ${payload.skipped} (unreadable)`);
      console.log(`ingest     ${payload.ingest === "api" ? "v2 api" : "host database"}`);
      if (payload.fallback !== null) console.log(`fallback   ${payload.fallback}`);
      console.log(`index      ${payload.index}`);
    }
    return 0;
  }

  const isPrecedent = args.command === "precedent";
  let query = args.query;
  if (isPrecedent && query === "") query = (await readStdin()).trim();

  if (query === "") {
    console.log(USAGE);
    return isPrecedent ? 1 : 0;
  }

  const match = toMatchQuery(query, isPrecedent ? "any" : "all");
  const hits = search(index, match, args.limit > 0 ? args.limit : isPrecedent ? 6 : 14);

  if (args.json) {
    console.log(JSON.stringify({ query, mode: args.command, hits }, null, 2));
    return 0;
  }
  if (isPrecedent) {
    console.log(`precedent for: ${query.replace(/\s+/g, " ").slice(0, 120)}\n`);
  }
  printHits(hits);
  return 0;
}

// Importing this module (from the test suite) must not run the CLI.
if (import.meta.main) process.exit(await main());
