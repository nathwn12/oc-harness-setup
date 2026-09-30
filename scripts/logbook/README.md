# logbook

The readable half of your OpenCode history.

Every session you have ever run is still on disk, but it is write-only — nothing
can search it, so problems get solved for the first time, every time. Logbook
makes it readable.

```bash
logbook "lastexitcode"            # search everything you have ever run
logbook --precedent "<error>"     # find prior occurrences of a failure
logbook --precedent               # ...reading the error from stdin
logbook --stats                   # what is indexed
logbook --reindex                 # rebuild from scratch
logbook --json                    # machine-readable
logbook --limit=5 "narrow this"
```

## How it is wired

- **CLI**, run through `bun`. No plugin, no MCP, no daemon, no server.
- **Trigger:** `skills/debugging-and-error-recovery/SKILL.md` Step 0 tells the
  agent to run `--precedent` before diagnosing anything.
- **Shim:** `~/.local/bin/logbook.cmd` (that directory is already on `PATH`).
- **Source (primary):** the running host's documented V2 HTTP API, called through
  the documented `opencode api` CLI — no token, port, or header handling of our
  own.
- **Source (fallback):** `~/.local/share/opencode/opencode.db`, opened
  **read-only**. Used automatically when the API is unavailable, errors, or
  returns nothing usable; the switch is recorded and printed, never silent.
- **Index:** `~/.opencode/logbook/index.db` — deliberately outside the config
  directory, so the config-directory Git mirror never copies it into the repo.

## Design rules

1. **The host database is never written.** The index is a separate file this tool
   owns.
2. **The index is derived data.** Deleting it and re-running `--reindex` is always
   safe.
3. **Secrets are scrubbed on the way in.** Transcripts contain pasted tokens, and
   an index is a new place for them to leak from. Known credential shapes are
   replaced with `[redacted]`; `key=value` forms keep the key so context survives.
   This is a seatbelt, not a guarantee — unknown formats will get through.
4. **Degrade quietly.** A missing index or an unreadable database prints one clear
   line and exits non-zero. It never throws a stack trace at you.

## What is indexed

| Kind | Source | Why |
|---|---|---|
| `user` | your prompts | the question you asked |
| `assistant` | the model's prose | the answer, and the reasoning behind it |
| `note` | synthetic + compaction summaries | context that would otherwise vanish |
| `error` | **failed** tool calls only | the failure text itself |

**Deliberately not indexed: successful tool output** (~52k documents of directory
listings and command results). It is the bulk of the corpus and almost none of
the retrieval value, and its short fragments would outrank long explanations
under bm25. Revisit if you ever want to search for *a command you ran* rather
than *a problem you solved*. Also skipped: `reasoning` blocks.

Long documents are clamped to 8,000 characters **head-and-tail**, because
failures report at the end of output.

## Schema coupling

Ingest prefers the host's **documented V2 HTTP API** — `GET /api/session` for the
session list and `GET /api/session/{id}/message` for messages — called through
the documented `opencode api` CLI. The index schema is
unchanged either way, and only the documented surface is used, so a host schema
move no longer breaks ingest.

The read-only `bun:sqlite` path over `session_message` and `session_v2` remains
as an automatic **fallback**. It triggers when the API is unavailable or errors
(missing binary, no running service, non-zero exit, non-JSON) or returns nothing
usable (an empty or unrecognisable shape). When it triggers, logbook prints one
line to stderr, records `last_source=db` and the reason in the index `meta`
table, and `--stats` reports `ingest  host database`.

Why the split: the API is the host's public contract and survives internal
schema changes, but it only exists while the host service is running; the
database is always on disk. Preferring the API and falling back to the table read
means a host that has moved its tables degrades instead of breaking, and an
unavailable API still yields a searchable index. The host database is never
written by either path.

Incremental sync from the API is per session — sessions created since the last
run, plus sessions the host reports as running — because the API exposes no
global "messages since" cursor and a session's `time.updated` does not move when
it gains messages. `--reindex` walks every session.

The legacy `message`/`part` tables are not indexed: they stop at 2026-08-13 and
overlap `session_message`, which spans the full range.

## Tests

```bash
cd ~/.config/opencode/scripts/logbook && bun test
```

25 tests: redaction, query building, schema parsing, incremental sync (including
in-place updates), the API-message adapter, path normalisation, automatic
fallback with its recorded reason, and the real CLI against a fixture database.

The CLI tests point `LOGBOOK_API_BIN` at a binary that cannot exist, so they
exercise the fixture database deterministically instead of whatever host service
happens to be running. Add a new test for API behaviour by exporting
`LOGBOOK_API_BIN` to a fake.
