# Model routing is unwired by decision

- Record type: decision record.
- Status: current.

Model routing is UNWIRED by decision in this harness. All 14 agent `model:`
lines are commented out (`# model: <YOUR_MODEL>`), so every agent inherits the
session's selected model — no per-agent bindings, no catalog resolution at load
time.

- Why: the unwired state is the supported MVP baseline; bindings get re-added
  per agent only when evidence justifies a specific model.
- Verified by: the harness doctor's Law 8 — fully-unwired routing is a PASS
  state only while a `.docs` record like this one documents the decision.
- Reverting: uncomment `model:` lines in `agents\*.md` with ids that resolve
  in `reference/models.md`, or document the new wiring state here.