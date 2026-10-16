# oc-harness-setup

One command that installs and orchestrates the whole harness for the OpenCode host. It is for anyone adopting the shared setup: a single explicit `setup` run lands the agents, commands, skills, references, scripts, and base configuration the host needs, then proves the install with the harness's own doctor gate.

## Quick start

Install for real (then restart the OpenCode host):

```bash
npx --yes oc-harness-setup setup
```

Preview without touching a file:

```bash
npx --yes oc-harness-setup setup --dry-run
```

Remove everything the installer created and restore overwritten files from backup:

```bash
npx --yes oc-harness-setup setup --uninstall
```

Work on this repo (no build step; pure Node ESM, stdlib only):

```bash
git clone https://github.com/nathwn12/oc-harness-setup.git
cd oc-harness-setup
npm test
npm run check
```

## Layout

- `bin/` — the installer entry point (`cli.js`); the product's front door.
- `agents/` — the agent definitions the installer ships.
- `commands/` — the explicit rituals the installer ships.
- `skills/` — the reusable procedures the installer ships.
- `reference/` — the supporting material the installer ships.
- `scripts/` — the PowerShell helpers the installer ships, ending in the harness doctor gate.
- `.docs/` — supplementary notes not installed into the host config.
- `AGENTS.md` — this guide; it is also shipped inside the published package, so edits here are consumer-facing documentation.
- `opencode.jsonc` — the base configuration merged into the adopter's config at install time.
- `package.json` — package manifest, `files` list, and the `test` / `check` scripts.
- `README.md` — the user-facing install story.
- `CHANGELOG.md` — the Keep a Changelog record.
- `.github/workflows/` — continuous checks and the tag-driven publish workflow.

## Conventions

- Write conventional commit subjects (e.g. `docs: ...`, `chore: ...`).
- Branch as `<type>/<slug>` (e.g. `docs/repo-guide-shape`).
- Land only through a pull request; squash-merge it, then delete the branch.
- Keep `CHANGELOG.md` and the docs current with every user-visible change.
- The installed agent, command, skill, and reference files are the product, so treat edits to them as content changes — review the words, not just the code.

## Host contract

- Targets the OpenCode host generally: the only host requirement is that the host CLI is runnable when `setup` runs (preflight refuses otherwise). Requires Node >= 22; the doctor gate needs PowerShell 7, and where it is missing its checks report as skipped, not passed.
- `setup` lays down exactly the shipped content — `agents/`, `commands/`, `skills/`, `reference/`, `scripts/`, `.docs/`, plus `AGENTS.md` — into the host config location, and merges the base configuration into the adopter's config file. The destination is resolved through the host itself first, then an environment override, then platform fallbacks; it is never an invented path.
- The install is consent-first and idempotent: the full manifest prints before anything moves, and re-runs skip identical files. Existing settings survive the merge; runtime policy is owned by the pack. Every run ends on the harness doctor, and a SHA-256 journal records every touched file.
- `--dry-run` guarantees nothing is touched: it prints the manifest (or, with `--uninstall`, the removal preview) and exits before any write.
- `--uninstall` removes exactly the manifest-listed files, restores overwritten files from backup, keeps files the adopter modified after install, and never deletes the merged config file — it restores the adopter's original instead.

## Release

- Releases are cut by pushing an annotated tag `v<version>`; the publish workflow runs on the tag and publishes with no version guard of its own.
- The changelog lives in `CHANGELOG.md`.
- The documented install commands are deliberately version-free, so the README never needs a version bump.

## Guardrails

- Never add an npm script named `install`, `postinstall`, `preinstall`, `build`, `prepare`, or `prepack` — installation must never modify config by itself; setup is always an explicit command, never a side effect.
- Keep `package.json`'s `files` list and the installer's expectations in step, so a published package can never reference a file it does not ship.
- Never write outside the target OpenCode config location — the installer owns one destination and must not scatter files elsewhere.
- Keep `--dry-run` output truthful about what a real run would touch — the preview is the consent gate, so a lying preview voids consent.
