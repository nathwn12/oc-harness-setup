#Requires -Version 7.0
<#
.SYNOPSIS
  Shared core for the gc-* git-ceremony scripts (scripts\gc-*.ps1).

.DESCRIPTION
  Dot-sourced by every gc-* script. Provides logging, the pinned git runner
  (always `git -C <root>` — never the ambient cwd, per the worktree rails in
  git-ceremony §10), ceremony validation, default-branch resolution, the secret
  gate, and the RESULT line contract.

  EXIT-CODE CONTRACT (stable API for agent callers):
    0  success or clean no-op
    1  generic failure (unexpected)
    2  agent-fixable stop — needs agent action to proceed
       (precondition violated, push rejected, conflict stop, merge refused)
    3  dependency missing or unusable (git, gh)
    4  security gate blocked a stage/commit (secret scan hit)

  OUTPUT CONTRACT: every script prints exactly one final stdout line
      RESULT: <json>
  whatever the outcome (ok, exit code, message, per-script props). Under the
  terse default that RESULT line is the ONLY line on stdout. -Detailed routes
  the Write-Host narration through the console instead, but across a process
  boundary that text is still captured by the caller (2>&1 sees it), so the real
  guarantee is: take the LAST `RESULT: ` line out of the captured output. Quote
  it, e.g.
      $r = pwsh -NoProfile -File scripts\gc-commit.ps1 ... | Out-String
  Write-GcFail and Write-GcNotice always print, in either mode.

  TERSE LEVER: the default is TERSE — a run prints only the RESULT line plus
  warnings, failures, and the security/remediation guidance. -Detailed restores
  the step narration, the ok/info lines, and the raw git/gh relay; -Quiet is
  accepted as a no-op for compatibility and wins if passed with -Detailed. The
  RESULT line, the exit code, warnings, failures, and the secret-gate guidance
  are never gated by either switch.

  FLOW MAP (git-ceremony section → script; see reference/gc-scripts.md):
    §1 pull / sync           gc-sync.ps1
    §2 branch lifecycle      gc-branch.ps1  (create · -Reuse switch · -Delete)
    §3 stage + commit        gc-stage.ps1 · gc-commit.ps1
    §4 push + PR             gc-push.ps1 · gc-pr.ps1
    §6 merge + cleanup       gc-merge.ps1  (-Mode squash | merge | rebase)
    status / where-am-i      gc-status.ps1
    rebase rail              gc-rebase.ps1 (-Onto · -Continue · -Abort)
    §8 version bump          gc-bump.ps1   (-Major | -Minor | -Patch | -Set)
    §9 release               gc-release.ps1 (one entry · moving `latest` pointer)
  Deliberately NOT scripted (prose; repo rules win): §5 review comments,
  §7 tags (off by default), §10 worktrees (YAGNI-hold).

  SECRET GATE
  gc-stage and gc-commit block on a best-effort scan for obvious secret shapes:
  private-key blocks, AWS AKIA keys, GitHub tokens, Slack tokens, sk- API
  tokens, and key-ish filenames (.env*, *.pem, *.p12, *.pfx, *.key, id_*,
  credentials). .env.example/.env.sample/.env.template are explicitly allowed.
  The gate is defence in depth, NOT a guarantee — novel shapes can slip it, and
  the staged-diff review stays the real last gate. On a hit the offending files
  are left UNSTAGED (working-tree content untouched) and the script exits 4.
  There is deliberately no bypass switch — the fix is to remove the secret.

.NOTES
  git-ceremony precedence: a repo's own documented convention always wins; this
  script set is the fallback ceremony. If the repo dictates its own rules, do
  not force these scripts onto it.
  Run every gc-* script via `pwsh -File <script>`; Write-GcResult exits the
  process with the documented code, so interactive dot-sourcing of the core is
  intentional and unsupported for the exit path.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- exit codes (documented contract, see .SYNOPSIS) -------------------------
$script:GcExitOk     = 0
$script:GcExitFail   = 1
$script:GcExitPre    = 2   # precondition / ceremony invariant violated
$script:GcExitDep    = 3   # dependency missing or unusable (git, gh)
$script:GcExitSecret = 4   # security gate blocked a stage/commit

$script:GcCeremonyTypes = @('feat','fix','chore','docs','refactor','test','perf','hotfix','wt')

class GcException : System.Exception {
    [int]$Code
    GcException([string]$Message, [int]$Code) : base($Message) { $this.Code = $Code }
}

