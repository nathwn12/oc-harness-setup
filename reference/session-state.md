# Session state

State is optional working memory for long work, compaction, or handoff. Trivial work needs none.

Use `~/.opencode/state/sessions/<session-id>/`:

- `session.yaml` — goal, plan, done, now, next, blockers, key files, handoff.
- `events.yaml` — append-only meaningful events.
- `artifacts/<id>.yaml` — long-form session artifacts when needed.

Use two-space YAML, quoted free text, literal blocks for prose, and no secrets. Do not create Markdown in the state directory. The foreground orchestrator owns state; background workers return evidence rather than editing their child session state.

`/checkpoint` refreshes the snapshot and appends one event. `/handoff` writes the minimum continuation context. Compact only at a clean milestone after refreshing state.
