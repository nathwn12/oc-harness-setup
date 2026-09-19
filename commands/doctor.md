---
description: Check harness health with derived laws - report regressions vs drift, never auto-fix
---

From `~/.config/opencode`, run `pwsh -File scripts\harness-doctor.ps1` and report what it returns. `$ARGUMENTS` may be empty, `-Json`, or `-Fix`.

- The doctor is self-contained: every law is derived from the config, the registries, the model catalog, and `.docs` — there is no separate checker and no allowlist to reconcile. Report the per-law PASS/FAIL/DRIFT summary first, then two separate lists: **regressions** (an evaluated law FAILED - the harness actually broke) and **drift** (the instrument could not derive an expectation: CLI missing, delegated command failed or changed shape, catalog missing). Never blend them.
- For regressions, report the one-line owner proposal and stop; for drift, report the owner action (repair the CLI, restore the file). `pwsh -File scripts\harness-doctor.ps1 -Fix` writes nothing - derived laws carry no declared state to patch, so it re-evaluates and lists what needs an owner action. Confirm it wrote nothing.
- Never weaken, delete, or comment out a law to reach green, and never edit `opencode.jsonc`, `agents\*.md`, or any skill from this command.
- Never read or print the secret store or `.env`; the doctor's own guard refuses those paths and self-tests each run.
- The doctor covers 16 derived laws. Laws 12-16 are static permission/frontmatter laws (check-only, never write):
  - Law 12 denies-last: every hard deny trails all same-action allows (skill allowlist exempt by design).
  - Law 13 no-broad-allow: no `node *` / `git *` / second bare `*` shell allow beyond the single documented unattended-shell default.
  - Law 14 skill-allowlist set equality: allow entries and local skill IDs agree in both directions.
  - Law 15 agent/command frontmatter: `agents/*.md` carry description+steps, `commands/*.md` carry description.
  - Law 16 skill-loadable: every skill directory carries a `SKILL.md` with name+description and no YAML-breaking plain scalar.

Close with: verdict (clean / drift / real regression), the exact commands run, files changed (normally none), and the next action.
