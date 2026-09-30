---
description: Bounded parallel review fan-out, then a lead go/no-go merge decision
agent: orchestrator
subagent: false
---

Gate `$ARGUMENTS` (default: current changes). Dispatch three one-pass reviewers in parallel: correctness, security, and test evidence. Each is read-only, bounded, and returns findings plus one verdict. Merge the reports; if they conflict, dispatch one focused reviewer for the disputed claim. Emit exactly one decision: `GO`, `NO-GO (revise)`, or `NO-GO (blocked)`, with whatever evidence, risk, and next action actually exist — omit any section with no real content (a clean `GO` carries no risk field). Never weaken checks or ship on stale evidence.
