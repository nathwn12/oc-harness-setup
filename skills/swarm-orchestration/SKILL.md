---
name: swarm-orchestration
description: How to divide work and run parallel helpers in this harness — splitting, briefs, ownership, verification, and session state.
---

# Swarm playbook

## Scale first (triage)
Triage every task to a dispatch tier before spawning. Complexity prompts consideration; the widening gate picks the tier.
- **T0 grunt/basic** — known answer, one artifact: direct, or one helper. Cap 1 child.
- **T1 medium/everyday** — visible seams, known topology: one wave of 2–4 parallel readers; writers serial. Cap 1 wave.
- **T2 complex/unknown** — breadth-shaped, unknown topology: readers (up to 4) → fan-in → writers on different artifacts → verify (≤3). Cap 3 waves, ~8–10 children.
- **Widening gate (all four, or drop one tier):** independent seams exist · breadth-shaped, not a dependency chain · exactly one writer per artifact · fits the session budget.
- **Re-triage:** tiers are provisional — recon can promote T1→T2, demote T2→T1, or collapse T2→T0. There is no fourth tier.

## When
- Independent parts (different files, questions, or phases) → run them in parallel.
- Spawn when it shortens the path; don't spawn for tiny serial work.

## Split
- By artifact: one writer per file.
- By question: one explorer per uncertainty.
- By phase: recon → build → verify; fan out inside a phase, not across dependencies.
- **Widen, don't deepen:** depth stays 1 — helpers never spawn helpers. Aggression is width at one level, not depth.

## Brief a helper
- What: the deliverable. Where: the paths. Done: the acceptance check. Prove: the evidence to return.
- Pointers over pastes. Never secrets.
- Require a compact return: ≤5 lines plus `file:line`/URL pointers; large detail goes to a state file, not the conversation.

## Run
- Launch independent children together; keep real dependencies sequential.
- **Fire everything at readers; serialize writers; cap everyone.** 4 readers / 3 verifiers per wave.
- The lead keeps the map: who writes what, what's done, what's next.
- On a rate-limit or 429 storm: collapse to T0, report it, do not retry-storm.

## Fan-in (the lead is the reducer)
- The lead merges every report into one severity-ordered list; helpers never write shared state.
- Re-check, from fresh evidence, any claim two reports disagree on. Never trust an unchecked claim.
- A late report must not silently overwrite a peer — merge explicitly, never append blindly.

## Control
- Never end a turn with a background child still running — collect it or kill it. An orphan keeps working unseen.
- Rogue, looping, or wedged child → `panic`, immediately and without asking.
- `panic --dry-run` lists what it would stop; `panic --session <id>` targets one; `panic --remove --timeout 0` kills instantly. Interrupt first, `--restart` last: a restart can *resume* a suspended child.
- Bind long research: a `steps:` ceiling in the agent's frontmatter makes it return a shorter report instead of running until the parent's turn ends.

## Verify & close
- Fresh eyes on real output: rerun the narrow check; use `reviewer` when independence matters.
- Reconcile evidence, then report result, evidence, risk, next.
- Close every dispatch in a named terminal state: `success · no-op · blocked · stalled · exhausted`.

## State
- Track `goal.md`, `plan.md`, `checkpoint.md`, `handoff.md` under `~/.opencode/state/sessions/<session-id>/`; hand helpers the state path when they should record findings.
