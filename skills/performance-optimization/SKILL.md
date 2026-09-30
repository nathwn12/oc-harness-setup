---
name: performance-optimization
description: "Measurement-led performance work for a stated latency/throughput goal, observed regression, Core Web Vitals issue, hot path, or identified resource bottleneck."
---

# Performance Optimization

1. Define the user-visible metric, representative workload, baseline, and target.
2. Measure with the narrowest profiler or trace that can locate the bottleneck. Distinguish CPU, I/O, network, memory, rendering, and database time.
3. Rank causes by measured contribution. Change the largest proven cause with the smallest complexity cost.
4. Repeat the same measurement under the same conditions. Check correctness and a nearby regression path.
5. Stop when the target is met or the next gain is not worth its complexity; report the tradeoff.

For a relevant detailed pass, read only the matching section of `../_shared/references/performance-checklist.md`.

Return before/after numbers, method, variance or caveats, change made, and residual bottleneck. Never claim an improvement without comparable measurements or add caching, concurrency, or dependencies on intuition alone.
