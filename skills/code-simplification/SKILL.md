---
name: code-simplification
description: "Simplifies an explicitly named implementation or diff by removing dead, duplicated, speculative, or over-abstracted code while preserving behavior."
---

# Code Simplification

1. State the behavior that must remain fixed and the check that proves it.
2. Find complexity with no current requirement: dead paths, duplicate logic, unnecessary indirection, speculative configurability, custom code replaced by standard/native behavior, or abstractions used once without leverage.
3. Rank cuts by confidence and value. Apply only safe in-scope cuts; do not mix correctness, security, or performance work into the pass.
4. Prefer deletion and direct naming over clever compression. Readability and debuggability matter more than raw line count.
5. Run the original proving check and report deleted code or dependencies, behavior evidence, and anything deliberately retained.

Do not commit, create debt markers, or use simplification as permission for a redesign.
