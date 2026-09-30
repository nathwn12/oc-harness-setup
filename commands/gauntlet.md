---
description: Closed-loop challenge engine - drive $ARGUMENTS to a defined green (challenge, revise, re-challenge)
agent: orchestrator
subagent: false
---

Run the explicit `gauntlet` workflow against `$ARGUMENTS` (default: current changes). Pre-register acceptance evidence, dispatch bounded challenge and repair rounds, keep challengers read-only and one writer per artifact, then report the terminal verdict and evidence. Never move the acceptance bar mid-loop.
