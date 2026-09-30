---
name: pilot-report
description: "Explicit-only analysis of real OpenCode history for a direct model/agent performance, speed, cost, throughput, or failure-rate comparison."
metadata:
  "opencode/autoinvoke": false
---

# Pilot Report

Use `pirep` to answer the named performance question from recorded OpenCode history.

1. Define the compared models/agents, time window, workload class, and metric before querying.
2. Use bounded reads and disclose sample size, missing fields, retries, and obvious workload imbalance.
3. Compare like with like. Separate observed measurements from causal claims and avoid ranking tiny samples.
4. Report median and tail latency where available, token/cost totals, success/failure rate, and uncertainty relevant to the question.
5. Recommend a routing change only when evidence supports it; do not edit model pins or routing automatically.

This skill is never triggered merely because the orchestrator dispatched a worker or discussed routing.