# --- logging (console only; stdout is reserved for the RESULT line) ----------
# TERSE BY DEFAULT: $script:GcQuiet starts $true, so a bare invocation prints
# only the RESULT line. -Detailed sets it $false (restores the pre-lever
# chatter); -Quiet forces it $true and so wins when both are passed.
# ALWAYS VISIBLE, never gated: the RESULT line (stdout), Write-GcFail,
# Write-GcWarn (decision cues — merge/rebase/push warnings are the reason the
# old docs said not to quiet those verbs), and Write-GcNotice (remediation /
# security guidance). GATED by $script:GcQuiet: Write-GcInfo / Write-GcOk
# narration and the raw git/gh relay (Write-GcNote).
$script:GcQuiet = $true
function Write-GcInfo { param([string]$Message) if (-not $script:GcQuiet) { Write-Host "[gc] $Message" -ForegroundColor Cyan } }
function Write-GcOk   { param([string]$Message) if (-not $script:GcQuiet) { Write-Host "[gc] ok: $Message" -ForegroundColor Green } }
function Write-GcWarn { param([string]$Message) Write-Host "[gc] warn: $Message" -ForegroundColor Yellow }
function Write-GcFail { param([string]$Message) Write-Host "[gc] FAIL: $Message" -ForegroundColor Red }
function Write-GcNotice {
    <# ungated console print for actionable/security guidance (remediation,
       offender handling, next steps) that must survive the terse default. #>
    param([string]$Message)
    Write-Host "[gc] $Message" -ForegroundColor White
}
function Write-GcNote {
    <# gated console print for raw chatter (git/gh relay lines, diff stats);
       the single biggest noise emitter is the git/gh output relay. #>
    param([string]$Text, [System.Nullable[ConsoleColor]]$ForegroundColor = $null)
    if (-not $script:GcQuiet) {
        if ($null -ne $ForegroundColor) { Write-Host $Text -ForegroundColor $ForegroundColor }
        else { Write-Host $Text }
    }
}

# --- pinned git runner --------------------------------------------------------
function Invoke-GcGit {
    <# git pinned to the repo root; throws GcException on non-zero exit.
       Output relays to the console only — script stdout stays reserved for the
       RESULT line. Use Get-GcGit when you need the output. Every invocation is
       a mutation, so it drops the cached repo state. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Argv)
    Clear-GcRepoState
    $out = & git -C $Root @Argv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [GcException]::new("git $($Argv[0]) exited $($LASTEXITCODE): " + (($out | Out-String).Trim()), $script:GcExitFail)
    }
    foreach ($line in @($out)) { if ($line) { Write-GcNote "  $line" -ForegroundColor DarkGray } }
    return
}

function Get-GcGit {
    <# like Invoke-GcGit but returns stdout as clean string lines, for parsing.
       Single-line native output wraps to a 1-element array (a bare string must
       never be piped — PowerShell would enumerate its characters). #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Argv)
    $out = & git -C $Root @Argv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw [GcException]::new("git $($Argv[0]) exited $($LASTEXITCODE)", $script:GcExitFail)
    }
    if ($null -eq $out) { return @() }
    return @($out)
}

function Resolve-GcRoot {
    <# the repository root for a path; Pre failure (exit 2) with the fix when
       not inside a repo — contract: precondition violations are agent-fixable. #>
    param([string]$Path = (Get-Location).Path)
    $top = & git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $top) {
        throw [GcException]::new("not inside a git working tree: $Path — cd into a repository or pass -RepoRoot", $script:GcExitPre)
    }
    return (@($top)[0]).Trim()
}

# --- repo state: one porcelain v2 call per mutation window --------------------
# The verbs used to ask separate git calls for branch (rev-parse), cleanliness
# (status --porcelain), staged names (diff --cached) and, in gc-status,
# ahead/behind (two rev-list). One `status --porcelain=v2 --branch -z` (37 ms)
# answers all of them; the result is cached per repo root and dropped by every
# mutation (Invoke-GcGit), so a verb shares one call and never reads stale state.
$script:GcRepoStateCache = @{}
function Clear-GcRepoState { $script:GcRepoStateCache = @{} }

