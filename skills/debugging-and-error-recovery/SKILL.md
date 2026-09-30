---
name: debugging-and-error-recovery
description: "Systematic root-cause debugging for reproducible errors, failing tests/builds, regressions, and behavior that contradicts expectations."
---

# Debugging and Error Recovery

1. Capture the exact symptom, environment, last known good behavior, and smallest reproduction. Preserve logs and failing output.
2. Reproduce before changing code. If reproduction is intermittent, quantify frequency and isolate variables.
3. Trace from the failing boundary toward the first incorrect state. Form one falsifiable hypothesis at a time and run the cheapest discriminating check.
4. Reduce the reproducer until unrelated layers disappear. Separate root cause from downstream noise.
5. Apply the smallest root-cause fix. Avoid fallback branches, retries, or broad refactors unless evidence shows they are required.
6. Verify the original reproduction, the nearest regression suite, and one relevant edge case. Confirm temporary diagnostics are removed.

If blocked, return the exact missing signal, what was ruled out, and the smallest next experiment. Do not invent history tools, perform opportunistic cleanup, commit, publish, or widen the brief.
