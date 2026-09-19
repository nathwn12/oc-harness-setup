# Local Skill Layer — Sources

This directory is the local, self-contained skill layer. Upstream material was inspected, adapted to this harness, and is owned locally; runtime does not depend on external checkouts.

| Source | Revision inspected (pinned) | Used for |
|--------|------------------------------|----------|
| `DietrichGebert/ponytail` (v4.9.0) | `356918eba965ee1eac64bd3a7f0dd02108350de5` | `code-simplification` (report-only review/audit modes); the lean ladder is integrated into `AGENTS.md` |
| `addyosmani/agent-skills` | `6ca0cd7db39b41b1c37e26d335c507ee92382c6d` | Active local workflow skills listed below |
| `mattpocock/skills` | `3cca18b368ae95cdbdebbff572ccafa662551015` | `grilling`, `writing-for-agents`, and `creative-writing` (modes from `writing-fragments` / `writing-beats` / `writing-shape`) |

`_shared/references/` mirrors the upstream `references/` checklists from the same addyosmani/agent-skills revision; all skills link to them via `../_shared/references/...` instead of the upstream `../../references/...` paths.

Transformations applied:

- Frontmatter normalized to OpenCode V2 (`name`, `description`, optional `metadata`). Low-frequency / collision-prone skills are marked `metadata.opencode.autoinvoke: false` (explicit-only).
- All `../../references/...` links rewritten to `../_shared/references/...`.
- Harness adaptations: `$ARGUMENTS` references are command-template aware; upstream scripts, adapters, plugins, hooks, and repo-specific policy files are not runtime dependencies.
- Ponytail adaptations: no plugin hooks, mode tracker, MCP/server code, adapter manifests, config/env default-mode machinery, or benchmark scoreboard. The always-on ladder lives in `AGENTS.md`; only report-only complexity workflows are active here.
- `swarm-orchestration` is local work, not upstream-derived; left unchanged. `git-ceremony` is likewise local/adapted work: it is the harness's own fixed git ritual, adopted without a recorded upstream and owned locally, not tracked to a pinned revision. Its worktree section absorbed the former standalone `worktree` skill on <DATE>.
- Mattpocock adaptations: ported as model-invoked local skills; upstream `disable-model-invocation` mapped to the harness explicit-only marker `metadata: {"opencode/autoinvoke": false}`; `grilling` invoked directly as a model-invoked skill (its former `/grill` wrapper command was retired <DATE>); `CLAUDE.md` references normalized to `AGENTS.md`; generic sub-agent references mapped to harness helpers (`explore`, lead-spawned children). Upstream OpenAI agent adapters and plugin packaging are not adopted. The `SKILL-MECHANICS.md` sibling reference is retained as disclosed reference.

Active Addy-derived IDs: `api-and-interface-design`, `code-review-and-quality`, `code-simplification`, `debugging-and-error-recovery`, `frontend-ui-engineering`, `incremental-implementation`, `observability-and-instrumentation`, `performance-optimization`, `planning-and-task-breakdown`, `security-and-hardening`, `source-driven-development`, `spec-driven-development`, and `test-driven-development`.

Active Mattpocock-derived IDs: `grilling`, `writing-for-agents`, and `creative-writing`. Local/adapted without a pinned upstream: `git-ceremony` (absorbed the former `worktree` skill <DATE>).

Runtime boundary: the OpenCode config uses a wildcard skill deny followed by exact allows for the active local IDs. Compatibility skill directories are not part of the local layer and are not required for any command or agent.