function Get-GcRepoState {
    param([Parameter(Mandatory)][string]$Root)
    if ($script:GcRepoStateCache.ContainsKey($Root)) { return $script:GcRepoStateCache[$Root] }
    $out = & git -C $Root status --porcelain=v2 --branch -z 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw [GcException]::new("git status exited $LASTEXITCODE (not a git working tree: $Root)", $script:GcExitFail)
    }
    $text = if ($null -eq $out) { '' } else { (@($out) -join "`n") }
    $tokens = @($text.Split([char]0) | Where-Object { $_ -ne '' })

    $branch = $null; $detached = $false; $unborn = $false
    $upstream = $null; $ahead = $null; $behind = $null
    $staged = [System.Collections.Generic.List[string]]::new()
    $stagedDeleted = [System.Collections.Generic.List[string]]::new()
    $untracked = 0; $unstaged = 0; $conflicts = 0; $dirty = $false
    $unmergedSet = @('AA','DD','UU','AU','UA','DU','UD')
    $skipNext = $false

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        switch ($t[0]) {
            '#' {
                if ($t -match '^# branch\.oid (.+)$') { $unborn = ($Matches[1] -ceq '(initial)') }
                elseif ($t -match '^# branch\.head (.+)$') {
                    if ($Matches[1] -ceq '(detached)') { $detached = $true } else { $branch = $Matches[1] }
                }
                elseif ($t -match '^# branch\.upstream (.+)$') { $upstream = $Matches[1] }
                elseif ($t -match '^# branch\.ab \+(\d+) -(\d+)$') { $ahead = [int]$Matches[1]; $behind = [int]$Matches[2] }
            }
            '?' { $untracked++; $dirty = $true }
            '1' {
                # 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path> — remainder is the path
                $p = $t -split ' ', 9
                $dirty = $true
                if ($p[1][0] -cne '.') {
                    $staged.Add($p[8])
                    if ($p[1][0] -ceq 'D' -and $p[1][1] -ceq '.') { $stagedDeleted.Add($p[8]) }
                }
                if ($p[1][1] -cne '.') { $unstaged++ }
            }
            '2' {
                # 2 <XY> ... <X><score> <path>, then the ORIGINAL path as the next
                # NUL token — consume it, keep the new path (matches diff --cached)
                $p = $t -split ' ', 10
                $dirty = $true
                if ($p[1][0] -cne '.') {
                    $staged.Add($p[9])
                    if ($p[1][0] -ceq 'D' -and $p[1][1] -ceq '.') { $stagedDeleted.Add($p[9]) }
                }
                if ($p[1][1] -cne '.') { $unstaged++ }
                $skipNext = $true
            }
            'u' {
                # u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                $p = $t -split ' ', 11
                $dirty = $true
                $staged.Add($p[10])   # diff --cached --name-only lists unmerged paths
                if ($unmergedSet -ccontains $p[1]) { $conflicts++ }
                if ($p[1][1] -cne '.') { $unstaged++ }
            }
        }
        if ($skipNext) { $i++; $skipNext = $false }
    }
    $state = [pscustomobject]@{
        Branch        = $branch
        Detached      = $detached
        Unborn        = $unborn
        Upstream      = $upstream
        Ahead         = $ahead
        Behind        = $behind
        Clean         = (-not $dirty)
        Staged        = $staged.ToArray()
        StagedDeleted = $stagedDeleted.ToArray()
        Unstaged      = $unstaged
        Conflicts     = $conflicts
        Untracked     = $untracked
    }
    $script:GcRepoStateCache[$Root] = $state
    return $state
}

function Get-GcCurrentBranch {
    <#
    The current branch. Two paths, identical contract and failure modes:
      - default: from the cached repo state (shares one porcelain walk with the
        other facts the verb needs).
      - -Targeted: one `rev-parse --abbrev-ref HEAD`, no worktree walk. For a
        verb that needs the branch and NOTHING else, the state walk costs tens
        of ms and grows with the worktree size; rev-parse is flat (~36 ms).
    #>
    param([Parameter(Mandatory)][string]$Root, [switch]$Targeted)
    if ($Targeted) {
        try {
            $b = (Get-GcGit -Root $Root -Argv @('rev-parse','--abbrev-ref','HEAD') | Select-Object -First 1).Trim()
        } catch {
            # rev-parse --abbrev-ref HEAD exits 128 on an unborn HEAD ('ambiguous
            # argument HEAD'); keep the state path's failure mode.
            throw [GcException]::new('HEAD is unborn (no commits yet)', $script:GcExitFail)
        }
        if ($b -ceq 'HEAD') { throw [GcException]::new('HEAD is detached — switch to a branch first', $script:GcExitPre) }
        return $b
    }
    $st = Get-GcRepoState -Root $Root
    if ($st.Detached) { throw [GcException]::new('HEAD is detached — switch to a branch first', $script:GcExitPre) }
    if ($st.Unborn) {
        # rev-parse --abbrev-ref HEAD fails on an unborn HEAD; keep that failure
        # mode (generic exit) rather than reporting the unborn branch name.
        throw [GcException]::new('HEAD is unborn (no commits yet)', $script:GcExitFail)
    }
    return $st.Branch
}

