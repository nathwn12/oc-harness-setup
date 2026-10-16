<p align="center">
  <img src="assets/icon.svg" width="120" height="120" alt="oc-harness-setup icon" />
</p>
<h1 align="center">oc-harness-setup</h1>
<p align="center"><strong>Install and verify the whole OpenCode harness in one explicit command.</strong></p>
<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/nathwn12/oc-harness-setup" alt="License" /></a>
  <img src="https://img.shields.io/github/languages/top/nathwn12/oc-harness-setup" alt="Language" />
  <img src="https://img.shields.io/badge/platform-windows--linux-2b3137" alt="Platform" />
</p>

## Project name and description

`oc-harness-setup` is a plug-and-play installer for an OpenCode harness. One explicit command lands an orchestrator-led setup — agents, commands, skills, reference material, and helper scripts — merges a base configuration into the adopter's config, and proves the result with the harness's own multi-law doctor gate. It ships on npm as a pure Node ESM package with zero runtime dependencies, and it never touches configuration on its own: setup is always an explicit command, never a side effect.

Setting up a harness by hand means copying dozens of files and hoping they agree. This installer makes setup consent-first, idempotent, and verified: the full manifest prints before anything moves, re-runs skip identical files, and every install ends on the doctor gate. A SHA-256 journal records every touched file, so anything the installer did can be undone.

**Status:** Unverified — as-is, use at your own risk.

## Technology stack

- **Node.js ≥ 22** — the only runtime requirement (declared in `engines`); the installer is pure ESM on the standard library, zero runtime dependencies.
- **OpenCode CLI** — must already be runnable; preflight refuses to install without it.
- **PowerShell 7** — runs the harness doctor gate. Where it is missing, the doctor is reported as skipped, never as passed.
- **Bun** — test runner only (`bun test`); not needed to use the installer.

## Architecture

The installer engine (`bin/cli.js`) runs one pipeline:

1. **Preflight** — confirms the OpenCode CLI is runnable.
2. **Config discovery** — resolves the destination through the host itself first, then an environment override, then platform fallbacks. The destination is never invented.
3. **Manifest gate** — prints the full install manifest (destination, incoming files, backup path, merge plan, doctor plan) and waits for explicit `y` confirmation.
4. **Backup** — snapshots the existing config before the first write.
5. **Stage** — copies the shipped content; identical files are skipped, adopter-owned files that differ are preserved, genuine overwrites are journaled.
6. **Merge** — layers the shipped base configuration under the adopter's own keys: existing model, provider, MCP, and plugin settings survive; runtime policy is owned by the pack; permission denies stay last so nothing can shadow them.
7. **Plugins** — registers the bundled plugin(s) through the host CLI.
8. **Doctor** — ends on the harness doctor gate; failures name the check, the detail, and a fix.

Every run writes a journal manifest recording each file's hash and action, the backup location, and whether the doctor ran. `setup --uninstall` reads that journal: it removes exactly the manifest-listed files, restores overwritten files from backup, keeps files the adopter modified after install, and never deletes the merged config file — it restores the adopter's original instead.

> [!NOTE]
> `--dry-run` prints the manifest (or, with `--uninstall`, the removal preview) and exits before any write. It is the safe way to inspect any operation first.

## Getting started

### Prerequisites

- Node.js ≥ 22.
- The OpenCode CLI installed and runnable (`setup` refuses otherwise).
- PowerShell 7 if you want the doctor gate verified (otherwise it reports skipped).

### Setup

1. Run the installer and confirm at the prompt:
   ```bash
   npx --yes oc-harness-setup setup
   ```
2. Restart OpenCode so the new agents, commands, and skills load.
3. Verify with the doctor script the installer laid down in the `scripts/` directory of your OpenCode config dir (`setup` prints that directory in its manifest):
   ```powershell
   pwsh -NoProfile -File <config-dir>/scripts/harness-doctor.ps1
   ```

To preview without touching a file:

```bash
npx --yes oc-harness-setup setup --dry-run
```

