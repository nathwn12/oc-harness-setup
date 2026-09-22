---
description: Build a redacted harness report with a prefilled issue URL - offer to file it, never auto-file
---

From `~/.config/opencode`, run `pwsh -File scripts\harness-report.ps1` and report what it returns. `$ARGUMENTS` may be empty, `-Json`, `-OutFile <path>`, `-ConfigDir <path>`, or `-SelfTest`.

- Redaction is enforced in code, not promised in prose: every field that reaches the body passes one chokepoint in `scripts\harness-report.ps1`. Home and config paths collapse to `~`, the installer's backup path becomes `~/.opencode-backup/<ts>`, session ids become `<session>`, hostnames `<host>`, and usernames `<user>`. Secret-like **values** are redacted in place to `<redacted>` whenever the name keys the redactor (a diagnostic line survives; only the value becomes `<redacted>`). A line is dropped whole only when it cannot be kept safely: a `{file:...}` pointer target, a path into a secret store, or a bare credential literal. Show the exact post-redaction bytes the script printed - never re-render, summarise, or "improve" them, and never re-read the files behind them.
- TRIAGE every FAIL before offering anything, one line each: **HARNESS-BUG** (the product is wrong - a missing path, a broken law, a frontmatter check that ships broken) versus **LOCAL-DRIFT** (the user's own config or machine - a stale path, a plugin they removed, a CLI they never installed). Real regressions never auto-fix; say which bucket each one falls in and why. DRIFT is neither: it means the instrument could not derive an expectation, so repair the CLI or restore the file first.
- Print the prefilled URL verbatim, then OFFER to open the issue - the human gate holds EVERY time. Never file, never call `gh`, never open a browser to the URL, and never post to the product repo on your own initiative; the human submits it or it does not happen.
- PowerShell 7 (`pwsh`) is required for the doctor, so it is required for this report. If `pwsh` is absent, both are skipped: say so plainly, print the doctor-only findings you can see by other means, and do not pretend a report was generated.
- Never read or print the secret store or `.env`; the reporter's own guard refuses those paths and `-SelfTest` proves the redactor.

Close with: verdict (clean / real regression / drift), what the report found, the exact command run, whether anything was filed (normally nothing), and one question - file it, fix locally, or leave it.