function Test-GcRef {
    <# $true when the ref exists. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Ref)
    try { Get-GcGit -Root $Root -Argv @('rev-parse','--verify','--quiet',$Ref) | Out-Null; return $true }
    catch { return $false }
}

function Get-GcConfig {
    <# git config value, '' when unset (config lookup failures are not errors). #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Key)
    try { return ((Get-GcGit -Root $Root -Argv @('config',$Key) | Select-Object -First 1).Trim()) }
    catch { return '' }
}

function Get-GcDefaultBranch {
    <#
    Resolve the default branch name, ceremony precedence (§1):
      1. selected remote HEAD symref (origin, otherwise the sole remote)
      2. init.defaultBranch config
      3. an existing refs/heads/main or refs/heads/master
      4. 'main' (name only — fine for unborn repos; creation validates later)
    Never hits the network.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $remotes = @(Get-GcGit -Root $Root -Argv @('remote') | ForEach-Object { $_.Trim() })
    $remote = if ($remotes -contains 'origin') { 'origin' } elseif ($remotes.Count -eq 1) { $remotes[0] } else { $null }
    if ($remote) {
        try {
            $sym = (Get-GcGit -Root $Root -Argv @('symbolic-ref','--quiet',"refs/remotes/$remote/HEAD") |
                    Select-Object -First 1).Trim()
            if ($sym -match ("^refs/remotes/" + [regex]::Escape($remote) + "/(.+)$")) { return $Matches[1] }
        } catch { }   # remote HEAD unset — fall through
    }
    $name = Get-GcConfig -Root $Root -Key 'init.defaultBranch'
    if (-not $name) { $name = 'main' }
    foreach ($cand in @($name,'main','master')) {
        if (Test-GcRef -Root $Root -Ref "refs/heads/$cand") { return $cand }
    }
    return $name
}

function Get-GcRemote {
    <# origin if present, else the sole remote; Pre failure otherwise. #>
    param([Parameter(Mandatory)][string]$Root, [string]$Preferred = 'origin')
    $r = @(Get-GcGit -Root $Root -Argv @('remote') | ForEach-Object { $_.Trim() })
    if ($Preferred -and $r -contains $Preferred) { return $Preferred }
    if ($r.Count -eq 1) { return $r[0] }
    if ($r.Count -eq 0) { throw [GcException]::new('no git remote configured — gc-pr / gc-push need one', $script:GcExitPre) }
    throw [GcException]::new("multiple remotes ($($r -join ', ')) and no origin — pass -Remote explicitly", $script:GcExitPre)
}

function Test-GcCleanTree {
    param([Parameter(Mandatory)][string]$Root)
    return (Get-GcRepoState -Root $Root).Clean
}

function Test-GcRebaseInProgress {
    <# $true when a rebase is stopped (conflict or paused) — .git/rebase-merge
       or .git/rebase-apply exists. Shared by gc-rebase and gc-status. #>
    param([Parameter(Mandatory)][string]$Root)
    foreach ($state in @('rebase-merge','rebase-apply')) {
        try {
            $p = (Get-GcGit -Root $Root -Argv @('rev-parse','--git-path',$state) | Select-Object -First 1).Trim()
            if ($p) {
                $abs = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $Root $p }
                if (Test-Path -LiteralPath $abs) { return $true }
            }
        } catch { }
    }
    return $false
}

function Assert-GcRefValue {
    <# ref-shaped user input, e.g. -Onto / -Branch / base: rejects a leading
       dash (git option injection — gc-rebase -Onto '--exec=...' executes
       commands), edge whitespace, and characters no ref can contain.
       Boundary: ref names are ASCII-only in this toolset ([A-Za-z0-9._/-@~^]
       plus rev-syntax braces for @{upstream}); ':' and '*' are rejected. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    $invalid = $Value -cmatch '^-' -or $Value -match '^\s' -or $Value -match '\s$' -or
               $Value -cnotmatch '^[A-Za-z0-9._/@~^{}-]+$'
    if ($invalid) {
        throw [GcException]::new("$Name '$Value' is not a valid ref — no leading dash, no edge whitespace, ASCII ref characters only", $script:GcExitPre)
    }
}

