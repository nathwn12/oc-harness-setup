---
name: observability-and-instrumentation
description: "Designs or audits logs, metrics, traces, and alerts when the user explicitly requests telemetry/operability work or a diagnosed gap blocks production evidence."
---

# Observability and Instrumentation

Start from the operational question that must be answerable, not from a desire to add more telemetry.

1. Name the event or failure, consumer, decision, and acceptable detection delay.
2. Choose the smallest signal: structured log for discrete context, metric for aggregation/trends, trace for causal latency, alert for actionable thresholds.
3. Use stable names and low-cardinality dimensions. Preserve correlation IDs across boundaries.
4. Exclude secrets and sensitive payloads; define retention and sampling where relevant.
5. Exercise the path and prove the signal appears with the expected fields and failure semantics.

Read only the matching section of `../_shared/references/observability-checklist.md` when deeper guidance is needed.

Return the operational question, signal added or inspected, verification query, noise/cardinality risk, and remaining blind spot. Do not add dashboards, alerts, or publication steps outside the brief.
