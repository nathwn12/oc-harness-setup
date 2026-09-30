#Requires -Version 7.0
<#
.SYNOPSIS
  One-shot ceremony-aware repo snapshot: branch, default, staleness, index
  state, upstream, remote, gh, open PR, checks. Read-only — an agent's first
  call in an unfamiliar repo.

.DESCRIPTION
  Returns a single RESULT: <json> with everything an agent needs to decide the
  next ceremony step. Read-only: no fetch, no mutation. Every gh-backed field
  is guarded — an unauthenticated or absent gh degrades to gh_authed=false,
  never a failure.

  Fields: repo, branch, branch_type, detached, default, clean, staged,
  unstaged, conflicts, untracked, upstream, ahead, behind, remote, gh_authed,
  pr (number or null), pr_state, pr_draft, pr_checks
  ('pass'|'pending'|'fail'|null), rebase_in_progress. The branch value is
  '(detached)' when HEAD is detached.

  Repo rules win: this is a read-only snapshot; a repo's own convention still
  governs how git work happens there.

.PARAMETER RepoRoot
  Repository path (defaults to the current directory).
.PARAMETER Detailed
  Restore the step narration, ok/info lines, and raw git/gh relay the terse
  default hides. Never affects the RESULT line, warnings, failures, or the
  security/remediation lines.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -File scripts\gc-status.ps1
#>
param(
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

    $branch = try { Get-GcCurrentBranch -Root $root } catch { '(detached)' }
    $detached = ($branch -eq '(detached)')
    $btype = if (-not $detached -and $branch -match '^([a-z]+)/') { $Matches[1] } else { $null }
    $default = Get-GcDefaultBranch -Root $root

    # one porcelain v2 call answers clean / staged / unstaged / conflicts /
    # untracked and upstream+ahead/behind (was: status + diff --cached +
    # rev-parse + 2x rev-list)
    $state = Get-GcRepoState -Root $root
    $staged = $state.Staged.Count
    $untracked = $state.Untracked
    $unstaged = $state.Unstaged
    $conflicts = $state.Conflicts
    $upstream = $state.Upstream
    $ahead = $state.Ahead
    $behind = $state.Behind

    $remote = $null
    try { $remote = Get-GcRemote -Root $root } catch { }

    $rebaseInProgress = Test-GcRebaseInProgress -Root $root

    # gh-backed fields — guarded, never fatal. The retired `gh auth status`
    # pre-flight made this three calls (a probe + 2x pr view); one call now
    # answers the whole PR question and its own failure is the auth probe.
    $ghAuthed = $false; $prNumber = $null; $prState = $null; $prDraft = $null; $prChecks = $null
    if ($remote -and -not $detached -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        try {
            $pr = Get-GcGhJson -Root $root -Argv @('pr','view',$branch,'--json','number,state,isDraft,statusCheckRollup')
            $ghAuthed = $true
            $prNumber = $pr.number; $prState = $pr.state; $prDraft = $pr.isDraft
            $rollup = @($pr.statusCheckRollup | Where-Object { $null -ne $_ })
            if ($rollup.Count -gt 0) {
                $verdicts = @($rollup | ForEach-Object {
                    if ($_.PSObject.Properties['status'] -and $_.status -in @('QUEUED','IN_PROGRESS')) { 'pending' }
                    elseif ($_.PSObject.Properties['state'] -and $_.state -in @('FAILURE','ERROR')) { 'fail' }
                    elseif ($_.PSObject.Properties['state'] -and $_.state -in @('PENDING','EXPECTED')) { 'pending' }
                    elseif ($_.PSObject.Properties['conclusion'] -and $_.conclusion -and $_.conclusion -notin @('SUCCESS','NEUTRAL','SKIPPED')) { 'fail' }
                    else { 'pass' }
                })
                $prChecks = if ($verdicts -contains 'fail') { 'fail' } elseif ($verdicts -contains 'pending') { 'pending' } else { 'pass' }
            }
        } catch {
            # not logged in → gh_authed=false; any other failure (usually "no pull
            # requests found") means authenticated with no open PR for the branch
            $ghAuthed = -not ($_.Exception.Message -match 'gh auth login')
        }
    }

    Write-GcResult -Props @{
        repo = $root
        branch = $branch
        branch_type = $btype
        detached = $detached
        default = $default
        clean = $state.Clean
        staged = $staged
        unstaged = $unstaged
        conflicts = $conflicts
        untracked = $untracked
        upstream = $upstream
        ahead = $ahead
        behind = $behind
        remote = $remote
        gh_authed = $ghAuthed
        pr = $prNumber
        pr_state = $prState
        pr_draft = $prDraft
        pr_checks = $prChecks
        rebase_in_progress = $rebaseInProgress
    }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}