# Local Skill Layer — Sources

This directory is the local, self-contained skill layer. Upstream material was inspected, adapted to this harness, and is owned locally; runtime does not depend on external checkouts.

| Source | Revision inspected (pinned) | Used for |
|--------|------------------------------|----------|
| `DietrichGebert/ponytail` (v4.9.0) | `356918eba965ee1eac64bd3a7f0dd02108350de5` | `code-simplification` (explicit behavior-preserving editing workflow) |
| `addyosmani/agent-skills` | `6ca0cd7db39b41b1c37e26d335c507ee92382c6d` | Active local workflow skills listed below |
| `mattpocock/skills` | `3cca18b368ae95cdbdebbff572ccafa662551015` | `grilling`, `writing-for-agents`, and `creative-writing` (modes from `writing-fragments` / `writing-beats` / `writing-shape`) |

`_shared/references/` mirrors the upstream `references/` checklists from the same addyosmani/agent-skills revision; all skills link to them via `../_shared/references/...` instead of the upstream `../../references/...` paths.

Transformations applied:

- Frontmatter normalized to OpenCode V2 (`name`, `description`, optional `metadata`). Low-frequency / collision-prone skills are marked `metadata.opencode.autoinvoke: false` (explicit-only).
- All `../../references/...` links rewritten to `../_shared/references/...`.
- Harness adaptations: `$ARGUMENTS` references are command-template aware; upstream scripts, adapters, plugins, hooks, and repo-specific policy files are not runtime dependencies.
- Ponytail adaptations: no plugin hooks, mode tracker, server code, or benchmark scoreboard. Explicit simplification lives in `code-simplification`.
- Orchestration is owned by `~/.config/opencode/agents/orchestrator.md`; the former orchestration, incremental-build, and review entrypoints were folded into role prompts and removed.
- Mattpocock adaptations use OpenCode's explicit-only marker where appropriate; `CLAUDE.md` references are normalized to `AGENTS.md`. The `SKILL-MECHANICS.md` sibling remains the mechanics reference.

Active Addy-derived IDs: `api-and-interface-design`, `code-simplification`, `debugging-and-error-recovery`, `frontend-ui-engineering`, `observability-and-instrumentation`, `performance-optimization`, `planning-and-task-breakdown`, `security-and-hardening`, `source-driven-development`, `spec-driven-development`, and `test-driven-development`.

Active Mattpocock-derived IDs: `grilling`, `writing-for-agents`, and `creative-writing`. Local/adapted without a pinned upstream: `git-ceremony`.

Runtime boundary: descriptions advertise routing conditions; exact procedures load only when matched. Commands use exact IDs for explicit-only workflows.
