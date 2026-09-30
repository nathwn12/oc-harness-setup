---
name: git-ceremony
description: "Explicit-only Git workflow activated by --gc or a direct request for branch, commit, PR, merge, tag, version, release, or worktree ceremony."
metadata:
  "opencode/autoinvoke": false
---

# Git Ceremony

The repository's own instructions win. This skill is the fallback when the user explicitly activates Git work.

## Sequence

1. Inspect repository rules, status, branch, remotes, default branch, and staged/unstaged/untracked work. Preserve unrelated user changes.
2. Classify the requested mutation and confirm any destructive, public, production, or history-rewriting step that lacks explicit authorization.
3. Sync with fast-forward-only behavior only when requested or required for the named endpoint.
4. Use a short typed branch when review isolation is appropriate: `feat/`, `fix/`, `docs/`, `refactor/`, `test/`, or `chore/` plus a lowercase slug.
5. Stage only intended files. Review the staged diff and scan for secrets, generated noise, and line-ending churn.
6. When a commit is requested or required for the named endpoint, commit one logical change with `<type>(<scope>): <imperative summary>`; omit scope when it adds no value.
7. Push, open a PR, merge, tag, version, or release only when the request includes that step. Never infer publication from a build or test request.
8. Verify the resulting status and remote state; report exact evidence and anything still local.

Use only the deterministic wrappers named in `~/.config/opencode/reference/gc-scripts.md`. If a wrapper cannot express an authorized operation, report that boundary before using a native command. `gc-release -MovingLatest` is valid only when repository policy explicitly declares that nonstandard scheme.

For worktrees, first verify the destination is outside tracked content or ignored, create from an explicit base, and never move uncommitted changes between worktrees. Version bumps and releases must follow the repository's format and policy; otherwise use SemVer and keep a bump isolated from unrelated code.

Never commit secrets, debug residue, or unrelated files. Do not clean, reset, rebase, force-push, merge, tag, or publish beyond the requested scope.
