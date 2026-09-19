---
name: grilling
description: Interview the user to a shared understanding before building. Use when a request, plan, or design is ambiguous, expensive, or has unresolved decisions; use before spec-driven-development when a wrong build would be costly. Triggered by "grill me" and by any decision tree with open branches.
---

# Grilling

Interview the user relentlessly until you reach a shared understanding. Map the topic as a **design tree**: every decision branches into the decisions that hang off it.

Reach for this before `spec-driven-development` when a wrong build would be expensive. The spec records settled decisions; grilling settles them.

## Rounds and the frontier

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled — the questions you can ask _now_ without guessing at answers you have not heard. Ask the whole frontier in one round, numbered, each with your recommended answer. Then wait for the user's answers before the next round.

Format a round like so:

```
❓ **Q1** - **<question title>**: <question body, including the choices>

➡️ <your recommended answer>

---

❓ **Q2** - **<question title>**: <question body>

➡️ <your recommended answer>
```

Each round reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier and ask the next round. A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

## Facts are yours; decisions are theirs

Find facts yourself — never ask the user for something the environment can answer. Dispatch `explore` for filesystem, code, or docs facts; don't block on it. A running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the report; ask the rest of the frontier now. Put every decision to the user and wait.

## Done

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on it until the user confirms you have reached a shared understanding; then hand the settled decisions to `spec-driven-development` or straight to the build.
