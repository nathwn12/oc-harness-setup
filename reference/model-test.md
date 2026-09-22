# Model Test — fixed contender intake (Go only)

How a new OpenCode Go model earns a row in `reference/models.md`. Same bytes in, same
harness around it, every time — so scores are comparable across models and across months.

## 0. Sweep (every recheck, every 3 days)

List the live catalog and diff against the ranked table — **all Go IDs are contenders**:

```powershell
opencode models 2>$null | Select-String 'opencode-go/'
```

**Fresh-online rule (standing):** re-pull the model list, prices, caps, and context
windows live every recheck — Go docs pricing tables + models.dev Go provider catalog.
Never rank off a cached snapshot older than the current recheck; if a rate, cap, or ID
disagrees between sources, the live `opencode models` output wins for IDs and the Go
docs win for prices, and the disagreement is recorded in one line.

Any live ID not in `models.md`, or any ranked ID with a new variant/rung, enters intake below.

## 1. Third-party benchmarks first

Before spending a single token, check (in this order) and record source + date:

1. Artificial Analysis intelligence / coding / agentic scores
2. OpenRouter benchmark + cost-throughput surfaces
3. models.opencode.ai Go catalog (rate, context window, output limit)
4. opencode.ai usage data (token share, peers)

If two independent third-party sources agree the contender is **outside** our ranked caliber
(weaker than MiMo v2.5 on intelligence, or pricier than Qwen3.8-flash per task with no
quality edge), reject on paper — record the rejection in one line, no run. Our own
usage-report tooling med-cost counts as a source: a contender metering 5×+ above the incumbent with
no quality evidence is rejected on paper (the Hy4 lesson, <DATE> — tested at $0.0156
when our own data already said $0.0098/turn). Otherwise, run the fixed test.

## 2. The fixed test — mockup login screen, one shot

Same task, same prompt bytes, same cage. This is the login-screen sibling of our <DATE>
bench (same family as `ranking.json`, new fixed rubric below — old scores carry over as-is
with their source labels, not re-scored).

**Fixed prompt v2** (verbatim each run; v1 retired <DATE> — v1 scores carry over
labeled, never re-scored):

> Build a single self-contained `index.html` login screen to production mockup standard:
> email + password fields with labels, show/hide password toggle (icon + text, `aria-pressed`),
> "Sign in" button with loading/spinner state and `aria-busy`, "Forgot password" link that
> responds inline (no dead links), remember-me checkbox persisted via localStorage,
> inline validation (empty + bad-email + min-length 8) on blur and submit with focus moved
> to the first invalid field, caps-lock warning on the password field, success panel on
> valid submit, visible focus rings throughout, `prefers-reduced-motion` support,
> responsive down to 360px with no horizontal scroll, dark theme with real depth
> (layered surfaces, not one flat card), zero remote refs (no CDNs, no external
> fonts/images). All CSS/JS inline. Short-to-medium length: dense, no filler sections.

**Fixed cage:**

- Fresh temp workspace; project-level agent; global config untouched; main history DB clean
  (or isolated DB copy).
- **Rung protocol (standing — highest reasoning must earn its keep):**
  1. Research the model's known quirks online first: vendor docs (thinking-level map,
     verbosity controls), community reports (overthinking, tool loops, token bloat).
     Record one line per model; social/vendor claims nominate questions, never answers.
  2. Always pair the top rung against one level down on the fixed task.
  3. Keep the highest rung only if it wins clearly (better quality at acceptable cost —
     the Muse xhigh precedent: +3 qual, +73% TPS, −27% wall for +18%). Otherwise drop
     one and live there (the DeepSeek max precedent: 7,337 reasoning tokens, −5 quality,
     3× wall, +68% cost — verbosity that loses value to performance).
  4. No two models expose the same rungs — probe, never assume (`<YOUR_MODEL>` exposes none).
- `steps: 8` ceiling, shell / web / subagents denied, 600 s hard timeout, single run
  (n=1, stated as caveat). Sequential runs only when pairing rungs.

**Fixed measurements** (host-recorded, never estimated):

- `cost` (recorded accounting), `tpsAggregate` (streaming window), wall seconds, turns,
  output tokens, reasoning tokens.

**Fixed rubric v2 — quality /100 (rendered DOM + visual):**

- Objective /60, measured live: email+password+labeled (10) · toggle with icon+text and
  `aria-pressed` (8) · submit with loading state + `aria-busy` (6) · forgot-link responds
  inline, zero dead links (6) · remember-me persisted (4) · validation empty+bad-email+
  min-8 on blur AND submit, focus to first invalid (10) · caps-lock warning (4) ·
  responsive at 360px without horizontal scroll (4) · zero remote refs, self-contained (4) ·
  ARIA hooks ≥15/≥8 (4/2).
