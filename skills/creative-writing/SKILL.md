---
name: creative-writing
description: "Three modes for turning raw material into finished prose - `writing-fragments` mines raw fragments, `writing-beats` assembles them into a journey of beats, and `writing-shape` shapes them into an article paragraph by paragraph. Use when drafting, mining, or structuring an article, essay, or piece of writing. Explicit-only: invoke deliberately for a writing session."
metadata:
  "opencode/autoinvoke": false
---

# Creative Writing

## Overview

Three modes on one arc: **explore** widens the space of what could be written; **exploit** commits to a path and mines the raw material to fill it. Pick the mode by where the material stands.

| Mode | Phase | Job |
|---|---|---|
| `writing-fragments` | explore | Mine raw fragments. No structure yet. |
| `writing-beats` | exploit | Assemble fragments into a journey of beats, grounding each term before a beat leans on it. |
| `writing-shape` | exploit | Shape raw material into an article, paragraph by paragraph. |

All three modes share the grounding rule and the writing rhythm below.

## Grounding (shared)

Every concept must be grounded before a beat or block leans on it: the reader either walked in knowing it or met it earlier. The unit is the concept, not the word for it - a move can lean on an ungrounded idea even with no jargon in sight. Where a concept has a name (a term), grounding it means landing the idea and the term together.

A concept is grounded one of two ways:
- **Prerequisite** - grounded before the first beat or block. The audience brings it. Fixed at the start.
- **Introduced** - a beat or block establishes it, and from then on it is grounded for everything later.

The lever is what you make a prerequisite versus what you ground inside the piece. Demand too much up front and you shut out readers who do not have it; ground too much inside and the early writing drowns in definitions. Settle this with the user when you establish prerequisites, and revisit it whenever a tempting move needs a concept nothing has grounded yet: either add a grounding beat before it, or promote the concept to a prerequisite.

## Writing rhythm (shared)

- Re-read the file from disk before every write. The user may have edited, reordered, or deleted between turns; preserve their changes absolutely.
- Append as you go; do not batch. Never write ahead of the agreed beat or block.
- Never overwrite blindly. When the user asks to rewrite something, edit that piece in place and leave the rest alone.
- Treat "cut that", "rewrite that sharper", "merge those two" as first-class instructions.

## Mode - writing-fragments (explore)

Widen the space of what could be written without committing to structure. Run a grilling session that produces fragments, interviewing the user about whatever they want to write. Imposing phases, outlines, or article structure is out of scope here.

- Capture fragments from the very first thing the user says, including the initial prompt.
- If the user did not pass a path, ask once where to save the file, then remember it.
- Append fragments to a single markdown file. On first write, put one H1 with a working title at the top and nothing else - no metadata, no TOC, no date.
- Separate fragments with a horizontal rule (`---`). No headings in the body, no tags, no order beyond the order they were added.
- Append silently. Do not ask permission for each fragment; mention in passing what you added.

A fragment is any piece of text that might survive into the final article. It must be readable by the author, but it need not define its terms or stand alone. Fragments are deliberately heterogeneous: a sharp sentence with nowhere to go yet, a claim with a one-line justification, a vignette, a half-thought, a quote, a list that hangs together by feel, a complaint or a punchline.

The most valuable fragment is a **leading word** - a compact metaphor or coinage the whole piece can hang on, the way *tracer bullets* or *fog of war* names a whole pattern. Name the right one in explore and it shapes the structure, transitions, and title later. When the conversation circles a recurring idea, push to coin a word for it.

The novelist's diary is the model: years of unstructured noticings, mined later. Fragments are noticings.

## Mode - writing-beats (exploit)

Input is a markdown file of raw material: the exploring is done, the pile is fixed. Commit to a path through it and mine the pile to fill each beat.

1. **Establish the prerequisites.** Settle with the user what the audience already knows walking in: the concepts grounded from the start. Everything else must be grounded by a beat before a later beat can use it.
2. **Offer 2-3 candidate starting beats**, each a different entry point drawn from the pile. Each may lean only on grounded concepts; note what new concepts it grounds. Show them before writing, and preview what each pick unlocks. The user picks one.
3. **Write only that beat** to the article file. A beat may be one sentence or several paragraphs, whatever it naturally is. Stop there.
4. **Re-read the file from disk**, then offer 2-3 candidate next beats reachable from the current grounded set, noting what each grounds.
5. **Loop** steps 3-4 until the article reaches a natural end.

A beat is one move in the journey: set a scene, land a point, ask a question, drop an aside, twist the angle. Then stop, leaving the reader where the next beat can pivot. A beat is sized by what it needs - a single sentence, a short paragraph, or several paragraphs for a self-contained vignette or argument. If a "beat" needs five paragraphs and three subheadings, it is two beats glued together; split it.

Pull material from the pile to populate each beat: paraphrase, split, recombine, quote. The pile is a quarry. The article ends when the journey is complete, not when the pile is empty; leftover fragments are expected.

## Mode - writing-shape (exploit)

Input is a markdown file of raw material - a tidy list of fragments, a wall of unstructured prose, a transcript; the format does not matter. Read it end-to-end before doing anything else. The raw material is read-only to this mode. This is exploit: the exploring is done, the pile is fixed. Commit to a structure and mine the pile to fill it.

1. **Read the pile in full.** Form a sense of what is in it.
2. **Establish the prerequisites** (see Grounding).
3. **Draft 2-3 candidate openings**, each implying a different thesis or angle. Show all of them; force the user to pick one or compose a hybrid. The chosen opening defines what the rest must do.
4. **Grow paragraph by paragraph.** Ask "given this opening, what does the reader need to hear next?" Pull material from the pile to answer. Each block may lean only on grounded concepts and grounds new ones as it lands.
5. **Argue the form** before writing it: a paragraph, a list, a table, a callout, a quote, a code block. Each format choice should be deliberate and defensible.
6. **Append each agreed block immediately**, then loop step 4 until the user decides the article is done.

This is a grilling session inverted. In ideation the question was "what are you actually noticing?"; here it is "what is this article actually arguing, and in what order does the reader need to hear it?" Push back and refuse to let weak transitions slide. Useful moves:
- "What does this paragraph do for the reader that the previous one didn't?"
- "If I cut this, what breaks?"
- "Is this prose, or should it be a list? Why prose?"
- "This sentence is doing two jobs: split it or pick one."
- "The opening promised X. We've drifted to Y. Either re-thread it or change the opening."

Treat the pile as a quarry, not a script: pull a fragment, rework it to fit the surrounding paragraph, paraphrase, split, or merge. The article must read as one voice. If the pile lacks something the article needs, name the gap explicitly - ask for an example now or cut the section.

Format tradeoffs to weigh out loud, not silently:
- **Prose vs. list** - prose carries argument; lists carry parallel items. Non-parallel items read better as prose.
- **Inline vs. callout** - callouts (`> [!TIP]`, `> [!NOTE]`) only when an aside would genuinely derail the main argument.
- **Table vs. repeated structure** - a table when the same shape repeats three or more times with the same fields.
- **Quote vs. paraphrase** - quote when the original wording is the point; paraphrase when only the idea matters.
- **Code block vs. inline code** - block for multi-line, runnable, or illustrative; inline for a single token.

Out of scope: mining for new fragments that are not in the pile, editing the raw material file, and publishing or platform-specific formatting.
