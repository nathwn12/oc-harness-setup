---
name: frontend-ui-engineering
description: "Implements or reviews user-facing UI components, pages, layouts, interaction states, responsive behavior, and accessibility against an existing product/design system."
---

# Frontend UI Engineering

1. Inspect the existing design system, component patterns, tokens, routing, state, and tests before adding UI.
2. Define the interaction states: loading, empty, success, validation, error, disabled, and recovery as applicable.
3. Use semantic HTML, keyboard-complete interaction, visible focus, correct labels, and sufficient contrast. Reuse existing primitives and tokens.
4. Keep state local to the smallest owner and separate server, URL, form, and presentation state.
5. Verify at representative narrow and wide viewports, with keyboard navigation and the repository's UI checks. Use real-browser tooling when runtime behavior or visual output matters.

Read `../_shared/references/accessibility-checklist.md` only when the scoped change needs the detailed checklist.

Return changed surfaces, states verified, accessibility evidence, and responsive evidence; add remaining visual risk only when it has real content, omit otherwise. Do not redesign adjacent UI or create a new component system without a request.
