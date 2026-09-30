# OpenCode Model Catalog

> **Recheck due: `<date>` - every 3 days.** Procedure: `~/.config/opencode/reference/model-keeper.md`.
> On recheck, move this date +3 days and re-verify the table below.

> **TEMPLATE - adopter-owned skeleton.** This file ships EMPTY of measured data by
> design: seat wiring lives in the adopter's `agents` map (or agent frontmatter) and is
> NOT shipped with the harness. The installer PRESERVES an existing file. Rows are
> recorded per `reference/model-keeper.md` - measured routes, prices, variants, and
> history are adopter evidence, never shipped.

This is an informational catalog of model IDs, provider availability, variants, and
measured route windows. It routes nothing itself - seat routing lives in the adopter's
`agents` map or agent frontmatter. The catalog's only machine-read contract is the table
below (`scripts/harness-doctor.ps1` parses the `Model (provider/<id>)` header and the
numbered backticked rows).

Rates are USD per MTok, input / output / cache-read / cache-write. Context is
input / max output. `<...>` slots are placeholders the adopter fills on first

record; rows start empty - replace the example rows, never extend the table shape.

| # | Model (provider/<id>) | Context | Rate (in/out/read/write) | Variants | Status |
|---|----------------------|--------:|--------------------------|----------|--------|
| 1 | `provider/example-model-1` | `<context>` | `<in>/<out>/<read>/<write>` | `<variants>` | `<status>` |
| 2 | `provider/example-model-2` | `<context>` | `<in>/<out>/<read>/<write>` | `<variants>` | `<status>` |

Example rows above are structural placeholders - replace with measured rows recorded
per `reference/model-keeper.md`. No fallback ladder is shipped: provider errors are
reported by OpenCode; the catalog never retries, substitutes, or changes the selected
model.