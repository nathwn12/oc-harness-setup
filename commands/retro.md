---
description: Run the bounded retro pass over logbook + pattern inbox; emit a proposal queue, never edits
agent: general
subagent: true
---

Run one bounded retro pass. Read `~/.opencode/memory/patterns.md` and query `logbook` read-only; never use `--reindex`.

Caps (hard): ≤8 logbook queries, ≤50 hits per query (`--limit=50`), ≤30 min wall-clock, repeat threshold ≥3 distinct sessions. If a query hits its cap, stop paging and record the cap-hit as a finding about corpus size, not a failure.

Look for repeated friction: hand-typed commands, failed or thrashing dispatches, violated instructions, and user restatements. Return a proposal queue to the parent; do not write the child session's state. Each item includes evidence, uncertainty, and one outcome (`core invariant`, `agent`, `skill`, `command`, `reference`, `delete`, or `discard`).

Never apply the queue here — applying is always a separate, reviewed step. Never touch `~/.config/opencode/scripts/`, `~/.config/opencode/agents/`, `~/.config/opencode/skills/`, `~/.config/opencode/opencode.jsonc`, or `~/.config/opencode/AGENTS.md` from this command. Never read or print `.secrets` / `.env`.

Close with queries and hit counts, proposals or honest-empty evidence, caps hit, and anything unverified.
