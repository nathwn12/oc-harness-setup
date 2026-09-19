---
description: Audit the repository or the current diff for over-engineering
agent: reviewer
subagent: true
---

Audit a scope for over-engineering, using the Ponytail ladder. Default scope is the entire repository; pass `--diff` in `$ARGUMENTS` to audit only the current changes. One-shot report; do not apply fixes. Rank findings by largest safe simplification first: what to delete, simplify, or replace with a stdlib/native equivalent. Report one line per finding as `<tag> <what to cut>. <replacement>. [path]` — or `<path>:L<line>: <tag> <what to cut>. <replacement>.` in `--diff` scope — using only `delete`, `stdlib`, `native`, `yagni`, or `shrink` tags. End with `net: -<N> lines, -<M> dependencies possible.` If nothing can be cut, say `Lean already. Ship.` Route correctness, security, and performance findings to `/review`; to apply cuts, use `/code-simplify`.
