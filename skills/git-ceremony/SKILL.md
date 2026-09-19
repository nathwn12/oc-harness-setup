---
name: git-ceremony
description: "The fixed git ritual for our repos — pull, branch, commit, PR, merge, tags, versioning, releases, and isolated worktrees. Use for any git work in a repository we own: creating or naming a branch, writing a commit message or PR body, merging, tagging, bumping a version, updating a release, or setting up an isolated workspace. A repo's own documented convention takes precedence when one exists."
---

# Git Ceremony

One fixed git ritual for every repo we own. Short, standard, ours.
**The repo's own rules win. Ours is the fallback.**

## 0. Precedence — read the repo before you touch it

Before branching, check whether the target repo already dictates how it wants work done.
If it does, that is the ceremony for that repo.

Look for: `CONTRIBUTING*`, `.github/` (PR template, workflows, CODEOWNERS), `.gitlab/`,
commit-lint / husky configs, branch protection, a versioning or release process, sign-off
or DCO requirements.

- Repo has rules → follow them exactly.
- Repo is silent → follow this document.

Ours never overrides a repo's documented convention.

## 1. Pull — start from truth

```
git switch <default-branch>     # main, master, trunk — whichever the repo uses
git pull --ff-only
```

- Detect the default branch from the repo (§0). Never assume `main`.
- Fast-forward only. If it fails, stop — do not manufacture a merge on the default branch.
- Never branch from a stale default branch.

## 2. Branch — create and name

One branch per unit of work. Never work on main. Never reuse a merged branch.

**Format:** `<type>/<slug>`

| type | for |
|---|---|
| `feat` | new capability |
| `fix` | broken behavior |
| `chore` | tooling, deps, config |
| `docs` | documentation only |
| `refactor` | no behavior change |
| `test` | tests only |
| `perf` | speed/size |
| `hotfix` | urgent production fix |
| `wt` | isolated worktree work (§10) |

- `slug`: kebab-case, 2–5 words, describes the change — not the author, not the date.
- Issue suffix only when the repo tracks issues: `fix/login-timeout-4821`.
- Examples: `feat/token-refresh`, `docs/git-ceremony`, `hotfix/null-cart`.

## 3. Commit — message format

**Subject:** `type: imperative summary`, ≤ 72 chars, no trailing period. An optional `(scope)` may follow the type — `fix(api): cap retry backoff`.

```
fix: cap retry backoff at 30s
```

**Body:** only when the reason isn't obvious. Up to three plain bullets — no padding,
no "this commit…", no emoji unless the repo uses them.

```
fix: cap retry backoff at 30s

- unbounded backoff stalled the queue ~9 min
- 30s ceiling keeps retries under the request timeout
```

- One logical change per commit. If the subject needs "and", split it.
- No WIP commits on a branch headed for review — squash first.
- Issue refs (`#123`, `ABC-123`) go in the body, never the subject.
- No AI-attribution or sign-off trailers unless the repo requires them.
- A version bump is its own commit — never buried in a feature commit (§8).

**Review the staged diff before every commit:** `git diff --staged`. It is the last gate
against a secret, a stray artifact, or a debug print.

**Line endings.** Never commit a whole-file line-ending change — it buries the real diff.
On our repos, keep a `.gitattributes` with `* text=auto eol=lf`. On a repo we don't own,
if a change shows whole-file churn, stop and fix the checkout config instead of committing
the noise.

## 4. Push and PR

Open the PR against the repo's default branch. Title = the commit subject.

**PR body — exactly this, nothing more:**

```
What:  <one line>
Why:   <one line, omit if obvious>
Check: <the single command that proves it, or "n/a">
Risk:  <one line, or "low">
```

- Draft PR while in progress; ready only when the check passes.
- Small diffs. If it's large, split it.
- Screenshots only for visual changes.

## 5. Comments and review — format

- One point per comment. Short, direct. No greetings, no praise padding.
- Prefix intent when useful: `nit:` · `q:` · `blocker:` · `suggest:`.
- Reply once — resolve or answer. Take real disagreements offline.
- Review at the same standard: tight, specific, no essay.

