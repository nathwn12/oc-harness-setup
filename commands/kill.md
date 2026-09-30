---
description: Kill a session now — interrupt its active execution in place
agent: orchestrator
subagent: false
---

If `$ARGUMENTS` is empty, ask once for one target and stop. Otherwise run:

`pwsh -NoProfile -File "$HOME/.config/opencode/scripts/interrupt-session.ps1" "$ARGUMENTS"`

Return the script's single result. Never substitute a message, deletion, batch sweep, or guessed session ID for the interrupt.
