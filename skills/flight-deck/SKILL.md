---
name: flight-deck
description: "Configures the global oc-flight-deck sidebar JSONC: rows, ordering, visibility, glyphs, and caution thresholds."
---

# Flight Deck Configuration

The plugin reads one global file: `$XDG_CONFIG_HOME/opencode/flight-deck.jsonc` when set, otherwise `~/.config/opencode/flight-deck.jsonc`. Project-local copies are ignored.

1. Route the edit through `vault` because it changes the global harness.
2. Locate the installed `oc-flight-deck` package, then read its shipped `flight-deck.schema.json` and `flight-deck.example.jsonc`. Search the active OpenCode/plugin cache if the package path is not known; never guess keys from memory.
3. If no config exists, copy the shipped example. Otherwise preserve comments and edit only requested differences from defaults.
4. Validate JSONC against the shipped schema and reload OpenCode to verify the panel.

`sidebar.rows` controls ordered visible fields; `caution` controls stalled-work thresholds and exemptions. Prefer removing low-value rows to adding noise. Do not invent styling keys or duplicate the same setting in both plugin options and the global file.

Return the config path, keys changed, schema source, validation result, and reload requirement.