function Format-GcPrBody {
    <# the §4 PR body, exactly: What / Why (omitted when empty) / Check / Risk,
       one line each. Pure renderer — pinned by the smoke without gh. #>
    param([Parameter(Mandatory)][string]$What, [string]$Why, [string]$Check, [string]$Risk)
    $bodyLines = @("What:  $What")
    if ($Why) { $bodyLines += "Why:   $Why" }
    $bodyLines += @("Check: $(if ($Check) { $Check } else { 'n/a' })", "Risk:  $(if ($Risk) { $Risk } else { 'low' })")
    return ($bodyLines -join "`n")
}

function Convert-GcMergeMode {
    <# §6 merge method → the gh flag. Pure mapping — pinned without gh. #>
    param([Parameter(Mandatory)][ValidateSet('squash','merge','rebase')][string]$Mode)
    return $(switch ($Mode) { 'squash' { '--squash' } 'merge' { '--merge' } 'rebase' { '--rebase' } })
}

function Get-GcMergedMethod {
    <# truthful merge-method label for an ALREADY-merged PR, read from the
       merge commit's own subject (gh's mergeCommit field carries no message).
       'merge' = "Merge pull request #N from …" · 'squash' = "title (#N)" ·
       'rebase' = the original subject · 'unknown' when the commit is absent. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sha)
    if (-not $Sha) { return 'unknown' }
    try {
        $msg = (Get-GcGit -Root $Root -Argv @('log','-1','--format=%s',$Sha) | Select-Object -First 1).Trim()
        if ($msg -match '^Merge pull request') { return 'merge' }
        if ($msg -match '#[0-9]+\)\s*$') { return 'squash' }
        return 'rebase'
    } catch { return 'unknown' }
}

# --- release renderers (§9) ---------------------------------------------------
function Get-GcChangelogSection {
    <#
    §9: the release body is rendered from the changelog. Locate the section for a
    version — a `## <version>` heading (trailing text such as a date allowed)
    up to the next `## ` heading — and return its lines WITHOUT the heading,
    blank-trimmed. Pre failure (exit 2) when CHANGELOG.md or the section is
    missing: the entry body is never hand-written (one source of truth, §8).
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version)
    $abs = Join-Path $Root 'CHANGELOG.md'
    if (-not (Test-Path -LiteralPath $abs)) {
        throw [GcException]::new('CHANGELOG.md not found — §9 renders the release body from the changelog; add it first', $script:GcExitPre)
    }
    $escaped = [regex]::Escape($Version)
    $section = [System.Collections.Generic.List[string]]::new()
    $found = $false
    foreach ($line in @(Get-Content -LiteralPath $abs)) {
        if (-not $found) {
            if ($line -match "^##\s+$escaped(\s|$)") { $found = $true }
            continue
        }
        if ($line -match '^##\s') { break }
        $section.Add($line)
    }
    if (-not $found) {
        throw [GcException]::new("CHANGELOG.md has no section for version '$Version' — the release body is rendered from the changelog (§8 one source of truth); add the section first", $script:GcExitPre)
    }
    while ($section.Count -gt 0 -and -not $section[0].Trim()) { $section.RemoveAt(0) }
    while ($section.Count -gt 0 -and -not $section[$section.Count - 1].Trim()) { $section.RemoveAt($section.Count - 1) }
    $section.ToArray()
}

function Format-GcReleaseBody {
    <# §9 body: the Version line — rendered from the manifest, never hand-edited
       — plus the changelog section verbatim. Pure renderer; pinned by the smoke
       without gh or npm. #>
    param([Parameter(Mandatory)][string]$Version, [string[]]$Lines)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("Version: $Version")
    $parts.Add('')
    if ($Lines) { foreach ($l in $Lines) { $parts.Add($l) } }
    return ($parts -join "`n")
}

function Get-GcStagedNames {
    param([Parameter(Mandatory)][string]$Root)
    return (Get-GcRepoState -Root $Root).Staged
}