- Design /40, visual review 5 criteria × 8: layout · typography · colour & contrast ·
  depth & detail (layered surfaces expected) · demo polish (loading/success motion).

**Fixed prompt v3** (verbatim each run; v2 retired on first v3 firing — v2 scores frozen
as-labeled, never re-scored). Same page, adversarial acceptance, 12 KB budget:

> Build a single self-contained `index.html` login screen to production mockup standard,
> max 12 KB total: email + password fields with labels, show/hide toggle whose state a
> screen-reader user always knows, sign-in flow that always communicates progress,
> "Forgot password" that responds inline (no dead links, no navigation), remember-me
> persisted without ever storing the password, validation that catches empty, bad-email,
> and short passwords on blur and submit with focus moved to the first invalid field,
> caps-lock warning, success confirmation, visible focus throughout, reduced-motion
> support, responsive to 360px with no horizontal scroll, layered dark surfaces.
> Adversarial bars: typing `"><script>alert(1)</script>` as the email must render as
> inert text everywhere it echoes; with JavaScript disabled the form must still submit
> via native validation (`required`, `minlength`, `action`); the entire flow must be
> operable keyboard-only with focus never dropped to `<body>`; Escape closes any open
> pane and returns focus to its trigger. Zero remote refs. All inline. Dense, no filler.

**Fixed rubric v3 — quality /100:**

- Objective /60, measured live: labels + outcomes-known toggle state (8) · progress
  always communicated (6) · inline forgot, zero dead links (6) · remember persisted,
  password never stored (6) · validation + focus-first-invalid (8) · caps warning (4) ·
  XSS echoes inert (8) · no-JS native submit works (6) · keyboard-only complete,
  focus never dropped, Escape returns focus (8).
- Design /40: layout · typography · colour & contrast · restraint under budget ·
  polish. Bloat past 12 KB caps design at 20 regardless of beauty.

## 4. Benchmark iteration loop — Vn until saturation

The benchmark itself versions (v1 → v2 → v3…). Each new version is derived from the
previous round's results, never from imagination:

1. **Analyze compression.** Any rubric bar every runner aces gets promoted to harder
   acceptance or replaced. Bars that separated the field stay.
2. **Add exactly one adversarial axis per version** (XSS escape, no-JS fallback,
   focus discipline, size budget…). One — so a score drop is attributable.
3. **Freeze prior scores as-labeled.** Vn scores never re-score under Vn+1; cross-version
   comparison is rank-order only, never points.
4. **Same test, same length class.** One self-contained login file, short-to-medium.
   A version that needs a bigger artifact is a different benchmark, not Vn+1.
5. **Stop condition (maximum quality reached):** two consecutive versions that change
   neither the rank order nor surface a new failure mode. The benchmark is saturated —
   further versions add noise, not signal. Record the saturation and hold.

## 5. Judges — specialists, design slice only, on demand

No standing persona panel exists; the objective /60 stays deterministic (DOM-measured,
lead-scored). When the top two are within 3 points, the subjective design /40 goes to a
three-judge panel of existing specialists, each scoring blind from the artifact:

- `security-auditor` — escape/XSS discipline, inline-script hygiene, autocomplete +
  persistence privacy.
- `reviewer` — correctness of states, a11y outcomes, focus management, no-dead-link rule.
- `web-performance-auditor` — size budget, render cost, animation discipline,
  reduced-motion honesty.

Majority moves the design score; dissent recorded in one line. Judges never touch the
objective slice and never see each other's scores first.

## 3. Record & re-rank — only our runs move rows (unchanged, applies to every version)

Third-party scores never change the table. Re-ranks happen **only** on fixed-test results,
on the three tracked axes: **TPS** (streaming window) / **cost** (recorded accounting) /
**quality** (fixed /100 rubric).

Decision rule per contender run:
- First, append one JSON row in the `ranking.json` schema
  (`id, model, variant, wallSec, turns, output, input, cacheRead, cost, tpsAggregate,
  objective, design, quality`) to the current bench assets file — every run is kept.
- **Desktop rule (standing):** every scored run's artifact + the current stats JSON are
  copied to `Desktop/bench-<series>-<date>/` for user evaluation — no screenshots, the
  user opens the pages directly. Sync the stats file on every row appended.

- **Takes (or jumps) a row:** beats the incumbent on quality at equal-or-lower cost, or
  matches quality at clearly lower cost. Re-number the table, state the beaten incumbent.
- **Stays out:** loses on quality, or wins quality only at a cost the verdict can't defend
  (the Qwen precedent: 100/100 at $0.014 stays row 6). One rejection line in Sources.
- **Paired-rung upgrade:** if the top rung beats the usable rung on all three axes for
  +<25% cost (the Muse xhigh precedent), the rank holds the top rung, noted in the row.

Then move the `models.md` recheck date +3 days. Never re-score old runs under a new rubric.
