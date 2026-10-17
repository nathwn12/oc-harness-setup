# oc-harness-setup

**Install the whole OpenCode harness in one explicit command and prove it with its own doctor gate.**

## Install

```bash
npx --yes oc-harness-setup setup
```

First run prints a manifest of everything it will touch and waits for you to type `y`. It then lays the agents, commands, skills, references, scripts and merged base config into your OpenCode config dir and ends on the harness doctor gate. You need Node.js 22 or newer and a runnable OpenCode CLI; the doctor check needs PowerShell 7.

### Or let your AI install it

```
Install nathwn12/oc-harness-setup with `npx --yes oc-harness-setup setup`,
answer `y` at the manifest prompt, then restart OpenCode.
Verify by running the harness doctor script path the manifest printed
and report whether it passed or was skipped.
```

### Offline or pinned

```bash
npx --yes oc-harness-setup@0.3.3 setup
```

This tracks the exact published version instead of latest.

## Use it

```bash
# Preview any run without touching a file
npx --yes oc-harness-setup setup --dry-run

# Re-run the doctor check the installer laid down
pwsh -NoProfile -File <your-config-dir>/scripts/harness-doctor.ps1

# Remove everything the installer created and restore your originals
npx --yes oc-harness-setup setup --uninstall
```

Restart OpenCode after install so the new agents, commands and skills load. Re-running setup is safe: identical files are skipped.

## What you get

- Consent-first install: the full manifest prints before anything moves, and `--dry-run` changes nothing.
- Your settings survive: your model, provider, MCP and plugin keys are preserved while the pack owns runtime policy.
- Verified result: every install ends on the harness doctor gate, and failures name the check and the fix.
- Reversible: each run snapshots your config and writes a SHA-256 journal, so `--uninstall` restores your originals.
- Fail-closed permissions: your rules are layered in, with the harness hard denies kept last so nothing shadows them.

## Requirements

- Node.js 22 or newer, the only runtime requirement with zero runtime dependencies.
- OpenCode CLI installed and runnable; setup refuses without it.
- PowerShell 7 for the doctor gate; without it the doctor reports skipped, never passed.

## Links

- [Source](https://github.com/nathwn12/oc-harness-setup)
- [Published package](https://www.npmjs.com/package/oc-harness-setup)
- [Changelog](https://github.com/nathwn12/oc-harness-setup/blob/main/CHANGELOG.md)
