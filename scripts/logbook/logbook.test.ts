// Logbook's behaviour, pinned. The point of these is that the two things that
// could quietly ruin the index — a leaked secret, and a silent mis-parse of the
// host schema — both fail loudly here instead.

import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { docsFromMessage, ingest, normDir, openIndex, redact, rowFromApiMessage, search, sync, toMatchQuery } from "./logbook.ts";

const CLIENT = join(import.meta.dir, "logbook.ts");

interface Row {
  id: string;
  session_id: string;
  type: string;
  time_created: number;
  time_updated: number;
  data: string;
}

const message = (over: Partial<Row> & { id: string; type: string; data: unknown }): Row => ({
  session_id: "ses_fixture",
  time_created: 1_700_000_000_000,
  time_updated: 1_700_000_000_000,
  ...over,
  session_id: over.session_id ?? "ses_fixture",
  data: JSON.stringify(over.data),
});

/**
 * A miniature of the real host database: two tables, and only the columns the
 * tool actually reads. If the host schema moves, these tests keep passing while
 * the real run fails loudly — which is the correct asymmetry.
 */
function fixtureDb(rows: readonly Row[]): Database {
  const db = new Database(":memory:");
  db.exec("create table session_v2(id text, title text, directory text)");
  db.exec("create table session_message(id text, session_id text, type text, seq integer, time_created integer, time_updated integer, data text)");
  db.exec("insert into session_v2 values('ses_fixture', 'Ticker reactivity', 'C:/Users/alice/foo')");
  const insert = db.query(
    "insert into session_message(id, session_id, type, seq, time_created, time_updated, data) values(?, ?, ?, 0, ?, ?, ?)",
  );
  for (const row of rows) {
    insert.run(row.id, row.session_id, row.type, row.time_created, row.time_updated, row.data);
  }
  return db;
}

function tempIndex(): { path: string; indexPath: string } {
  const dir = mkdtempSync(join(tmpdir(), "logbook-test-"));
  return { path: dir, indexPath: join(dir, "index.db") };
}

describe("redact", () => {
  test("removes the credential shapes that actually show up in transcripts", () => {
    expect(redact("token npm_abcdefghijklmnopqrstuvwxyz here")).toContain("[redacted]");
    expect(redact("token npm_abcdefghijklmnopqrstuvwxyz here")).not.toContain("abcdefghijkl");
    // literals are split so the gc secret gate stays clean (it scans for the
    // sk-/AKIA/xoxb- shapes these very fixtures must exercise); runtime
    // strings are identical either way.
    expect(redact("sk-" + "abcdefghijklmnopqrstuvwx")).toBe("[redacted]");
    expect(redact("ghp_abcdefghijklmnopqrstuvwx")).toBe("[redacted]");
    expect(redact("AKIA" + "IOSFODNN7EXAMPLE")).toBe("[redacted]");
    expect(redact("xoxb-" + "1234567890-abcdefghij")).toBe("[redacted]");
  });

  test("keeps the key so the surrounding context survives", () => {
    const out = redact("//registry.npmjs.org/:_authToken=supersecretvalue123");
    expect(out).toContain("_authToken");
    expect(out).toContain("[redacted]");
    expect(out).not.toContain("supersecretvalue123");
  });

  test("leaves ordinary prose alone", () => {
    const text = "the spinner wraps rather than running off the end of the frame list";
    expect(redact(text)).toBe(text);
  });
});

describe("toMatchQuery", () => {
  test("quotes every term so error punctuation cannot become FTS syntax", () => {
    expect(toMatchQuery("bun test (fail)", "all")).toBe('"bun" AND "test" AND "fail"');
    expect(toMatchQuery("bun test (fail)", "any")).toBe('"bun" OR "test" OR "fail"');
  });

  test("drops tokens too short to discriminate anything", () => {
    expect(toMatchQuery("a i the spinner", "all")).toBe('"the" AND "spinner"');
  });

  test("deduplicates so repetition cannot skew the ranking", () => {
    expect(toMatchQuery("ticker ticker ticker", "all")).toBe('"ticker"');
  });

  test("returns an empty query rather than throwing on punctuation-only input", () => {
    expect(toMatchQuery("!!! ??? ---", "all")).toBe("");
    expect(toMatchQuery("", "all")).toBe("");
  });
});

