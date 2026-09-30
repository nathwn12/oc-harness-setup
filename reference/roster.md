# Agent roster

| Seat | Mode | Purpose |
|---|---|---|
| `orchestrator` | primary | User-facing control plane: scope, dispatch, live event reports, fan-in, recovery, final verdict. |
| `plan` | primary | Planning only; may use one read-only `explore` worker. |
| `build` | subagent | Project implementation and proving checks. |
| `explore` | subagent | Read-only reconnaissance and targeting evidence. |
| `general` | subagent | Bounded synthesis, operations, documentation, and non-product artifacts. |
| `reviewer` | subagent | Independent read-only verification with a pass/revise/blocked verdict. |
| `vault` | subagent | Global harness and credential-bearing paths, values by pointer only. |

Seats are roles, not singletons. The orchestrator may run multiple instances when their seams are independent. Workers never delegate or widen their briefs.

Reviewer lenses are named in the dispatch brief: `correctness`, `security`, `test`, or `performance`. Apply only lenses relevant to the risk; `/ship` deliberately runs correctness, security, and test in parallel.
