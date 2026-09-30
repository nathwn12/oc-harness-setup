---
name: spec-driven-development
description: "Explicit-only specification workflow for /spec or a direct request to define a feature/change before implementation."
metadata:
  "opencode/autoinvoke": false
---

# Spec-Driven Development

Produce a decision-ready specification, then stop. Planning, implementation, commits, and publication are separate actions.

## Spec

- **Outcome:** observable behavior and who benefits.
- **Scope:** included surfaces and explicit non-goals.
- **Current evidence:** relevant existing behavior, constraints, and interfaces.
- **Requirements:** uniquely identified, testable statements.
- **Failure behavior:** validation, error states, recovery, and reversibility.
- **Acceptance evidence:** one runnable or inspectable proof per requirement.
- **Risks and decisions:** unresolved items that materially affect the result.

Use `grilling` only when the user deliberately requests it. Otherwise ask the smallest blocking question or state a reversible assumption.

Keep the spec in chat by default. Write it only when the user or repository names a destination. Never create `tasks/`, session files, commits, or implementation work as a side effect.

Before returning, check that every requirement maps to evidence, non-goals prevent obvious scope expansion, and no acceptance criterion depends on subjective language such as “good,” “fast,” or “clean” without a measurable bound.
