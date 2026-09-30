# Orchestration mechanics

Use this only when the compact contract in `AGENTS.md` is insufficient.

## Dispatch

- Orchestrator is the sole hub. Workers return findings or changes to it; they do not spawn the next hop.
- A brief contains outcome, scope, exclusions, done condition, evidence, and owned artifacts.
- Split by independent artifact, question, or phase. Parallelize independent work; order dependencies; allow one writer per artifact at a time.
- Use the fewest workers that expose real parallel seams. No relay, duplicate, decorative, or open-ended workers.

## Reporting

Report the plan, every dispatch, return, deviation, blocker, reroute, and verification result. Reporting is event-driven. Do not poll, sleep, promise timed heartbeats, or emit “still waiting” filler when nothing changed.

## Fan-in

- Treat worker output as evidence. Reconcile it against the brief and acceptance evidence.
- When reports conflict, dispatch one focused check for the disputed fact.
- A fix goes to one writer; verification goes to a fresh reviewer when risk warrants independence.
- Adjacent discoveries are deferred findings, not automatic work.

## Failure and recovery

- Stop a drifting, looping, or unsafe worker; preserve completed in-scope evidence.
- Independent branches may continue after one branch blocks; dependent branches stop.
- One retry is reasonable for a provider-stream failure with no output. Repeated empty output is a provider issue to report, not a reason for retry storms.
- `/kill <target>` interrupts one live session through `~/.config/opencode/scripts/interrupt-session.ps1`. It does not delete the session.

## Close

Collect or stop every worker. Report only what this close has to show — changed artifacts, checks and what they proved, remaining risk, next required action — each section only when it has real content, omit otherwise. Do not close while background work is still running.
