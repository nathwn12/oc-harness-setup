# Skill mechanics

The skill-specific branch of [`writing-for-agents`](SKILL.md): what changes when the document is a skill (frontmatter, the invocation choice, and router skills). Everything else about writing it is the universal reference in `SKILL.md`.

## Invocation

Two choices, trading the two loads:

- A **model-invoked** skill keeps a `description`, so the agent can fire it autonomously, and other skills can reach it. You can still type its name: model-invocation always _includes_ user reach; a description only ever adds agent discovery, never removes the human's. The description is the skill's top-level context pointer, forced to stay loaded at all times: permanent context load in exchange for discoverability. A model-invoked skill whose content is all reference is also one home for shared reference: another skill can invoke it, so reference needed by several skills lives in one place. Mechanics: omit the `opencode/autoinvoke: false` marker, and write a model-facing description carrying the trigger branches (the pointer-writing rules in `SKILL.md` apply in full).
- An **explicit-only** skill is hidden from the model's advertised skill list, but remains registered and loadable by exact ID from a command or deliberate instruction. It removes the always-advertised description cost while preserving explicit reach. Set `metadata: {"opencode/autoinvoke": false}` and keep the description as a short human-facing summary.

Pick model-invocation only when the agent must reach the skill on its own, or another skill must. If it only ever fires by hand, make it explicit-only and pay no context load.

Shared reference that two skills need can live in a plain reference file and be loaded only from the matching branch.

## Splitting by invocation

The invocation cut of splitting (the sequence cut lives in `SKILL.md`): split off a model-invoked skill when you have a distinct leading word that should trigger it on its own (a trigger word you actually use in your prompts), or another skill must reach it. You pay context load for the new always-loaded description, so that independent reach has to be worth it.

## Router skills

When explicit skills multiply, route them through commands or the compact lookup at `~/.config/opencode/reference/intent-routing.md`. Exact-ID loading remains available even when a skill is not advertised.
