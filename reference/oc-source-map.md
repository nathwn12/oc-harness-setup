# oc-source map — OpenCode V2 monorepo (local)

**What this is:** the map of the `oc-source` reference — the operator's daily-updated local copy of the OpenCode V2 monorepo at `<OC_SOURCE>`. Where the docs live, which files are authoritative for what, and where to start reading. Written for agents; everything below is local on disk, no web required. Pairs with the `oc-source` entry registered in `opencode.jsonc`.

**Rules of use**
- **Read-only:** never edit that checkout — it is a reference, not a workspace.
- **Freshness first:** run the recipe below before citing it; prefer this checkout over web docs.
- **Cite by commit:** `path @ <short-HEAD>` (e.g. `specs/v2/session.md @ 96f23508bed1`).
- **Confirm load-bearing paths at HEAD:** the tree moves; re-check before betting a decision on a file.

## Freshness — run before citing

```powershell
git -C <OC_SOURCE> status --short --branch  # expect: ## v2...origin/v2 and a clean tree
git -C <OC_SOURCE> rev-parse --short HEAD  # note the hash for citations
```

Last verified: 2026-09-29 · HEAD b29dab3231d4 · clean on `v2...origin/v2`. Bounded recheck: root shape and listed absences below, sampled paths, and `specs/v2/session.md`; the full map was not exhaustively revalidated. Detailed package-map citations remain tied to their historical revision unless rechecked.

## Self-update nudge

The freshness recipe above already runs first; compare its `git rev-parse --short HEAD` against the "Last verified" anchor:

- **HEAD differs from the anchor** → re-anchor on the spot: re-run the bounded recheck — root top-level shape, the `package.json`-absence list (`console`, `containers`, `effect-drizzle-sqlite`, `identity`, `stats`), and `specs/v2/session.md` present — then update all three anchor lines (the "Last verified" block and both `(rechecked … at <hash>)` tags) to the new date/hash. Note any shape changes in the session report.
- **HEAD commit date older than 2 days** (`git log -1 --date=short`) → surface in the session: "oc-source checkout stale — run `pwsh <OC_SOURCE>\update-all.ps1` to refresh, then re-run the recipe and re-anchor." State plainly: that script runs `git fetch --all --prune --tags` + `git reset --hard` + `git clean -fdx` on **every** git repo under the umbrella directory that contains `<OC_SOURCE>`, not just this checkout.

Nothing else: no scheduling, no `AGENTS.md`/owner-pin edits, no command file (a `/oc-refresh` command was explicitly declined). The nudge fires only in sessions that load this map.

## 1. Start here — root files, in reading order

| Path | What it is | Why read it |
|---|---|---|
| `README.md` | Project identity, install, screenshots, translated copies (`README.*.md`) | Orientation only |
| `CONTRIBUTING.md` | Contribution guardrails — what PRs get accepted, `bun dev` loop | Before touching code |
| `AGENTS.md` | Contributor-critical regression guardrails (authoritative per `specs/v2/README.md`) | **Read first** before any change |
| `specs/v2/README.md` | Authority table + index of the design specs | Pick what to trust |
| `SECURITY.md` | How to report issues | Optional |
| `STATS.md` | Historical download numbers, not product info | Skip |

**Top-level shape** (rechecked 2026-09-29 at `b29dab3231d4`): `packages/` (34 dirs) · `sdks/vscode` · `services/` (www, files, update) · `specs/v2` · `infra/` (SST infrastructure: `app.ts`, `console.ts`, `lake.ts`, `monitoring.ts`, …) · tooling: `script/`, `patches/`, `nix/`, `github/` · worktrees: `artifacts/`, `perf/`.

## 2. Docs — online ↔ local map

`https://opencode.ai/v2/llms.txt` is just a **manifest of pages built from this repo**. Every doc page = a Markdown (`mdx`) file under `services/www/src/docs/content/` — the documentation source of truth.

