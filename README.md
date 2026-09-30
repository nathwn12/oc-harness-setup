<div align="center">

# :rocket: oc-harness-setup

**The whole harness in one command.**
*Orchestrator primary . 7 agents . 14 commands . 20 skills . a doctor that proves it.*

![npm](https://img.shields.io/npm/v/oc-harness-setup) ![license](https://img.shields.io/badge/license-MIT-blue) ![opencode](https://img.shields.io/badge/opencode-v2-blueviolet) ![node](https://img.shields.io/badge/node-%E2%89%A522-green) ![downloads](https://img.shields.io/npm/dm/oc-harness-setup)

</div>

---

## :zap: Quick start

```bash
npx --yes oc-harness-setup setup
```

> Just installed OpenCode? This lands a **working harness**: an orchestrator that triages, swarms, and reduces - with the agents, commands, skills, and health gate already wired. Plug it in. Play.

---

## :wrench: What setup does

```text
preflight -> locate config -> consent gate -> backup -> install -> verify
```

- **Consent first** - the full manifest prints before anything moves; `--dry-run` shows it without touching a file
- **Your config survives** - the installer owns runtime policy (`$schema`, `default_agent`, `formatter`, `compaction`, `tool_output`, `media`, `watcher`), unions your `plugins` and `references` with the harness's, and preserves every other top-level key, known or unknown - `provider`, `model`, `agents`, `commands`, `skills`, `mcp`, or a key of your own
- **Your `permissions` still apply** - your rules are placed after the harness's allow/ask rules and ahead of its hard denies, so a rule of yours beats a harness allow while the hard denies stay last
- **Reversible** - a SHA-256 journal records every touched file; `--uninstall` removes the files the installer created and restores any file it overwrote from the pre-install backup (its path is printed before anything moves). Post-install edits to a restored file are copied aside first as `<name>.replaced-<ts>` - never destroyed
- **Idempotent** - re-run anytime; identical files are skipped
- **Verified** - ends on the harness's own 16-law doctor; red = nonzero exit, with every failing law naming the check, the detail, and a proposed fix. The doctor needs PowerShell 7: if it is missing, the laws are **skipped** and reported as skipped - not passed

> *Installation never modifies your config by itself - setup is always an explicit command you run. **No postinstall, ever.***

---

## :package: What you get

| Component | What it gives you |
|:---|:---|
| 🧠 **Orchestrator** | dispatch tiers, parallel waves, fan-in reduction, one question per close |
| 🤖 **7 agents** | orchestrator . plan . build . explore . general . reviewer . vault (secrets by pointer) |
| ⌨️ **14 commands** | build . checkpoint . code-simplify . gauntlet . handoff . keeper . kill . plan . retro . review . ship . spec . test . webperf |
| 🧪 **20 skills** | git ceremony . TDD . debugging . security . performance . test-flight . flight-deck . ... |
| 🩺 **The doctor** | 16 self-derived laws; green = consistent, regressions != drift (runs as an installer-integrated gate, not a command) |

---

## 🛡️ Safety by design

> Strict deny-set permissions that survive `--auto` . skills fail closed on unknown IDs . credentials stay by pointer . backup before any change.

### Policy

This package ships a **fail-closed permission set**: the disk-destroy and credential denies hold even under `--auto`, and skills load only from an exact allowlist - an unknown skill ID is denied, not loaded. The author's own live harness runs permission-free; the guardrails here are intentional, kept for adopters who want the safety net. Rogue-session and housekeeping machinery ships too: `/kill` (with `scripts/interrupt-session.ps1`) stops a runaway session, and `scripts/gc-clean.ps1` sweeps junk with a dry-run default. Adopters who prefer the author's freer setup can relax or remove the deny entries in the merged opencode.jsonc, with one caveat: the installer's merge re-applies the harness's deny entries on every install run - the deny tail is always placed after your rules, and under last-match-wins a re-added deny outranks any relaxation you added. To keep relaxed permissions, remove the deny entries from the merged opencode.jsonc and do not re-run setup afterwards.

---

<div align="center">

OpenCode V2 . Node >= 22 . Windows / macOS / Linux (config path auto-resolved)

**MIT © 2026 nathwn12** . For OpenCode. Free.

</div>