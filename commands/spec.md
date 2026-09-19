---
description: Turn an idea or request into a sharp, buildable spec
agent: plan
subagent: true
---

Synthesize `$ARGUMENTS` into a spec from what is known and flag the rest. Follow the local `spec-driven-development` skill. Produce:

- **Outcome:** what "done" means, observable.
- **In scope / out of scope:** explicit non-goals.
- **Constraints:** safety, validation, security, accessibility, platform limits — the things that must never be leaned away.
- **Acceptance evidence:** how each part will be proven (the check that runs).
- **Risks and open decisions:** what would change the build if answered differently.

If the request is ambiguous enough that a wrong build would be expensive, don't guess — run the `grilling` skill to settle the open decisions first, then return to the spec. When the user wants this published, write the approved spec to the requested project artifact; otherwise report it only. Implement nothing.
