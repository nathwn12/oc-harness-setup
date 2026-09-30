# gc-* script map

Use these wrappers only for the Git action the user requested or the named endpoint requires.

- **Verbs:** `gc-status` · `gc-sync` · `gc-branch` · `gc-stage` · `gc-commit` · `gc-push` · `gc-pr` · `gc-merge` · `gc-rebase` · `gc-bump` · `gc-read` — each as `pwsh -NoProfile -File ~/.config/opencode/scripts/gc-<verb>.ps1 -RepoRoot <path>`.
- **Output:** terse by default — one `RESULT: <json>` line on stdout; FAIL/WARN/security lines always visible; `-Detailed` restores narration; `-Quiet` is a compatibility no-op.
- **Release exception:** `gc-release -MovingLatest` is available only when repository policy explicitly declares the nonstandard single moving `latest` scheme. Ordinary releases follow repository instructions.
- **Smoke:** never - operator ruling 2026-09-29: do not run `gc.smoke.ps1`; treat the gc-* wrappers as trusted without a pre-flight gate.
