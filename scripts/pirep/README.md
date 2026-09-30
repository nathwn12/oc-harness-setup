# pirep

**Pilot report: which models and agents actually perform — measured, not assumed.**

Every turn OpenCode has ever run is still on disk with its token counts and its
recorded cost. Pirep reads them and reports, per model and per agent: turns and
sessions, input / output / cache-read tokens, median streaming speed, median
turn cost, cache hit rate, and failure rate.

It exists to answer a question that guessing gets wrong: *which of these is
actually doing the work, and which one only looks cheap?*

```bash
pirep                    # full report: metered models, unpriced models, agents
pirep --models           # models only
pirep --agents           # agents only
pirep --since=2026-06-01 # only turns on or after this date
pirep --limit=5          # cap rows per section
pirep --json             # machine-readable, with exact integers
pirep --help
```

No flags still prints the full report. It runs in about two seconds over a
1 GB history.

## The rule that shapes everything

Subscription models record a cost of `0` with real token counts, because there
is no per-token bill. **That zero is correct.**

So pirep will never invent a price for one, and — more importantly — never lets
one into a cost ranking. A model with no metered cost would always look free and
always "win", which is a recommendation engine confidently recommending the
wrong thing. Metered and unpriced models are reported in **separate sections and
never summed or averaged together**. Every figure that excludes unpriced turns
is labelled *partial*.

## How it is wired

- **CLI**, run through `bun`. No plugin, no MCP, no daemon, no server, no index.
- **Source:** `~/.local/share/opencode/opencode.db`, opened **read-only**.
  Override with `PIREP_SOURCE` (the tests point it at a fixture).
- **Scope:** `session_message` rows where `type = 'assistant'`. The legacy
  `message` / `part` tables stop at 2026-08-13 and overlap `session_message`,
  which spans the full range — they are not read.
- **Trigger:** the `pilot-report` skill tells the agent to run this before
  recommending a model or an agent.

## Design rules

1. **Never price an unpriced model**, and never mix the two units. See above.
2. **The host database is never written.** Opened `{ readonly: true }`.
3. **Parse defensively, skip honestly.** Bad JSON, no resolvable model, a
   non-assistant row, or a row with `time` but no `tokens` yet (a mid-stream
   write, which is not a zero-token turn) is skipped and counted. Negative
   tokens and cost clamp to zero.
4. **Speed means streaming speed.** Output tokens-per-second is measured over
   `time.streamed - time.created` — the window the model spent producing output.
   It is deliberately *not* `time.completed - time.created`, which also spans
   tool execution and would report every model as slower than it is. Where the
   host recorded no stream completion the turn gets no speed at all rather than
   a number measuring something else.
5. **Degrade quietly.** A missing or unreadable database, or an unexpected host
   schema, prints one clear line and exits non-zero. It never throws a stack
   trace at you.

## What the numbers mean

| Figure | Definition |
|---|---|
| `turns` / `sess` | assistant messages / distinct sessions behind the row |
| `in` / `out` / `cache-r` | summed `tokens.input` / `tokens.output` / `tokens.cache.read` |
| `hit%` | `cache.read / (cache.read + input)` — the same definition `opencode stats` uses |
| `tok/s` | median output speed over turns with a streaming window; `-` when none was recorded |
| `cost`, `med-cost` | **metered section only**: sum and per-turn median of recorded cost |
| `metered$*` (agents) | recorded cost on metered turns only — agents mix models, so this is partial |
| `fail%` | share of turns with a non-null `error` field (includes aborts/cancels), not judged quality |

Token columns are abbreviated (`518`, `83.2M`, `1.4B`) so a lifetime total fits
the table; `--json` carries the exact integers.

## The real field names

Read from the actual database, not from documentation. Assistant rows carry
their payload in the `data` JSON column:

| Field | Meaning |
|---|---|
| `model.id` / `model.providerID` / `model.variant` | model identity — **nested**, on 3,969 of 4,000 sampled rows |
| `tokens.input` / `tokens.output` / `tokens.reasoning` | token counts |
| `tokens.cache.read` / `tokens.cache.write` | cached-token counts |
| `cost` | recorded cost for the turn (`0` on subscription models) |
| `time.created` / `time.streamed` / `time.completed` | millisecond-epoch: start, last token, turn end |
| `agent` | the agent name — this is the field the host writes |
| `error` | non-null when the turn errored (370 rows in this history) |

Three things that are easy to get wrong, and were:

- **`mode` is never populated.** Every assistant row in this history has
  `agent` set and `mode` null. Reading `mode` first would label every turn
  "unknown".
- **`time.streamed` exists.** It is present on 15,755 of 33,466 token-carrying
  turns (47.1%), and on roughly 99% of recent ones. Early rows predate it, which
  is why `tok/s` shows `-` for some models.
- **`model` is nested.** The flat `modelID` / `providerID` fields are kept as a
  fallback for older rows but appear on none of the rows inspected here.

## Coverage and honesty

The report states what it scanned and what it skipped. Typical run:

```
scanned 33672 assistant messages: 33464 turns across 1852 sessions, 208 skipped (unreadable)
```

A `tok/s` of `-` is not a bug: it means no turn for that model carried a
streaming timestamp. `fail%` counts any non-null `error` field, which includes
aborts and cancellations — it is an error rate, not a quality judgement.

## Schema coupling

This reads the host's `session_message` table. It is not a public API. If the
host moves it, the tool fails loudly rather than returning wrong answers.

## Tests

```bash
cd ~/.config/opencode/scripts/pirep && bun test
```

33 tests: the parser (nested and flat model shapes, precedence, clamping, the
streaming-window rules, skipping a mid-stream tokenless row), the maths, the
metering split (including that a zero-cost model with real tokens lands in the
unpriced section with no median cost and its turns excluded from every cost
total), `--since`, the JSON shape, flag validation, and the real CLI end to end
against a fixture database.

Tests never touch the real database and never need the network.

## Verification

The numbers were checked against plain SQL over the real database — turns,
input, output, cache reads, cost, hit rate, and the metered total all agree.
The one deliberate difference is that pirep counts an unpriced *model's* turns
while the raw SQL counts individual zero-cost rows, so the unpriced-turn count
is slightly higher by design: the metering split is a property of a model, not
of a row.