| llms.txt URL | Local file |
|---|---|
| `/v2/docs/` | `services/www/src/docs/content/index.mdx` |
| `/v2/docs/config/` · `/agents/` · `/models/` | `…/content/config.mdx` · `agents.mdx` · `models.mdx` |
| `/v2/docs/<page>/` — skills, themes, commands, plugins, providers, websearch, network, snapshots, compaction, formatters, references, attachments, tools, mcp-servers, permissions, policies, instructions, sharing, warming, troubleshooting, migrate-v1 | `…/content/<page>.mdx` |
| `/v2/docs/cli/…` — acp, commands, config, keybinds, plugins, providers, theme, tui, web | `…/content/cli/<name>.mdx` |
| `/v2/docs/build/…` — client/, plugins/, sdk/ groups (nested) | `…/content/build/<path>.mdx` |
| `/v2/docs/console/…` — budgets, byok, go, inference, models, usage, websearch | `…/content/console/<name>.mdx` |
| `/v2/docs/api/` | `services/www/src/pages/docs/api` — **generated** from `services/www/openapi.json` |

> **Caveat:** the *published* site may be ahead of the checkout. Read the `.mdx` files when docs must match this exact commit.

## 3. Specs — authoritative design contracts

**`specs/v2/`** — documents explaining V2 behavior that is hard to recover from one source file. `specs/v2/README.md` marks which are current contracts, decision records, or historical.

| Document | Job |
|---|---|
| `README.md` | Authority table + doc index — read first |
| `session.md` | Current contract: prompt admission, execution, instructions, compaction, recovery boundaries |
| `tools.md` | Current contract: tool construction, registration, execution, outcome laws |
| `event-stream-architecture.md` | Decision record (accepted): one encoded event feed with independent queues |
| `provider-policy.md` | Decision record (accepted): provider allow/deny + permission checks; Console-managed statements have final authority |
| `catalog-config-plugin-lifecycle.md` | Historical: the option comparison → replayable Location-scoped catalog transforms (may use obsolete names) |

**Authority chain** (from `specs/v2/README.md`):

| Concern | Owner |
|---|---|
| HTTP operations / transport errors | `packages/protocol/src` (assembled by `packages/server` HttpApi) |
| Public domain shapes / durable event payloads | `packages/schema/src` |
| Runtime behavior / persistence | `packages/core/src` |
| Contributor guardrails | root `AGENTS.md` |

## 4. Package map — `packages/` (34 dirs)

Each is a `@opencode/<name>` package; start at `src/`.

| Package | What it is | Start reading |
|---|---|---|
| `cli` | The CLI binary — commands, config, ACP, framework, node runtime | `src/run`, `src/commands`, `src/acp` |
| `core` | Runtime behavior, persistence, account, instance, events, codemode | `src/` (largest; read `specs/v2` first) |
| `protocol` | HTTP endpoint definitions, client, errors, simulation | `src/api.ts`, `src/groups` |
| `schema` | Domain shapes, durable event payloads, v1 compat | `src/*.ts` (event.ts, session shapes…) |
| `server` | Effect HttpApi assembly, transport | `src` |
| `ai` | Agent/AI layer — internal design: `docs/media-design.md` | `src`, `docs/` |
| `client` | Generated/typed HTTP client | `src` |
| `sdk` | Public SDK | `src` |
| `plugin` | Plugin API surface | `src` |
| `tui` | Terminal UI | `src` |
| `ui` | Shared UI components | `src` |
| `theme` | Themes | `src` |
| `web` | Web app + lander (screenshot: `src/assets/lander/screenshot.png`) | `src/pages`, `src/components` |
| `app` | App shell | `src` |
| `desktop` | Desktop app | `src` |
| `plugin-browser` | OpenCode's desktop browser plugin (own package — not under `desktop`) | `src` |
| `console` | Cloud console — packages in subdirs `app`, `core`, `function`, `mail`, `resource`, `support` | `app/src` |
| `session-ui` | Session UI | `src` |
| `codemode` | Effect-native confined code execution over schema-described tools | `src` |
| `httpapi-codegen` | Generates clients from the HttpApi | `src` |
| `simulation` | Simulation/testing harness | `src` |
| `http-recorder` | Record/replay Effect HTTP+WS traffic as cassettes (for tests) | `src` |
| `script` | Scripting helpers | `src` |
| `util` | Shared utilities — internal design: `docs/layer-node.md` | `src`, `docs/` |
| `effect-drizzle-sqlite` | SQLite adapter (no `package.json` — source dir) | root |
| `containers`, `identity`, `stats`, `enterprise`, `function`, `latex`, `merman`, `posts`, `storybook` | Misc/infra — inspect when a task touches them | root |

