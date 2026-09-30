---
name: planning-and-task-breakdown
description: "Creates an executable plan when the user asks for planning, task breakdown, sequencing, ownership, or acceptance criteria without requesting implementation."
---

# Planning and Task Breakdown

Convert a known outcome into the smallest ordered plan that another worker can execute without rediscovering intent.

1. State the outcome, in-scope surfaces, exclusions, and acceptance evidence.
2. Identify dependencies and the critical path. Keep independent tasks parallel and dependent tasks ordered.
3. Split by artifact, question, or verifiable phase. Each task gets one owner, a bounded change surface, a done condition, and a narrow proof.
4. Surface only material risks and open decisions. Recommend a path when evidence supports one.
5. Check that no task performs opportunistic cleanup, hidden publication, commits, or unrelated hardening.

Return the plan in chat unless the user names a destination. Do not write state files, create project folders, dispatch workers, or implement the plan.
