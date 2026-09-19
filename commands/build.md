---
description: Implement the request with the smallest working change
agent: build
---

Build `$ARGUMENTS`. Define "done" first, then implement with the smallest correct diff.

- Pick the local skill that fits: `spec-driven-development` for a new or specified feature, `incremental-implementation` for the build loop, `test-driven-development` when tests should come first, and `debugging-and-error-recovery` for hard bugs. For UI, consult `frontend-ui-engineering`; for API boundaries, use `api-and-interface-design`.
- Inspect before editing; understand the real flow, then stop at the first rung that holds.
- Preserve safety, validation, security, accessibility, reversibility, and anything the user explicitly asked for — never lean these away.
- Run the narrow check that proves the change and report: files changed, what you ran, what it proved, and residual risk.
- Mark deliberate shortcuts with `lean: <ceiling>; revisit when <trigger>` so `/ponytail-debt` can collect them.
- For work that splits at natural seams, spawn helpers in parallel with one writer per artifact; follow the `swarm-orchestration` skill.
