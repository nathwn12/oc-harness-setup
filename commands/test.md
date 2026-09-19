---
description: Run tests and report evidence — identify the narrowest missing coverage
agent: test-engineer
subagent: true
---

For `$ARGUMENTS` (default: the current changes):

1. Run the existing test/check suite first and report results as evidence — exact commands and outcomes.
2. If behavior lacks coverage, describe the narrowest tests that would prove it, following the local `test-driven-development` skill (red-green-refactor). Do not add them in this read-only audit; hand the test task to `/build`.
3. Do not edit product code or tests to make the report pass. Report genuine defects separately with file:line evidence.
4. Never weaken assertions, skip flaky tests silently, or lower coverage to get green.

End with: what passed, what failed, what is untested (with the risk that leaves), and the smallest next action.