## 6. Merge

- **main stays green.** A PR merges only after its check passes — never merge red.
- Default to **squash merge** — one commit per PR, linear history. Honor the repo otherwise.
- **Conflicts:** if main moved, rebase your branch on it and resolve there — never on main.
  Never leave conflict markers, and never resolve by discarding the other side wholesale.
  Re-run the check after resolving.
- Delete the branch after merge, local and remote. `git fetch --prune` when stale refs pile up.
- Force-push only your own PR branch, and only with `--force-with-lease`. Plain `--force` is
  reserved for the single `latest` tag (§9).
- **Never** force-push main or any shared branch.

## 7. Tags — default OFF

> Off unless proven necessary.

- Do not create tags as part of normal work. Not per commit, not per PR.
- Turn tags on only when the repo requires them (publish/deploy tooling), or you ask.
- The single exception is the moving release pointer in §9 — that is a pointer, not a version tag.

## 8. Versioning — strict

**Format: detect, never invent.**

1. The repo declares a versioning format → use it exactly.
2. The repo declares nothing → our default: `MAJOR.MINOR.PATCH`.

Shapes we follow as-is: `0.0.0`, `0.0.0.0`, `0.0.0-beta.1`, CalVer `YYYY.MM.DD`,
a bare build number — whatever the repo uses.

**One source of truth.** The version lives in exactly one place — the manifest its
ecosystem reads (`package.json`, `pyproject.toml`, `Cargo.toml`, a `VERSION` file).
Everything else derives from it — the release body in §9 only *renders* it. Never hardcode the number in two places.

**Bump table (default 3-part):**

| Change | Bump |
|---|---|
| Breaking API or behavior change | MAJOR |
| New capability, backward compatible | MINOR |
| Bug fix, no new surface | PATCH |

- MAJOR resets MINOR and PATCH to 0. MINOR resets PATCH to 0.
- At `0.y.z` the project is unstable: a `y` bump may include breaking changes. State the
  break so it isn't a surprise.
- Four-part `MAJOR.MINOR.PATCH.BUILD`: the first three follow the table; `BUILD` increments
  per build and carries no API meaning. It never absorbs a breaking change.

**No bump for:** docs, tests, CI, formatting, or refactors that don't change shipped behavior.

**The bump is its own commit** — `chore(release): <old> -> <new>` — never buried inside a
feature commit.

**Every bump is justified — an unjustified bump is invalid.** The reason is one line, and it
appears twice: in the bump commit and in the release body.

```
chore(release): 1.4.2 -> 1.5.0

- minor: adds token refresh endpoint (backward compatible)
```

```
bump 1.4.2 -> 1.5.0 · minor · new: token refresh endpoint
```

The justification states *what kind of change* forced *which digit*. A `1.4.2 -> 1.4.3` with no
line explaining the fix is not allowed.

**Never:** reuse a version · bump downward · bump without justification · keep two sources of
truth · bury a bump inside an unrelated feature commit.

## 9. Releases — exactly one, forever

A repo has **at most one release entry, permanently**. Never a growing list. Each release is
the same entry, rewritten to describe the project as it stands now.

**Mechanism — one moving tag, one release:**

```
git tag -f latest <head-sha>          # move the single pointer
git push --force origin latest        # deliberate: the tag is a pointer, not a version
```

Then edit the one release object to point at `latest` and rewrite its body.

**Body format:**

```
Version: <rendered from the manifest — never hand-edited>
Now:     <what the project is right now, 1–3 bullets>
Changed: <bump + reason since the last update, 1–3 bullets>
Use:     <one line to install/run>
```

- One release entry. Ever. Never create a second.
- Never accumulate per-version tags or releases.
- If the repo has its own release process → **theirs wins**; do not collapse or delete it.
- Some repos forbid force-moving tags → repo rule wins; fall back to their process.

**How this squares with strict versioning:** the release entry is a current-state snapshot, not
a changelog. Version *history* lives in the bump commits — each justified, each permanent. The
entry only reports the version the project is at now, and overwrites cleanly every time.
Nothing is lost, because the commits are the record.

