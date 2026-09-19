---
description: Bounded parallel review fan-out, then a lead go/no-go merge decision
---

Ship gate for `$ARGUMENTS` (default: the current changes). Three phases; do not skip the merge step.

## Phase 1 — Bounded parallel fan-out

Verify in parse → smoke → fresh-eyes order: well-formed first, then the narrow runnable check, then independent review.
Never weaken the check to fake a green; report check output verbatim, not paraphrased.
The 3-way fan-out below is unchanged.

Spawn these three specialists **in parallel** with short briefs (what, where, done, how to prove it). Bounded: each gets one pass, no grandchildren, findings only — nobody edits files.

- **`reviewer`** — independent verification: inspect the changes and their real behavior, run the checks that matter, report findings in severity order with file:line evidence, end with exactly one verdict (`pass`, `revise`, `blocked`).
- **`security-auditor`** — security-only pass: boundary validation, secrets by pointer, injection surfaces, auth/authz changes, unsafe dependency additions. Report findings in severity order with file:line evidence and a verdict (`pass`, `revise`, `blocked`).
- **`test-engineer`** — test evidence: run the existing suite, confirm coverage of the changed behavior, report what passed/failed/untested and the risk that leaves. Verdict (`pass`, `revise`, `blocked`).

## Phase 2 — Lead merge

As lead, merge the three reports yourself. Do not spawn a router agent. Resolve conflicts from fresh evidence (re-check a claim yourself if two reports disagree); never trust an unchecked claim. Collapse into one findings list in severity order.

## Phase 3 — Go/no-go

Emit exactly one decision:

- **GO:** all three verdicts pass; no open high-severity findings; evidence is fresh. Next: ship via the repository's normal flow, preserving its existing isolation and commit checks.
- **NO-GO (revise):** any `revise` verdict or high-severity finding. List the smallest fixes with owners (`coder` for implementation, `test-engineer` for gaps), then re-run `/ship` after they land.
- **NO-GO (blocked):** any `blocked` verdict, or a safety-constraint violation (validation, security, accessibility, secrets, reversibility). State the blocker and the explicit next action.

Report the three verdicts, the merged findings, and the decision. Close with result, evidence, remaining risk, next step.
