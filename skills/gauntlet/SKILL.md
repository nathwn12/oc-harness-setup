---
name: gauntlet
description: "Explicit-only bounded challenge-and-repair loop for /gauntlet or a direct 'gauntlet this' request."
metadata:
  "opencode/autoinvoke": false
---

# Gauntlet

Use only when deliberately invoked. The orchestrator owns dispatch and reporting.

1. Freeze the artifact, constraints, acceptance evidence, round ceiling, and revert pointer before the first challenge. Changing the bar restarts the loop.
2. Dispatch one or more independent read-only reviewers with non-overlapping lenses. Findings need executed evidence or an `UNVERIFIED` label.
3. Merge duplicate findings and reject anything outside the frozen scope.
4. Dispatch one writer with only the accepted findings. No finding means no edit.
5. Rerun the original acceptance evidence and a fresh review. Track opened, closed, and regressed findings.
6. Stop on green, a hard blocker, or the round ceiling. At the ceiling, report options and recommend one; do not continue silently.

Keep independent challenges parallel, repair dependent on findings, and one writer per artifact. In verdict-only mode, edit nothing.

Return the terminal state, rounds used, findings opened/closed/regressed, and exact acceptance results; add remaining risk and the revert pointer only when they have real content, omit otherwise.
