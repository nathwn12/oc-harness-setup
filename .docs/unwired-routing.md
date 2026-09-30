# Model routing is unwired by decision

- Record type: decision record.
- Status: current.

Model routing is UNWIRED by decision in this harness. The 7-seat roster -
orchestrator, plan, build, explore, general, reviewer, vault - ships with no
live model pins: no agent file carries a `model:` line, so every agent
inherits the session's selected model - no per-agent bindings, no catalog
resolution at load time.

- Why: the unwired state is the supported MVP baseline. Wiring belongs to the
  adopter, not the package: bindings are added in the adopter's `agents` map
  in `opencode.jsonc` or by uncommenting `model:` in an agent's frontmatter,
  using an id that resolves in `reference/models.md`. Binding choices are a
  per-machine decision; a shipped pin would fight the adopter's provider setup.
- Verified by: the harness doctor's Law 8 - fully-unwired routing is a PASS
  state only while a `.docs` record like this one documents the decision.
- Reverting: wire models per seat (adopter `agents` map or `model:` frontmatter
  lines with ids that resolve in `reference/models.md`), or document the new
  wiring state here.