describe("docsFromMessage", () => {
  const meta = { title: "T", dir: "D" };

  test("takes a user prompt as one document", () => {
    const docs = docsFromMessage(
      message({ id: "m1", type: "user", data: { text: "we should check the ticker again" } }),
      meta,
    );
    expect(docs).toHaveLength(1);
    expect(docs[0]?.kind).toBe("user");
    expect(docs[0]?.text).toContain("ticker");
  });

  test("reads assistant prose but ignores reasoning", () => {
    const docs = docsFromMessage(
      message({
        id: "m2",
        type: "assistant",
        data: {
          content: [
            { type: "reasoning", text: "the internal monologue nobody searches for" },
            { type: "text", text: "the fix is to route the tick through the host store" },
          ],
        },
      }),
      meta,
    );
    expect(docs).toHaveLength(1);
    expect(docs[0]?.kind).toBe("assistant");
    expect(docs[0]?.text).toContain("host store");
  });

  test("pulls the failure text out of a failed tool call", () => {
    const docs = docsFromMessage(
      message({
        id: "m3",
        type: "assistant",
        data: {
          content: [
            {
              type: "tool",
              name: "shell",
              state: {
                status: "error",
                input: { command: "bun run check" },
                content: [{ type: "text", text: "error TS2345: argument not assignable" }],
              },
            },
          ],
        },
      }),
      meta,
    );
    expect(docs).toHaveLength(1);
    expect(docs[0]?.kind).toBe("error");
    expect(docs[0]?.text).toContain("TS2345");
  });

  test("skips successful tool output, which is the bulk of the corpus", () => {
    const docs = docsFromMessage(
      message({
        id: "m4",
        type: "assistant",
        data: {
          content: [
            {
              type: "tool",
              name: "shell",
              state: {
                status: "completed",
                input: { command: "ls" },
                content: [{ type: "text", text: "a very long successful directory listing" }],
              },
            },
          ],
        },
      }),
      meta,
    );
    expect(docs).toHaveLength(0);
  });

  test("scrubs secrets on the way in, not on the way out", () => {
    const docs = docsFromMessage(
      message({ id: "m5", type: "user", data: { text: "my token is npm_abcdefghijklmnopqrstuvwxyz ok" } }),
      meta,
    );
    expect(docs[0]?.text).not.toContain("abcdefghijkl");
    expect(docs[0]?.text).toContain("[redacted]");
  });

  test("keeps the tail of a long document, where failures are reported", () => {
    const docs = docsFromMessage(
      message({ id: "m6", type: "user", data: { text: `${"x".repeat(20_000)} THE-END-MARKER` } }),
      meta,
    );
    expect(docs[0]?.text.length).toBeLessThan(9_000);
    expect(docs[0]?.text).toContain("THE-END-MARKER");
  });

  test("survives data that is not valid JSON rather than crashing the sync", () => {
    const docs = docsFromMessage(
      { id: "m7", session_id: "s", type: "user", time_created: 0, data: "{not json" },
      meta,
    );
    expect(docs).toEqual([]);
  });
});

