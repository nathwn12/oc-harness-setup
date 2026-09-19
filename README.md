# my-oc-harness

Plug-and-play OpenCode harness: MASTER orchestrator, agents, commands, skills, doctor — installed by one explicit command.

## Install

```sh
npx --yes my-oc-harness setup
```

The installer (`bin/cli.js` — plain Node, zero dependencies) preflights `opencode --version`, finds your config dir, prints an install manifest, backs up your config dir to `<config>.bak-my-oc-harness-<timestamp>`, copies the `agents/` `commands/` `skills/` `reference/` `scripts/` tree plus `AGENTS.md`, merges its `opencode.jsonc` with yours (keeping your `model`, `providers`, `mcp`, `plugins` under the harness base), registers the `oc-flight-deck` plugin, and runs the doctor when PowerShell 7 is present. Everything it writes is journaled with SHA-256 hashes in `<config>/my-oc-harness.manifest.json`; rerunning is safe — identical files are skipped.

**Where the backup is:** `<config>.bak-my-oc-harness-<timestamp>` (a full recursive copy of your config dir taken before anything is written).

**How to undo:** `npx my-oc-harness setup --uninstall` — deletes exactly the manifest-listed files (anything you modified yourself is kept and reported), then prints the path to restore your backup.

**Installation never modifies your config by itself — setup is always an explicit command you run.**

## Flags

| Flag | Behavior |
| --- | --- |
| `--dry-run` | print the install manifest, touch nothing |
| `--ci` | print-only, refuse to mutate, exit 0 |
| `--fleet` | also register the `oc-freedom-fleet` plugin |
| `setup --uninstall` | remove exactly the manifest-listed files |

## Troubleshooting (read this first)

| Symptom | Fix |
| --- | --- |
| `npx: command not found` | No Node.js on PATH. Install Node ≥ 22 (nodejs.org), reopen your shell, and re-run. |
| `pwsh: command not found` | PowerShell 7 is optional — it only powers `/doctor`. `winget install --id Microsoft.PowerShell --source winget` (Windows) or `brew install --cask powershell` (macOS). Setup still succeeds without it. |
| Corporate npm proxy blocks the install | Point npm at your proxy/mirror: `npm config set https-proxy http://your-proxy:port` and `npm config set proxy http://your-proxy:port`, or `npm config set registry https://npm.yourcorp.example/` for an internal mirror. |
| WSL | Run the command inside the WSL shell — it installs into the Linux-side config (`~/.config/opencode`). It will not touch your Windows-side config. |
| `opencode: command not found` | OpenCode V2 must be installed and on PATH first (the installer refuses to proceed without it). |

## No-Node fallback (below the fold)

The engine is plain Node — you can't run it without Node. If Node ≥ 22 is available but npm/npx is not (offline mirror, sandbox), clone the repo and run the same engine straight from the checkout — same gates, backup, and journal, no install step:

```sh
git clone https://github.com/nathwn12/my-oc-harness.git
cd my-oc-harness
node bin/cli.js setup
```

`node bin/cli.js --dry-run` shows the manifest first. Hand-copying files into `.config/opencode` is NOT supported — the engine exists to make installs verifiable, journaled, and undoable.

## Prerequisites

- OpenCode V2 (on PATH — `opencode --version` must succeed).
- Node.js ≥ 22 (the CLI uses `import.meta.dirname` and modern stdlib).
- PowerShell 7 — optional, powers `/doctor` only.

## Why no postinstall script

npm runs install scripts non-interactively with no consent moment and no uninstall hook — by design, this package has none. `setup` is the only path that touches your config, and it always asks first.

## Typosquatting

Install via the exact name `my-oc-harness` (author `nathwn12`, repo `github.com/nathwn12/my-oc-harness`). Verify the package page before running anything you didn't intend to.

## License

MIT © 2026 nathwn12