function Sync-GcDefaultBranch {
    <#
    Ceremony §1: fetch the selected remote, then fast-forward the local default branch.
    Never manufactures a merge. Pre failure when the tree is dirty and a
    switch is needed, when the branch diverged, or when the default branch is
    not a fast-forward of its remote head.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Default,
        [string]$CurrentBranch
    )
    $remotes = @(Get-GcGit -Root $Root -Argv @('remote') | ForEach-Object { $_.Trim() })
    if ($remotes.Count -eq 0) {
        Write-GcInfo 'no remote — skipping fetch (local-only repo)'
        return 'skipped-local'
    }
    $remote = Get-GcRemote -Root $Root
    Invoke-GcGit -Root $Root -Argv @('fetch','--prune',$remote)
    if (-not (Test-GcRef -Root $Root -Ref "refs/remotes/$remote/$Default")) {
        Write-GcInfo "$remote/$Default has no remote head yet — nothing to fast-forward"
        return 'skipped-no-remote-head'
    }
    $localExists = Test-GcRef -Root $Root -Ref "refs/heads/$Default"
    if (-not $localExists) {
        # no local default yet: switch DWIM-creates the tracking branch from
        # <remote>/<default> — no merge involved, so always safe.
        Invoke-GcGit -Root $Root -Argv @('switch',$Default)
        Write-GcOk "created local $Default tracking $remote/$Default"
        return 'created'
    }
    $localAhead = [int](Get-GcGit -Root $Root -Argv @('rev-list','--count',"$remote/$Default..$Default"))
    $localBehind = [int](Get-GcGit -Root $Root -Argv @('rev-list','--count',"$Default..$remote/$Default"))
    if ($localAhead -eq 0 -and $localBehind -eq 0) { Write-GcInfo 'default branch up to date'; return 'up-to-date' }
    if ($localAhead -gt 0 -and $localBehind -gt 0) {
        throw [GcException]::new("default branch diverged from $remote/$Default ($localAhead ahead / $localBehind behind) — stop; resolve by hand, never manufacture a merge here", $script:GcExitPre)
    }
    if ($localAhead -gt 0) {
        Write-GcInfo "local $Default is $localAhead commit(s) ahead of $remote — keeping local"
        return 'local-ahead'
    }
    # local behind: fast-forward only.
    if (-not (Test-GcCleanTree -Root $Root)) {
        throw [GcException]::new("$Default is $localBehind commit(s) behind $remote/$Default but the tree is dirty — commit or stash first, then re-run", $script:GcExitPre)
    }
    if ($CurrentBranch -ne $Default) { Invoke-GcGit -Root $Root -Argv @('switch',$Default) }
    Invoke-GcGit -Root $Root -Argv @('merge','--ff-only',"$remote/$Default")
    Write-GcOk "$Default fast-forwarded to $remote/$Default"
    return 'fast-forwarded'
}

# --- ceremony validation ------------------------------------------------------
function Test-GcBranchName {
    <# validates `<type>/<slug>` per git-ceremony §2; prints why on failure.
       PowerShell -match/-contains are case-insensitive, so the ceremony checks
       must be case-sensitive (-cmatch / -cnotcontains). #>
    param([Parameter(Mandatory)][string]$Branch)
    $parts = $Branch -split '/', 2
    if ($parts.Count -ne 2) {
        Write-GcFail "branch '$Branch' must be <type>/<slug> — e.g. feat/token-refresh"
        return $false
    }
    if ($script:GcCeremonyTypes -cnotcontains $parts[0]) {
        Write-GcFail "type '$($parts[0])' not in ceremony set: $($script:GcCeremonyTypes -join ', ')"
        return $false
    }
    if ($parts[1] -cnotmatch '^[a-z0-9]+(-[a-z0-9]+){1,4}$') {
        Write-GcFail "slug '$($parts[1])' must be 2-5 kebab-case words, lowercase letters/digits only, no author/date — e.g. login-timeout-4821"
        return $false
    }
    return $true
}

function Get-GcSubjectParts {
    <#
    Validates a full commit subject per git-ceremony §3:
    `type(scope): imperative summary` ≤72 chars, no trailing period, lowercase
    start. Returns type/scope/summary. Pre failure with the fix in the message.
    #>
    param([Parameter(Mandatory)][string]$Subject)
    if ($Subject.Length -gt 72) {
        throw [GcException]::new("subject is $($Subject.Length) chars — ceremony caps it at 72", $script:GcExitPre)
    }
    if ($Subject -cmatch '\.\s*$') {
        throw [GcException]::new("subject must not end with a period", $script:GcExitPre)
    }
    if ($Subject -cnotmatch '^([a-z]+)(\(([a-z0-9-]+)\))?: (.+)$') {
        throw [GcException]::new("subject must match: type(scope): summary — e.g. 'fix(api): cap retry backoff at 30s'", $script:GcExitPre)
    }
    $type = $Matches[1]
    $scope = if ($Matches.ContainsKey(3)) { $Matches[3] } else { $null }
    $summary = $Matches[4]
    if ($script:GcCeremonyTypes -notcontains $type) {
        throw [GcException]::new("type '$type' not in ceremony set: $($script:GcCeremonyTypes -join ', ')", $script:GcExitPre)
    }
    if ($summary -cnotmatch '^[a-z0-9]') {
        throw [GcException]::new("summary must start lowercase (imperative: 'add', 'cap', 'fix')", $script:GcExitPre)
    }
    return [pscustomobject]@{ Type = $type; Scope = $scope; Summary = $summary }
}

