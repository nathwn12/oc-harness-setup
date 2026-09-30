---
name: test-flight
description: "Verifies an npm package from its packed artifact when exports, files, peer dependencies, install behavior, or release readiness must match what consumers receive."
---

# Test Flight

1. Identify the package manager, workspace root, package, supported runtimes, and consumer contract.
2. Run the repository's build and tests, then create or inspect the packed artifact with the native dry-run/pack command.
3. Verify included files, `exports`, types, entry points, peer/runtime dependencies, licenses, and absence of secrets or local-only paths.
4. Install the artifact into a temporary clean consumer and exercise the smallest real import/usage path under each required module mode or runtime.
5. Fix only authorized package defects, repack, and rerun until clean; then report. Publishing and tagging are separate explicit actions.

Return artifact identity, packed contents summary, clean-install commands, consumer results, and remaining compatibility risk.
