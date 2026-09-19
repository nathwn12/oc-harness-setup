---
description: Simplify current changes by cutting unnecessary complexity
agent: coder
---

Simplify `$ARGUMENTS` (default: the current changes) by applying the Ponytail ladder in `AGENTS.md` and the local `code-simplification` skill: the laziest change that actually works.

1. First **review** the target for what can be cut — tags `delete` (dead code, unused flags), `stdlib` (reinvented standard library), `native` (platform features replaced by custom code), `yagni` (speculative flexibility), `shrink` (over-abstraction). Or run `/ponytail-audit --diff` first if the diff is large.
2. Then **apply** the safe cuts: one writer per artifact, smallest diff, no behavior change unless removing the behavior is the point.
3. Preserve the lean safety floor: validation, security, accessibility, reversibility, and explicit user requirements are never cut.
4. Run the check that proves behavior is unchanged (or correctly simpler) and report: what was cut, lines/dependencies removed, what you ran, and what it proved.

Mark anything you deliberately deferred with `lean: <ceiling>; revisit when <trigger>`. Route correctness, security, and performance findings to `/review` — this command cuts complexity only.