> Root `package.json` absent in: `console` (per-subdir packages), `containers`, `effect-drizzle-sqlite`, `identity`, `stats` (rechecked 2026-09-29 at `b29dab3231d4`).

## 5. Services & SDKs

| Path | What it is |
|---|---|
| `services/www` | **The docs site** (Astro) — docs content in `src/docs/content/`, API pages from `openapi.json`, pages in `src/pages/docs` |
| `services/files` | `@opencode/files` service |
| `services/update` | `@opencode/update` service |
| `sdks/vscode` | VS Code extension (`src`, `README.md`, esbuild build) |

## 6. Topic → file quick index

> "I need to know how X works" → start here.

| Topic | Go to |
|---|---|
| Anything user-facing about the product | `services/www/src/docs/content/` (docs) or `specs/v2/` (contracts) |
| Session lifecycle, compaction, recovery | `specs/v2/session.md` + `packages/core/src` |
| Tools (definition/registration/execution) | `specs/v2/tools.md` + `packages/schema/src` |
| HTTP API surface / endpoints / errors | `packages/protocol/src` + `services/www/openapi.json` |
| Domain types / durable events | `packages/schema/src` |
| Persistence / runtime behavior | `packages/core/src` |
| CLI commands, ACP, config load | `packages/cli/src` |
| Agent internals / AI layer | `packages/ai/src` + `packages/ai/docs/` |
| Plugin API | `packages/plugin/src` (docs: `content/plugins.mdx`) |
| Desktop browser plugin | `packages/plugin-browser/src` |
| Providers / models / permissions | docs `content/providers.mdx` + `specs/v2/provider-policy.md` |
| UI (web/desktop/console) | `packages/web` · `packages/app` · `packages/desktop` · `packages/console` · `packages/ui` |
| Tests & cassettes | `packages/http-recorder` · `packages/simulation` |
| Infra / deploys | `infra/*.ts` (SST) + `services/` |

## 7. Dev loop (from `CONTRIBUTING.md`)

```bash
bun install                    # from repo root
bun dev [directory]            # run V2 CLI + TUI against a directory (`.` = this repo)
bun run dev:live [directory]   # TUI against installed background service
```

For web development, run the backend and app in separate terminals (`bun run dev:web`). UI/core product features require design review before implementation.

## 8. Gotchas

- **Docs drift:** `services/www/src/docs/content/` is the local truth; the live site may be a newer deploy.
- **Generated API docs:** `docs/api/` pages derive from `openapi.json` — edit the HttpApi (`packages/protocol`), not generated pages.
- **Specs are contracts, not history:** `specs/v2/README.md` marks current vs decision vs historical; historical docs may use obsolete names.
- **No implementation checklists in `specs/v2`** — actionable work belongs in GitHub issues.
- **Branch/HEAD move:** this checkout is `v2`; the repo default branch + published release may differ. Re-run the freshness recipe before citing.
- **A deployed surface can postdate this checkout.** `/zen/go/v1/usage` answers 200 in production while `routes/zen/go/v1/` here holds only `chat/completions`, `messages`, `responses`, `models` (2026-09-26). A local grep proves what the *checkout* contains — never that a live endpoint is absent. When a plan depends on a service's shape, probe the deployed surface (a 401-vs-404 difference is evidence) or read the deployed docs before concluding "doesn't exist".
