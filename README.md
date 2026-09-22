<div align="center">

# 🚀 oc-harness-setup

**The whole harness in one command.**
*MASTER orchestrator · 14 agents · 14 commands · 18 skills · a doctor that proves it.*

![npm](https://img.shields.io/npm/v/oc-harness-setup) ![license](https://img.shields.io/badge/license-MIT-blue) ![opencode](https://img.shields.io/badge/opencode-V2-compatible-8A2BE2) ![node](https://img.shields.io/badge/node-%E2%89%A522-green)

</div>

---

## ⚡ Quick start

```bash
npx --yes oc-harness-setup setup
```

> Just installed OpenCode? This lands a **working harness**: an orchestrator that triages, swarms, and reduces — with the agents, commands, skills, and health gate already wired. Plug it in. Play.

---

## 🔧 What setup does

```text
preflight -> locate config -> consent gate -> backup -> install -> verify
```

- **Consent first** — the full manifest prints before anything moves; `--dry-run` shows it without touching a file
- **Your config survives** — the installer owns runtime policy (`$schema`, `default_agent`, `compaction`, `tool_output`, `media`, `watcher`), unions your `plugins` and `references` with the harness's, and preserves every other top-level key, known or unknown — `provider`, `model`, `agents`, `commands`, `skills`, `mcp`, or a key of your own
- **Your `permissions` still apply** — your rules are placed after the harness's allow/ask rules and ahead of its hard denies, so a rule of yours beats a harness allow while the hard denies stay last
- **Reversible** — a SHA-256 journal records every touched file; `--uninstall` removes the files the installer created and restores any file it overwrote from the pre-install backup (its path is printed before anything moves). Post-install edits to a restored file are copied aside first as `<name>.replaced-<ts>` — never destroyed
- **Idempotent** — re-run anytime; identical files are skipped
- **Verified** — ends on the harness's own 16-law doctor; red = nonzero exit with the file:line that explains it. The doctor needs PowerShell 7: if it is missing, the laws are **skipped** and reported as skipped — not passed

> *Installation never modifies your config by itself — setup is always an explicit command you run. **No postinstall, ever.***

---

## 📦 What you get

| Component | What it gives you |
|:---|:---|
| 🧠 **MASTER** | dispatch tiers, parallel waves, fan-in reduction, one question per close |
| 🤖 **14 agents** | coder · explore · reviewer · security-auditor · vault (secrets by pointer) · … |
| ⌨️ **14 commands** | doctor · council · keeper · checkpoint · plan · build · review · ship · … |
| 🧪 **18 skills** | spec-driven dev · TDD · debugging · security · performance · git ceremony · … |
| 🩺 **The doctor** | 16 self-derived laws; green = consistent, regressions ≠ drift |

---

## 🛡️ Safety by design

> Strict deny-set permissions that survive `--auto` · skills fail closed on unknown IDs · credentials stay by pointer · backup before any change.

---

<div align="center">

OpenCode V2 · Node ≥ 22 · Windows / macOS / Linux (config path auto-resolved)

**MIT © 2026 nathwn12** · For OpenCode. Free.

</div>
