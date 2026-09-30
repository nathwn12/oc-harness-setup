#Requires -Version 7.0
<#
.SYNOPSIS
  Commit the staged content with a ceremony-validated message. No editor, no
  prompts, no human in the middle.

.DESCRIPTION
  git-ceremony §3 as a script. Validates the subject
  (`type(scope): imperative summary`, ≤72 chars, no trailing period, lowercase
  start — `fix: cap retry backoff at 30s`), caps the body at three plain
  bullets, puts issue refs in the body (never the subject), refuses to commit
  on every default-branch commit. Direct-default fallback is outside this
  script only, after all §11b predicates are verified; unknown predicates
  require stopping and escalating. Re-runs the secret
  scan over the staged diff (the last gate), prints the staged diff stat for
  review, then commits the staged content exactly.

  Nothing staged fails with a remediation (run gc-stage or -All) — exit 2.
  A repo without user.name/user.email fails with the fix — exit 2.

  Repo rules win: if the repo documents its own convention (commit-lint,
  sign-off, DCO), follow that instead of this script.

.PARAMETER Type
  One of: feat, fix, chore, docs, refactor, test, perf, hotfix, wt.
.PARAMETER Scope
  Optional kebab-case scope, e.g. api — renders as type(scope): summary.
.PARAMETER Summary
  Imperative summary, lowercase first char, no trailing period.
.PARAMETER Body
  Up to 3 plain lines; rendered as bullets under the subject. Bullets are
  newline-separated: pwsh -File callers pass ONE argument with embedded `n
  characters (repeated -Body and comma lists do NOT become arrays under
  pwsh -File — a comma list lands as one literal bullet).
  Do NOT prefix a body line with `-`: a leading dash collides with the
  [string[]] binder and fails with the misleading "Missing an argument for
  parameter 'Body'".
.PARAMETER Issue
  Issue ref (#123 or ABC-123) — goes in the body, never the subject (§3).
.PARAMETER All
  Stage everything first (git add -A, with the same gates as gc-stage).
.PARAMETER RepoRoot
  Repository path (defaults to the current directory); git is always pinned
  with git -C.
.PARAMETER Detailed
  Restore the step narration, ok/info lines, git/gh relay, and the staged-diff
  stat the terse default hides. Never affects the RESULT line, warnings,
  failures, or the security/remediation lines.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -File scripts\gc-commit.ps1 -Type fix -Scope api -Summary 'cap retry backoff at 30s' `
      -Body 'unbounded backoff stalled the queue ~9 min' -Issue #4821
#>
param(
    [string]$Type,
    [string]$Scope,
    [Parameter(Mandatory)][string]$Summary,
    [string[]]$Body,
    [string]$Issue,
    [switch]$All,
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Detailed,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gc.core.ps1')
if ($Detailed) { $script:GcQuiet = $false }
if ($Quiet) { $script:GcQuiet = $true }

try {
    $root = Resolve-GcRoot -Path $RepoRoot
    Write-GcInfo "repo: $root"

    # branch only — targeted rev-parse; the cached state this would build is
    # dropped by the `git add -A` below before Get-GcStagedNames reads it.
    $cur = Get-GcCurrentBranch -Root $root -Targeted
    $default = Get-GcDefaultBranch -Root $root
    if ($cur -eq $default) {
        throw [GcException]::new("intentionally refusing to commit on the default branch ($default). Direct-default fallback applies only when review state is absent (no remote collaborators, default-branch CI, branch protection, CODEOWNERS, or releases/tags), the change is R1 bounded/reversible/local, and gc-stage's secret gate has run. If every predicate is verified, documented §11b permits direct commit for snapshot/derived targets; see skills/git-ceremony §11b and reference/gc-scripts.md. If any condition is unknown or disputed, stop and escalate to the operator; do not retry with raw git.", $script:GcExitPre)
    }

    if ($Scope -and $Scope -cnotmatch '^[a-z0-9-]+$') {
        throw [GcException]::new("scope '$Scope' must be kebab-case — stray positional argument? pass every parameter by name", $script:GcExitPre)
    }
    $subject = if ($Scope) { "${Type}($Scope): $Summary" } else { "${Type}: $Summary" }
    Write-GcInfo "subject: $subject"
    $parts = Get-GcSubjectParts -Subject $subject   # throws Pre with the fix on any violation
    if ($parts.Summary -cmatch '#[0-9]+' -or $parts.Summary -cmatch '(?<![A-Za-z0-9])[A-Z]{3,}-[0-9]{2,}(?![A-Za-z0-9])') {
        throw [GcException]::new("issue refs go in the body via -Issue, never the subject (§3) — '$($parts.Summary)' looks like a ref", $script:GcExitPre)
    }

    $bullets = @()
    foreach ($b in (@($Body) | ForEach-Object { $_ -split "`n" } | Where-Object { $_ -and $_.Trim() })) {
        $bullets += ($b.Trim() -replace '^-+\s*','')
        if ($bullets.Count -gt 3) {
            throw [GcException]::new('body is capped at 3 plain bullets (§3)', $script:GcExitPre)
        }
    }
    if ($Issue) {
        if ($Issue -notmatch '^[A-Za-z0-9#_.-]+$') {
            throw [GcException]::new("issue ref '$Issue' must be a bare ref like #123 or ABC-123", $script:GcExitPre)
        }
        $bullets += "refs $Issue"
        if ($bullets.Count -gt 3) {
            throw [GcException]::new('body plus issue ref is capped at 3 bullets (§3)', $script:GcExitPre)
        }
    }

    Assert-GcIdentity -Root $root

    if ($All) {
        Invoke-GcGit -Root $root -Argv @('add','-A')
        Write-GcOk 'staged all changes (-All)'
    }

    # last gate: the staged diff (ceremony §3) — content plus secret scan
    if (-not (Get-GcStagedNames -Root $root)) {
        throw [GcException]::new('nothing staged — run gc-stage with the paths, or pass -All', $script:GcExitPre)
    }
    Stop-GcOnSecrets -Root $root
    $stat = Get-GcGit -Root $root -Argv @('diff','--cached','--stat')
    Write-GcInfo 'staged diff (review before the commit lands):'
    Write-GcNote (($stat -join "`n"))

    $argv = @('commit','-m',$subject)
    if ($bullets.Count -gt 0) { $argv += @('-m', ($bullets -join "`n")) }
    Invoke-GcGit -Root $root -Argv $argv

    $log = (Get-GcGit -Root $root -Argv @('log','-1','--format=%h%x09%s') | Select-Object -First 1).Trim()
    $files = @(Get-GcGit -Root $root -Argv @('show','--format=','--name-only','-r','HEAD') | Where-Object { $_ }).Count
    Write-GcOk "committed: $log"
    Write-GcResult -Props @{ sha = ($log -split "`t")[0]; subject = ($log -split "`t")[1]; files = $files; action = 'committed' }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}
