# Model Keeper

The `keeper` maintains the evidence-based model catalog in `~/.config/opencode/reference/models.md` and
the provider inventory (an adopter-owned companion file, e.g. `provider-model-inventory.md`, kept by the
keeper on first pass - **not** shipped with the harness). It does **not**
route models to agents and must never add, remove, or alter agent `model:` bindings.
Agent bindings exist per OWNER ORDER 2026-09-26 (`models.md` § Routing); the operator
owns them, not the keeper.

## Keeper pass

1. Read `~/.config/opencode/reference/models.md` and the provider inventory.
2. Query live provider catalogs and list available models and variants.
3. Check official pricing, context sizes, capabilities, and variants for candidate models.
4. Diff live evidence against the catalog: additions, removals, renames, price/capability
   changes, and variant changes.
5. Update the catalog and inventory only. Never add or restore an agent `model:` field,
   change the TUI selection, or select a model on the operator's behalf.
6. Validate model IDs and values against live catalogs; preserve uncertainty when sources
   disagree. Report sources, verification date, and any unverified claims.

## Evidence rules

- Live provider catalogs are the availability authority.
- Official provider pricing is the price authority.
- Promotions, temporary discounts, free trials, and usage multipliers are not routing evidence.
- Record cache-read rates, context tiers, and per-model allocations when the source exposes them.
- Preserve uncertainty; never invent a model ID, price, or variant.
- Keep secrets by pointer only: never print, paste, log, or commit a key value.

## Cadence

Recheck the date at `~/.config/opencode/reference/models.md:3`. Refresh after a provider catalog change, an
OpenCode update, or the listed review date. No background watcher runs on its own; the
keeper runs when invoked. A no-change result is valid.

Each pass also snapshots `https://opencode.ai/data` (the public usage board) into
the adopter's model data log (e.g. `model-data-log.md` beside `models.md`, created on first
pass - **not** shipped with the harness) for the tracked stable lineup: board rank, weekly tokens
and Δ, weekly retention, cost/session, and the model's Go allowance. Free, promo/
contributor, experimental, and superseded models are excluded from tracking. Record
events and claims with date, source, and a verification tag (**VERIFIED** / **UNVERIFIED**).
A no-change result is valid there too.

`~/.config/opencode/reference/model-test.md` is the optional Go-only contender bench for adding evidence to
the catalog; it does not change agent routing.
