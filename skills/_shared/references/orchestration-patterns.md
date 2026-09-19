# Orchestration Patterns

Local reference for this OpenCode V2 harness on Windows, adapted from the
upstream reference. The governing rule is unchanged: **one level deep** —
the lead may spawn helpers; helpers return findings and do not spawn
grandchildren — and the multi-step pipeline stays user-driven: the user (or
a slash command) drives define → plan → build → verify → review → ship and
keeps the human checkpoints between steps. For a single request, the
`master` agent leads and dispatches helpers but does not implement
project code. The detailed playbook is
`~/.config/opencode/skills/swarm-orchestration/SKILL.md`.

## Runtime boundaries

- Global agents are Markdown files under `~/.config/opencode/agents/*.md`.
- Commands are Markdown templates under `~/.config/opencode/commands/`.
- Skills are loaded only when their exact ID is allowed by the config; the
  wildcard skill rule is deny, followed by exact allows for local skills.
- There are no plugins, MCP servers, or HTTP skill catalogs in this harness.
- `explore`, `reviewer`, `security-auditor`, `test-engineer`, and
  `web-performance-auditor` are read-only report producers (edit and
  subagent permissions denied; they report, they don't act). `documenter`
  and `keeper` write only their assigned artifacts.
- Anti-patterns B and D below are blocked by construction in this harness:
  helpers cannot spawn grandchildren, so depth stays at most 1.
- Parallel fan-out means launching multiple `subagent` calls together in one
  turn; sequential turns serialize execution.

## Endorsed patterns

### 1. Direct invocation (default)

Use one helper for one perspective on one artifact. This is the default and
the cheapest option.

```text
lead → helper → report → lead
```

**Use when:** one perspective on one artifact, describable in one sentence.
The baseline to compare everything against — don't orchestrate what one
focused agent can do.

### 2. Single-helper command

Use a slash command when the same focused operation repeats. The command body
should state the task and output contract, not decide which helper to call.

**Anti-signal:** if the command's body is mostly "decide which helper to
call," delete it and document the intent mapping in `AGENTS.md` instead.

### 3. Parallel fan-out with merge

Use parallel child sessions only when the work is independent, each child has
a distinct lens, and the lead can merge the reports without another routing
layer. Independent helpers run on the same input, each producing its own
report; the lead synthesizes in its own context.

```text
                 ┌─→ reviewer ──────────┐
lead ─ fan out ──┼─→ security-auditor ──┤→ lead merges → decision
                 └─→ test-engineer ─────┘
```

`/ship` uses this composition. Add `web-performance-auditor` when a web
performance question is actually in scope. Each child gets a short brief with
what, where, done, and how to prove it; children edit nothing.

Before fanning out, check:

- [ ] Sub-tasks genuinely independent (no shared mutable artifact, no
  ordering dependency)?
- [ ] Each child answers a different question — a different *kind* of
  finding, not the same finding from another angle?
- [ ] The lead has room to reconcile the reports (merge stays small enough
  for the lead's context)?
- [ ] Parallelism saves meaningful wait time (wall-clock saving is
  noticeable)?

If any answer is no, use direct invocation or a single-helper command.

### 4. User-driven lifecycle

Dependent work stays visible and sequential: define → plan → build → verify →
review → ship. The user runs the commands in order and makes the checkpoints;
do not add a coordinator that merely paraphrases each step. No agent automates
this whole pipeline — automating the full sequence loses human checkpoints,
paraphrases away nuance between steps, and roughly doubles token cost.
(A single request may still be led by the `master` agent, which
dispatches helpers and does not implement project code.)

### 5. Read-heavy isolation

When the input is much larger than the required result, spawn `explore` with a
read-only brief. Require a compact digest with file/line or URL pointers, not
large pasted inputs. The lead owns the decision and any follow-up.

```text
lead → explore (reads widely) → digest → lead continues
```

**Use when:** the result is much smaller than the input it consumes. This
harness's `explore` agent is purpose-built for this: read-only, no spawning,
pointers over pastes.

## Anti-patterns

### A. Router helper ("meta-orchestrator")

A helper whose only job is choosing another helper adds two paraphrasing hops
(information loss, ~2× tokens) for zero domain value. Put stable intent
mapping in `AGENTS.md` or a slash command.

### B. Helper-to-helper chaining

A child that launches another child hides cost, multiplies failure modes, and
loses context. Return a recommended follow-up; let the lead or user decide.

### C. Automated sequential coordinator

An agent that silently runs the entire lifecycle removes human checkpoints and
drifts through repeated summaries (roughly double cost). Keep dependent steps
user-driven.

### D. Deep trees

Command → coordinator → coordinator → worker is not allowed here. Every layer
adds latency and tokens with no decision value; leaf helpers lose context to
multiple summarization steps. Keep depth at most 1 (command → helpers); the
merge happens in the lead session.

## Decision flow

```text
Is the work one perspective on one artifact?
├── Yes → direct invocation. Stop.
└── No  → will the same composition repeat?
         ├── No  → direct invocation, ad hoc. Stop.
         └── Yes → independent sub-tasks with distinct outputs?
                  ├── No  → sequential user-driven commands (Pattern 4).
                  └── Yes → parallel fan-out with merge (Pattern 3).
                           Validate against the checklist above; if any check
                           fails → fall back to a single-helper command.
```

## When to add a new pattern to a local catalog

Only after: (1) used at least twice in real work, (2) a concrete artifact
demonstrates it, (3) you can say why an existing pattern wouldn't have worked,
(4) you can name its anti-pattern shadow. Premature catalog entries become
aspirational documentation no one follows.

Every helper report names the evidence it checked, separates fact from
inference, and ends with the smallest next action. No pattern justifies
weakening validation, security, accessibility, reversibility, or explicit
requirements.