function Assert-GcIdentity {
    <# git user.name + user.email must exist; Pre failure with the fix. #>
    param([Parameter(Mandatory)][string]$Root)
    $n = Get-GcConfig -Root $Root -Key 'user.name'
    $e = Get-GcConfig -Root $Root -Key 'user.email'
    if (-not $n -or -not $e) {
        throw [GcException]::new('git identity not set — run once per repo: git config user.name "You" ; git config user.email "you@host"', $script:GcExitPre)
    }
}

# --- gh ----------------------------------------------------------------------
function Assert-GcGh {
    <# gh present. Authentication is deliberately NOT probed: `gh auth status`
       costs ~0.5 s on every gh verb and the first real call is the probe —
       Convert-GcGhError maps its not-logged-in failure back to the dependency
       exit, so the documented exit-3 contract is preserved without the wait. #>
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw [GcException]::new('gh (GitHub CLI) is not installed or not on PATH', $script:GcExitDep)
    }
}

$script:GcGhAuthRe = 'gh auth login|not logged in|authentication required|HTTP 401'

function Convert-GcGhError {
    <# gh's own failure message → GcException (always throws). A not-logged-in
       failure keeps the documented dependency exit (3) and the actionable login
       text; any other failure stays generic (1). Replaces the deleted probe. #>
    param([Parameter(Mandatory)][string]$Verb, [Parameter(Mandatory)][int]$Code, [string]$Text)
    if ($Text -match $script:GcGhAuthRe) {
        throw [GcException]::new('gh is not authenticated — run `gh auth login` once, human', $script:GcExitDep)
    }
    throw [GcException]::new("gh $Verb exited $Code`: " + $Text.Trim(), $script:GcExitFail)
}

function Invoke-GcGhCapture {
    <# Run gh from the repo root and return its stdout, its error text and its
       exit code, without throwing. `gh @Argv 2>&1` catches a native gh's
       stderr, but a wrapper/script gh writing to the process error stream
       ([Console]::Error) bypasses PowerShell's 2>&1 — swapping Console.Error
       around the call catches that too, so a failure's own message (e.g.
       "please run:  gh auth login") always reaches Convert-GcGhError. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Argv)
    Push-Location $Root
    try {
        $prevErr = [Console]::Error
        $errBuf  = [System.IO.StringWriter]::new()
        $out = $null; $code = 0
        try {
            [Console]::SetError($errBuf)
            $out = & gh @Argv 2>&1
            $code = $LASTEXITCODE
        } finally { [Console]::SetError($prevErr) }
    } finally { Pop-Location }
    $text = if ($null -eq $out) { '' } else { (@($out) -join "`n") }
    $err  = $errBuf.ToString()
    if ($err) { $text = if ($text) { "$text`n$err".Trim() } else { $err.Trim() } }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Invoke-GcGh {
    <# gh pinned to the repo root (gh has no -C); output relays to the console
       only; throws GcException on exit != 0. Use Get-GcGhJson for parsing. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Argv)
    $r = Invoke-GcGhCapture -Root $Root -Argv $Argv
    if ($r.Code -ne 0) { Convert-GcGhError -Verb $Argv[0] -Code $r.Code -Text $r.Text }
    foreach ($line in @($r.Text -split "`n")) { if ($line) { Write-GcNote "  $line" -ForegroundColor DarkGray } }
    return
}

function Get-GcGhJson {
    <# gh --json result as a parsed object; failure keeps gh's own message.
       Never pipes a bare string (chars) — join first. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Argv)
    $r = Invoke-GcGhCapture -Root $Root -Argv $Argv
    if ($r.Code -ne 0) { Convert-GcGhError -Verb $Argv[0] -Code $r.Code -Text $r.Text }
    return ($r.Text | ConvertFrom-Json)
}

