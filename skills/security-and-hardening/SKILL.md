---
name: security-and-hardening
description: "Security-focused implementation or audit for authentication/authorization, secret handling, untrusted-input boundaries, sensitive data, dependencies, or an explicit threat-model request."
---

# Security and Hardening

Start with the changed trust boundary, assets at risk, attacker capability, and required invariant. Do not broaden a routine change into a full security program.

1. Map input, identity, authorization, data flow, storage, and external calls across the scoped boundary.
2. Check fail-closed validation, object-level authorization, injection resistance, safe error disclosure, and secret handling where applicable.
3. Inspect dependency or supply-chain risk only when dependencies changed or the brief requests it.
4. Prefer platform security primitives and centralized policy over bespoke sanitizers or scattered checks.
5. Prove the control with a negative test or concrete exploit attempt, then rerun the normal behavior path.

Read `../_shared/references/security-checklist.md` only for the matching topic; do not load it wholesale. Route credential-bearing files through the permitted privileged worker and report secrets only by path and key name.

Return threat, evidence, severity, smallest remediation, and verification; add residual risk only when it has real content, omit otherwise. Do not commit, rotate credentials, contact services, or expand scope without authorization.