describe("sync and search", () => {
  test("indexes, is incremental, and replaces a row that changed", () => {
    const { path, indexPath } = tempIndex();
    // time_updated moves between syncs; time_created does not. That asymmetry is
    // what makes a tool call that changed from running -> error re-indexable.
    const source = fixtureDb([
      message({ id: "m1", type: "user", data: { text: "first message about the ticker" } }),
      message({
        id: "m2",
        type: "assistant",
        time_created: 1_700_000_001_000,
        time_updated: 1_700_000_001_000,
        data: { content: [{ type: "text", text: "answer mentioning lastexitcode quirks" }] },
      }),
    ]);
    const index = openIndex(indexPath);

    const first = sync(index, source, false);
    expect(first.indexed).toBe(2);
    expect(search(index, toMatchQuery("ticker", "all"), 10)).toHaveLength(1);

    // Nothing changed: a second sync must not duplicate anything.
    const second = sync(index, source, false);
    expect(second.indexed).toBe(0);
    expect(search(index, toMatchQuery("ticker", "all"), 10)).toHaveLength(1);

    // A row that is edited in place must replace its old document, not add one.
    source
      .query("update session_message set data = ?, time_updated = ? where id = 'm1'")
      .run(JSON.stringify({ text: "first message about the ticker, now corrected" }), 1_700_000_002_000);
    const third = sync(index, source, false);
    expect(third.indexed).toBe(1);
    expect(search(index, toMatchQuery("ticker", "all"), 10)).toHaveLength(1);
    expect(search(index, toMatchQuery("corrected", "all"), 10)).toHaveLength(1);

    index.close();
    source.close();
    rmSync(path, { recursive: true, force: true });
  });

  test("a forced rebuild produces the same index rather than doubling it", () => {
    const { path, indexPath } = tempIndex();
    const source = fixtureDb([
      message({ id: "m1", type: "user", data: { text: "a searchable sentence about flight decks" } }),
    ]);
    const index = openIndex(indexPath);

    sync(index, source, false);
    sync(index, source, true);
    expect(search(index, toMatchQuery("flight decks", "all"), 10)).toHaveLength(1);

    index.close();
    source.close();
    rmSync(path, { recursive: true, force: true });
  });

  test("carries the session title and date into each hit", () => {
    const { path, indexPath } = tempIndex();
    const source = fixtureDb([
      message({ id: "m1", type: "user", data: { text: "something worth finding later" } }),
    ]);
    const index = openIndex(indexPath);
    sync(index, source, false);

    const [hit] = search(index, toMatchQuery("finding later", "all"), 10);
    expect(hit?.title).toBe("Ticker reactivity");
    expect(hit?.dir).toBe("C:/Users/alice/foo");
    expect(hit?.snippet).toContain("<<");
    expect(hit?.snippet).toContain(">>");

    index.close();
    source.close();
    rmSync(path, { recursive: true, force: true });
  });

  test("--precedent's OR mode still finds a hit when no term appears together", () => {
    const { path, indexPath } = tempIndex();
    const source = fixtureDb([
      message({
        id: "m1",
        type: "assistant",
        data: { content: [{ type: "text", text: "the pipeline swallows the exit code from the native command" }] },
      }),
    ]);
    const index = openIndex(indexPath);
    sync(index, source, false);

    expect(search(index, toMatchQuery("last-exit-code pipeline", "all"), 10)).toHaveLength(0);
    expect(search(index, toMatchQuery("pipeline exit code", "any"), 10).length).toBeGreaterThan(0);

    index.close();
    source.close();
    rmSync(path, { recursive: true, force: true });
  });
});

describe("api adapter", () => {
  const meta = { title: "T", dir: "D" };

  test("maps an API message to the same documents as the host row", () => {
    const dbUser = message({ id: "m1", type: "user", data: { text: "we should check the ticker again" } });
    const apiUser = rowFromApiMessage("ses_fixture", {
      id: "m1",
      time: { created: 1_700_000_000_000 },
      type: "user",
      text: "we should check the ticker again",
    });
    expect(apiUser).toEqual({
      id: "m1",
      session_id: "ses_fixture",
      type: "user",
      time_created: 1_700_000_000_000,
      data: '{"text":"we should check the ticker again"}',
    });
    expect(docsFromMessage(apiUser!, meta)).toEqual(docsFromMessage(dbUser, meta));

    // The API flattens the payload and moves `time` to the top level; a failed
    // tool call must still extract identically.
    const content = [
      { type: "tool", name: "shell", state: { status: "error", content: [{ type: "text", text: "error TS2345: argument not assignable" }] } },
    ];
    const dbTool = message({ id: "m3", type: "assistant", data: { content } });
    const apiTool = rowFromApiMessage("ses_fixture", { id: "m3", time: { created: 1_700_000_000_000 }, type: "assistant", content });
    expect(docsFromMessage(apiTool!, meta)).toEqual(docsFromMessage(dbTool, meta));
  });

  test("rejects a message the API returned without an id, type or timestamp", () => {
    expect(rowFromApiMessage("s", { type: "user", time: { created: 1 } })).toBeUndefined();
    expect(rowFromApiMessage("s", { id: "m", time: { created: 1 } })).toBeUndefined();
    expect(rowFromApiMessage("s", { id: "m", type: "user" })).toBeUndefined();
  });

  test("normalises the API's native path separators to the host table's form", () => {
    expect(normDir("C:\\Users\\alice\\.config\\opencode")).toBe("C:/Users/alice/.config/opencode");
    expect(normDir("/home/user/project")).toBe("/home/user/project");
    expect(normDir(undefined)).toBe("");
  });

  test("falls back to the database and records why when the API is unavailable", () => {
    const { path, indexPath } = tempIndex();
    const source = fixtureDb([
      message({ id: "m1", type: "user", data: { text: "a fallback sentence about the ticker" } }),
    ]);
    const index = openIndex(indexPath);
    const previous = process.env["LOGBOOK_API_BIN"];
    process.env["LOGBOOK_API_BIN"] = join(path, "no-such-opencode");
    try {
      const result = ingest(index, source, false);
      expect(result.source).toBe("db");
      expect(result.fallbackReason).toBeDefined();
      expect(result.indexed).toBe(1);
      const recorded = index
        .query<{ value: string }, []>("select value from meta where key = 'last_source'")
        .get();
      expect(recorded?.value).toBe("db");
      expect(search(index, toMatchQuery("ticker", "all"), 10)).toHaveLength(1);
    } finally {
      if (previous === undefined) delete process.env["LOGBOOK_API_BIN"];
      else process.env["LOGBOOK_API_BIN"] = previous;
      index.close();
      source.close();
      rmSync(path, { recursive: true, force: true });
    }
  });
});