To remove everything the installer created and restore overwritten files from backup:

```bash
npx --yes oc-harness-setup setup --uninstall
```

> [!WARNING]
> `--uninstall` restores pre-install files from the backup recorded in the journal. Files you modified after install are kept, never deleted — the summary tells you where each one stands.

## Project structure

- `bin/` — the installer entry point (`cli.js`); the product's front door.
- `agents/` — the agent definitions the installer ships (orchestrator-led set).
- `commands/` — the explicit rituals the installer ships.
- `skills/` — the reusable procedures the installer ships, plus shared helpers.
- `reference/` — the supporting material the installer ships.
- `scripts/` — the helper scripts the installer ships, ending in the harness doctor gate.
- `.docs/` — supplementary notes not installed into the host config.
- `AGENTS.md` — the contributor and adopter guide; also shipped inside the published package.
- `opencode.jsonc` — the base configuration merged into the adopter's config at install time.
- `package.json` — package manifest, `files` list, and the `test` / `check` scripts.
- `CHANGELOG.md` — the Keep a Changelog record; see it for release history.

## Key features

- One-command setup, then restart OpenCode.
- Consent gate: the full manifest prints before anything moves; `--dry-run` changes nothing.
- Idempotent: re-run anytime, identical files are skipped.
- Verified: ends on the harness doctor gate; failures name the check, the detail, and a fix.
- Config-preserving merge: existing model, provider, MCP, and plugin settings survive; runtime policy is owned by the pack.
- Fail-closed permissions: the deny set survives automation, and skills load from an exact allowlist.
- Reversible: a SHA-256 journal records every touched file; `--uninstall` restores from backup.
- Zero runtime dependencies: pure Node ESM, standard library only.

## Development workflow

- Write conventional commit subjects (e.g. `docs: ...`, `chore: ...`).
- Branch as `<type>/<slug>` (e.g. `docs/repo-guide-shape`).
- Land only through a pull request; squash-merge it, then delete the branch.
- Keep `CHANGELOG.md` and the docs current with every user-visible change.
- Releases are cut by pushing an annotated tag `v<version>`; the publish workflow runs on the tag.

## Coding standards

- The installed agent, command, skill, and reference files are the product — treat edits to them as content changes and review the words, not just the code.
- Never add an npm script named `install`, `postinstall`, `preinstall`, `build`, `prepare`, or `prepack`: installation must never modify config by itself.
- Keep `package.json`'s `files` list and the installer's expectations in step, so a published package can never reference a file it does not ship.
- Never write outside the target OpenCode config location.
- Keep `--dry-run` output truthful about what a real run would touch — the preview is the consent gate.

## Testing

- `npm test` — syntax-checks the installer (`node --check bin/cli.js`) and runs the suite with Bun.
- `npm run check` — dry-runs `npm pack` to prove the published tarball contains exactly what the installer expects.
- Every real install ends on the harness doctor gate, which is the acceptance check for the laid-down tree.

```bash
git clone https://github.com/nathwn12/oc-harness-setup.git
cd oc-harness-setup
npm test
npm run check
```

## Contributing

See [AGENTS.md](AGENTS.md) — it is the contributor contract (workflow, conventions, guardrails). Changes to shipped agent, command, skill, or reference content are user-visible changes: keep the changelog and docs current.

Supporting material: [reference/](reference/) (lifecycle, session state, routing, models), [.docs/unwired-routing.md](.docs/unwired-routing.md) (unwired routing notes), [CHANGELOG.md](CHANGELOG.md) (release history, Keep a Changelog).

## License

MIT — see [LICENSE](LICENSE).

<!-- nathwn12 house footer: identical in every repo. Do not edit. -->
<p align="center">
  <a href="https://github.com/nathwn12"><img src="assets/signature.svg" width="96" alt="nathwn12" /></a>
</p>
<p align="center">
  <sub>Built by <a href="https://github.com/nathwn12">nathwn12</a> · <a href="https://github.com/nathwn12?tab=repositories">All projects</a></sub>
</p>
