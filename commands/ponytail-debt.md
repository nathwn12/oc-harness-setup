---
description: Harvest lean/ponytail deferral comments into a debt ledger
agent: explore
subagent: true
---

Harvest every `lean:` and `ponytail:` deferral marker in the current repository into a debt ledger. One-shot report; change nothing.

- Scan for `lean: <ceiling>; revisit when <trigger>` comments and any legacy `ponytail:` markers; skip dependencies, VCS internals, and build output.
- Group by file. For each marker: `<file>:<line>, <what was deferred>. ceiling: <limit>. revisit: <trigger>.`
- Mark markers missing a ceiling or trigger as `no-trigger` — those are the ones most likely to rot.
- Sort so `no-trigger` items surface first.

End with `<N> markers, <M> with no trigger.` If none exist, say `No lean debt. Clean ledger.`