# --- secret gate --------------------------------------------------------------
$script:GcSecretSafeFilenameRe = '^\.env\.(example|sample|template)$'
$script:GcSecretFilenameRe = '\.env(\.[A-Za-z0-9_-]+)?$|\.pem$|\.p12$|\.pfx$|\.key$|^(id_rsa|id_ed25519|id_ecdsa|id_dsa|credentials)$'
$script:GcSecretContentRes = @(
    '-----BEGIN (RSA |EC |OPENSSH |DSA |PGP |ENCRYPTED )?PRIVATE KEY-----',
    'AKIA[0-9A-Z]{16}',
    'ghp_[A-Za-z0-9]{36}',
    'github_pat_[A-Za-z0-9_]{30,}',
    'xox[baprs]-[A-Za-z0-9-]{10,}',
    'sk-[A-Za-z0-9]{24,}'
)

function Get-GcSecretHits {
    <#
    Scans the STAGED CONTENT — the index blobs via `git show :<path>`, exactly
    what a commit would ship — for obvious secret shapes. A worktree edit after
    `git add` cannot smuggle a staged secret past this gate. Staged DELETIONS
    are skipped (removing key material is the fix itself). Returns a list of
    { File, Why } hits — empty when clean. Callers unstage the hits and exit 4.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $state = Get-GcRepoState -Root $Root
    # staged DELETIONS are skipped: removing key material is the fix itself.
    # StagedDeleted mirrors the old `^D\s+` filter (X=D, Y=.) exactly.
    $deleted = @{}
    foreach ($n in $state.StagedDeleted) { $deleted[$n] = $true }
    $hits = @()
    foreach ($rel in $state.Staged) {
        if ($deleted.ContainsKey($rel)) { continue }
        $leaf = Split-Path $rel -Leaf
        if ($leaf -match $script:GcSecretSafeFilenameRe) { continue }
        $why = $null
        if ($leaf -match $script:GcSecretFilenameRe) {
            $why = "filename looks like key material ($leaf)"
        } else {
            try {
                $blob = @(Get-GcGit -Root $Root -Argv @('show',":$rel"))
                $text = ($blob -join "`n")
                foreach ($re in $script:GcSecretContentRes) {
                    if ($text -match $re) { $why = "staged content matches $re"; break }
                }
            } catch { }   # no index blob / unreadable — skip the content pass
        }
        if ($why) { $hits += [pscustomobject]@{ File = $rel; Why = $why } }
    }
    return $hits
}

function Stop-GcOnSecrets {
    <#
    Blocks a stage/commit on secret hits: unstages exactly the offending files
    (working tree untouched), prints remediation, and exits 4.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $hits = Get-GcSecretHits -Root $Root
    if (-not $hits) { return }
    $names = @($hits | ForEach-Object { $_.File })
    Write-GcFail "secret scan blocked: $($names -join ', ')"
    foreach ($h in $hits) { Write-GcFail "  $($h.File) — $($h.Why)" }
    # `restore --staged` resolves HEAD; on an unborn repo (fresh init, no commits)
    # it dies with "fatal: could not resolve 'HEAD'". Fall back to the index-only
    # unstage for the SAME offender names — same narrow semantics, working tree
    # untouched, exit 4 unchanged.
    $unstaged = $false
    try {
        Invoke-GcGit -Root $Root -Argv (@('restore','--staged','--') + $names)
        $unstaged = $true
    } catch {
        try {
            Invoke-GcGit -Root $Root -Argv (@('rm','--cached','--quiet','--') + $names)
            $unstaged = $true
        } catch {
            Write-GcFail "could not unstage the offenders: $($_.Exception.Message)"
        }
    }
    if ($unstaged) { Write-GcNotice 'unstaged exactly those files; working tree untouched' }
    Write-GcNotice 'remediation: remove the secret, add a .gitignore entry if the file is never meant to be tracked, then re-run'
    Write-GcResult -Code $script:GcExitSecret -Props @{ message = 'secret scan blocked the operation'; blocked = $names }
}

# --- result line --------------------------------------------------------------
function Write-GcResult {
    <#
    Prints the single contract stdout line and exits with the documented code.
    stdout carries ONLY this line; everything else is Write-Host.
    #>
    param([int]$Code = 0, [hashtable]$Props = @{})
    $o = [ordered]@{ ok = ($Code -eq 0); exit = $Code }
    foreach ($k in $Props.Keys) { $o[$k] = $Props[$k] }
    if ($Code -ne 0) { Write-Host '' }
    Write-Output ("RESULT: " + ($o | ConvertTo-Json -Compress))
    exit $Code
}