## 10. Worktrees — isolate when the work earns it

Multiple working trees from one repo, each on its own branch, sharing one `.git`. Use one when
the main checkout must stay clean, or when two things are in flight at once.

**Use when:** risky or large change · two or more features in flight · isolated review or merge ·
multi-branch test runs.

**Don't use when:** single-branch linear work (pure ceremony) · you just need to park uncommitted
changes (`git stash` is the smaller tool) · the same file would be open in two places (a conflict
factory, not parallelism).

### 10.1 Detect first — never create what already exists

```
git rev-parse --git-dir
git rev-parse --git-common-dir
```

Different paths means you are already in a linked worktree — stop, do not nest another.

**Submodule guard:** that difference is also true inside a submodule. Confirm with
`git rev-parse --show-superproject-working-tree` — a path back means submodule, treat it as a
normal repo.

Only when the two paths match are you in a normal checkout.

### 10.2 Directory — pick, then prove it's ignored

Priority: explicit instruction › existing `.worktrees/` › existing `worktrees/` › default
`.worktrees/`.

**Before creating, verify the directory is ignored.** An unignored worktree dir commits the
entire tree into the repo:

```
git check-ignore -q .worktrees || {
  echo ".worktrees/" >> .gitignore
  git add .gitignore
  git commit -m "chore: ignore worktrees dir"
}
```

If the worktree must live outside the repo, use a sibling instead: `<repo-root>-wt-<slug>`.

### 10.3 Create, then start from a clean baseline

```
git worktree add -b wt/<slug> <repo-root>/.worktrees/<slug> <main | commit | tag>
```

1. **Set up deps** — detect and run the project's own installer (`npm install`, `cargo build`,
   `pip install -r requirements.txt`, `poetry install`, `go mod download`).
2. **Run the test suite before writing code.** A dirty baseline makes every later failure
   ambiguous. If tests already fail, report and ask — do not build on sand.
3. Report: worktree path, baseline result, ready.

**Sandbox fallback:** if `git worktree add` is blocked by permissions, say so and work in place.

### 10.4 Work, merge, remove

```pwsh
# pin every command to the worktree — the shell cwd is NOT the worktree
git -C <path> status
git -C <path> add -A; git -C <path> commit -m "..."

# merge into the base with a merge commit (keeps history readable)
git -C <repo-root> merge --no-ff wt/<slug>

# after merge, remove and sweep stale bookkeeping
git -C <repo-root> worktree remove <path>
git -C <repo-root> worktree prune
git -C <repo-root> worktree list
```

The `--no-ff` merge here is a local integration step. The PR itself still squashes per §6.

### 10.5 Rails

- **One writer per worktree.** One tree = one agent or session at a time; concurrent edits
  corrupt review state.
- **Always pin with `git -C <path>`.** Never assume the shell is inside the worktree.
- **No `git clean` or `git reset --hard`** in a shared worktree.
- **Uncommitted work stays put.** Never carry edits between worktrees — commit, then merge.
- **`git worktree remove` refusing a dirty tree is the safety, not an error to route around.**
- **Adopting a worktree as the session's working directory is a session move:** call
  `tools.opencode.session_move` rather than relying on shell cwd.

## 11. Never

- Never work directly on main.
- Never merge red — main stays green.
- Never commit secrets, `.env`, or credentials.
- Never commit debug prints or commented-out code.
- Never commit generated artifacts unless the repo expects them.
- Never force-push a shared branch.
- Never create a second release entry or a per-version tag.
- Never bump a version without a stated justification.
- Never tag by default.

## Quick card

```
detect repo rules → pull --ff-only → branch type/slug → commit type: summary →
push → PR (What/Why/Check/Risk) → squash → delete branch
version: repo's format first, else MAJOR.MINOR.PATCH — every bump justified, own commit
tags: off    release: one, moved via `latest`, body rewritten
worktree: detect first · .worktrees/ ignored · clean baseline · one writer · git -C
main stays green · force-push only with --force-with-lease
repo rules always win
```
