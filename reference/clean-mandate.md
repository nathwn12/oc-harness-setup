# Housekeeper mandate (`--clean`)

A standalone `--clean` arms the housekeeper for this session: junk, trash, and test-generated files may be deleted. `--no-clean` disarms it. Unarmed, every sweep is a report-only dry run - it never deletes, no matter how much junk exists.

Auto path: at terminal close, after all workers are collected (global AGENTS.md close rule), run `scripts/gc-clean.ps1`. Armed, it deletes and reports; unarmed, it dry-runs and reports the same tables. The closing agent embeds the summary in the close report. Manual runs follow the same gate: the script never deletes without `-Force`, and `-Force` is passed only while `--clean` is armed.

Roots: `%TEMP%\opencode` and `%USERPROFILE%\.cache\opencode` (a `-Root` override exists for sandboxed test runs). Deletions are permitted for exactly these junk classes: `*.bak*` temp config backups; stale cache entries under `github\v2` for plugins not in the adopter's live set (classified only while a live set is passed via `-LiveCache`; without one, v2 entries are reported, never deleted); old-layout leftovers under `github\` that are not `github\v2\`; and directories left empty after those deletions. Repo-local untracked files are listed dry-run only - this tool never deletes them. Anything unclassified is reported, never deleted.

The keep-list is law, PROTECT-IF-PRESENT: the script itself, the reference directory, any `*.tgz` npm pack, the adopter's live v2 cache entries (`-LiveCache`), and anything passed via `-KeepExtra`. An absent keep is skipped with a note - never a hard exit. What stays a hard refusal: a junk-class misclassification (only the four classes above are ever deleted), and an unresolvable keep-list, which stops `-Force` with exit 2 - never a silent guess. The root-resolution guard also stands: nothing outside the two resolved roots (or the `-Root` sandbox) can ever be deleted.

Safety: the sweep never touches `~/.config`, `~/.local/state`, credential-bearing paths, junctions or reparse points, or anything containing obvious secrets. A secret hit is reported by path only - contents are never printed.

Report shape: before/after item list with sizes, bytes freed, keep-list confirmed intact, and the final `RESULT` line.