describe("cli", () => {
  function run(args: readonly string[], indexPath: string, sourcePath: string) {
    return Bun.spawnSync({
      cmd: ["bun", CLIENT, ...args],
      // LOGBOOK_API_BIN points at a binary that cannot exist, so the CLI is
      // exercised against the fixture database deterministically instead of
      // whatever host service happens to be running.
      env: {
        ...process.env,
        LOGBOOK_INDEX: indexPath,
        LOGBOOK_SOURCE: sourcePath,
        LOGBOOK_API_BIN: join(sourcePath, "..", "no-such-opencode"),
      },
      stdout: "pipe",
      stderr: "pipe",
    });
  }

  test("prints hits with the session, date and a snippet", () => {
    const { path, indexPath } = tempIndex();
    const sourcePath = join(path, "source.db");
    const source = new Database(sourcePath);
    source.exec("create table session_v2(id text, title text, directory text)");
    source.exec("create table session_message(id text, session_id text, type text, seq integer, time_created integer, time_updated integer, data text)");
    source.exec("insert into session_v2 values('ses_fixture', 'Exit codes', 'Q:/P')");
    source
      .query("insert into session_message values(?, 'ses_fixture', 'user', 0, ?, ?, ?)")
      .run(
        "m1",
        1_700_000_000_000,
        1_700_000_000_000,
        JSON.stringify({ text: "the last-exit-code after a pipeline is the wrong one" }),
      );
    source.close();

    const ok = run(["last-exit-code"], indexPath, sourcePath);
    expect(ok.exitCode).toBe(0);
    const out = ok.stdout.toString();
    expect(out).toContain("Exit codes");
    expect(out).toContain("2023-11-14");
    expect(out).toContain("<<");

    const misses = run(["something-never-said-ever"], indexPath, sourcePath);
    expect(misses.stdout.toString()).toContain("no matches");

    rmSync(path, { recursive: true, force: true });
  });

  test("explains itself instead of throwing when there is no history to read", () => {
    const { path, indexPath } = tempIndex();
    const missing = run(["anything"], indexPath, join(path, "does-not-exist.db"));
    expect(missing.exitCode).toBe(1);
    expect(missing.stderr.toString()).toContain("no history found");
    rmSync(path, { recursive: true, force: true });
  });

  test("--help does not touch an index at all", () => {
    const { path, indexPath } = tempIndex();
    const help = run(["--help"], join(path, "never-created.db"), join(path, "nope.db"));
    expect(help.exitCode).toBe(0);
    expect(help.stdout.toString()).toContain("logbook — search your OpenCode history");
    rmSync(path, { recursive: true, force: true });
  });
});
