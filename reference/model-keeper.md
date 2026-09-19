# Model Keeper

The `keeper` maintains the model picture: the catalog in `reference/models.md.example` and the agent model bindings in the file-based agent definitions under `~/.config/opencode/agents/*.md` (the `model:` frontmatter). `opencode.jsonc` carries global defaults and may mirror bindings; for a given agent, its `agents\*.md` file is authoritative. `/keeper` is the explicit refresh point. The keeper works from live evidence and reports changes, sources, and uncertainty — or a clean no-change result.

## Keeper pass

1. Read `reference/models.md.example`, the agent files in `~/.config/opencode/agents/*.md`, `opencode.jsonc`, and the harness references that describe routing.
2. Query the live provider catalogs and list the models and variants each one offers.
3. Check official pricing, context sizes, capabilities, and available variants for the candidate models.
4. Diff the live picture against the configured bindings and the catalog: additions, removals, renames, price changes, capability changes, and variant changes.
5. Update `reference/models.md.example` and the `model:` bindings in `agents\*.md` together (touching `opencode.jsonc` only when defaults or mirrored bindings change), keeping every configured agent binding in agreement with the catalog. Only the `keeper` writes agent files; one writer per artifact.
6. Validate: every `model:` frontmatter value parses and resolves against the catalog, agent files still parse with their frontmatter, and `opencode.jsonc` (if touched) stays consistent.

## Evidence rules

- Live provider catalogs are the availability authority.
- Official provider pricing is the price authority.
- Promotions, temporary discounts, free trials, and usage multipliers are not routing evidence.
- Record cache-read rates, context tiers, and per-model allocations when the source exposes them.
- Record source URLs and the verification date in `reference/models.md.example`.
- Preserve uncertainty when sources disagree; never invent a model ID, price, or variant.
- Keep secrets by pointer only: never print, paste, log, or commit a key value.

## Cadence

Refresh after a provider catalog change, an OpenCode update, or a recurring personal review. No background watcher runs on its own; the keeper runs when invoked. A no-change result is a valid outcome.
