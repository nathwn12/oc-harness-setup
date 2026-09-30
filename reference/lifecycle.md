# Lifecycle boundaries

Before a consequential action, identify target, owner, blast radius, reversibility, dependencies, and proof.

- **Read-only:** inspect and report freely inside scope.
- **Bounded reversible:** ordinary requested edits and local checks may proceed.
- **Consequential external:** pushes, messages, remote mutations, installs, or shared-state changes require the request to include them.
- **Destructive or irreversible:** deletion, force, history rewrite, production mutation, and credential rotation require explicit authorization plus a recovery path.
- **Secrets and identity:** work by pointer; never render values.

One authorization covers the bounded action described. A material target, scope, blast-radius, or reversibility change must be surfaced before proceeding.

On failure, stop at the boundary, preserve evidence and rollback state, then recover inside scope or report the exact blocker. Never turn a failed check into permission for cleanup, rewrites, or a weaker check.

Use a script when the operation is repetitive, must keep secrets out of model context, or needs deterministic reuse. Otherwise prefer the direct native tool.
