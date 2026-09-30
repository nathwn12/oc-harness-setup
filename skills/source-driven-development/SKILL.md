---
name: source-driven-development
description: "Verifies implementation choices from primary sources when an API/version may have changed, official documentation is requested, or a reusable public pattern needs authoritative support."
---

# Source-Driven Development

Use primary sources only: official documentation, specifications, source repositories, release notes, or research papers.

1. Pin the relevant product/library version and the decision that needs verification.
2. Find the narrow authoritative section. Prefer current versioned docs over blogs and snippets.
3. Check deprecations, defaults, platform constraints, and migration notes that could invalidate the approach.
4. Translate the source into the smallest repository-compatible implementation. Cite the exact page near the decision it supports.
5. Verify behavior locally; documentation establishes the contract, not that this code satisfies it.

Separate sourced fact from inference. If sources conflict, name the versions and choose the one matching the project. Do not research every ordinary language or standard-library choice, and do not turn citations into a side quest.
