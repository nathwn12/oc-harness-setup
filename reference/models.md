# OpenCode Model Catalog — shipped skeleton

> **Recheck due: YYYY-MM-DD — every 3 days.** Procedure: `reference/model-test.md`.
> On recheck, move this date +3 days and re-verify the table below.

This catalog ships with no adopted models: the harness is fully unwired by
decision (see `.docs/unwired-routing.md`). When you wire an agent, add its
`opencode-go/<id>` row here first — the harness doctor's Law 8 enforces that
every live `model:` binding resolves against this table.

| # | Model (opencode-go/<id>) | Price in / out / cache-read | Monthly cap | Smart evidence | Cheap evidence | Status |
|---|--------------------------|-----------------------------|-------------|----------------|----------------|--------|

## Notes

- Columns follow the harness ordering: context gate first, then price, cap, and
  real measured evidence — never vendor claims.
- The `model:` lines in `agents\*.md` must resolve against this table; the
  harness doctor's Law 8 enforces it.
- Rank rows by judgment, not a single formula; state the judgment calls.