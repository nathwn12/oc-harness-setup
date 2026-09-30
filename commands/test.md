---
description: Run tests and report evidence — identify the narrowest missing coverage
agent: reviewer
subagent: true
---

Audit tests for `$ARGUMENTS` (default: current changes). Run the existing narrow suite first, report exact commands and outcomes, identify the smallest missing coverage, and separate genuine defects from test gaps. Do not edit, weaken assertions, hide flakes, or lower coverage. Return what passed, failed, remains untested, the resulting risk, and the smallest next action.
