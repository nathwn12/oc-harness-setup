# Harness references

`AGENTS.md` is the always-loaded contract. Everything here is on-demand support; load only the file named by a matching rule or workflow.

- `roster.md` — active seats and authority.
- `swarm.md` — dispatch, reporting, fan-in, recovery, and close.
- `lifecycle.md` — action boundaries and authorization.
- `session-scope.md` — avoid collisions with other live sessions.
- `session-state.md` — optional YAML checkpoint and handoff format.
- `auto-mandate.md` — exact `--auto` behavior.
- `clean-mandate.md` — exact `--clean` housekeeper behavior.
- `editor-parity.md` — use only when dependency/config changes affect the editor.
- `gc-scripts.md` — deterministic Git wrapper map.
- `model-keeper.md`, `models.md`, `model-test.md` - model evidence; seat wiring lives in the adopter's `agents` map (or agent frontmatter) and is not shipped.
- `oc-source-map.md` — local OpenCode source map.
- `owner-pin.md` - adopter-owned template: volatile owner countdown and next item (the installer preserves an existing file).

Current control plane: the adopter's default primary seat and any planning-only primary are defined in the `agents` map; all substantive work runs through background seats.
