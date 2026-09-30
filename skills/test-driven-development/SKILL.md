---
name: test-driven-development
description: "Uses RED-GREEN-REFACTOR for behavior changes and reproducible bug fixes when a testable seam exists."
---

# Test-Driven Development

Use this inside an implementation brief, not as a reason to widen it.

1. **RED:** Write the smallest test that expresses the requested behavior or reproduces the reported bug. Run it and confirm it fails for the expected reason; a syntax or setup failure is not red.
2. **GREEN:** Make the smallest production change that passes the new test. Run the focused test, then the nearest relevant suite.
3. **REFACTOR:** Improve names or structure only where the passing change made complexity visible. Keep behavior fixed and rerun the tests.

Prefer public behavior over implementation details. Cover the meaningful boundary or failure case, not every line. Reuse the repository's framework and conventions; do not introduce a new test stack without explicit approval.

If no practical automated seam exists, state why and use the narrowest deterministic verification available. Never weaken assertions, skip a failure, or rewrite a test merely to make the implementation pass.

Return tests added or changed and exact commands and outcomes; add remaining untested risk only when it has real content, omit otherwise. Delegation, commits, browser automation, and publication remain outside this skill.
