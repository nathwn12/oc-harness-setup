---
description: Produce an implementation plan with steps, ownership, and acceptance evidence
agent: plan
subagent: true
---

> Triage first: WHERE (blast-radius) → WHAT → HOW (ceremony) → FIRE.
> Scale ceremony to blast radius — tiny stays tiny, big gets a plan plus helpers.
> Route via the existing intent table and lifecycle; no new routes, no second router.

Plan `$ARGUMENTS`. Inspect the current system before planning (spawn `explore` for recon only when the codebase is unknown). Produce a user-facing plan:

- **Outcome:** the definition of done, stated so anyone can verify it.
- **Approach:** the shape of the solution and the lean rung it stops at (remove the need → reuse → stdlib → native platform → installed dependency → minimum change).
- **Ordered steps:** each with an owner (local specialist: `coder`, `explore`, `reviewer`, `documenter`, `keeper`), what it changes, and its acceptance evidence — the narrow runnable check that proves it.
- **Risks and open decisions:** with the smallest next action for each.

Write `plan.md` to this session's state directory (`~/.opencode/state/sessions/<session-id>/`). If the steps aren't obvious yet, state the one decision that must be sharpened rather than inventing detail. Leave implementation to `/build`.
