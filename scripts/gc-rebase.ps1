#Requires -Version 7.0
<#
.SYNOPSIS
  Rebase the current branch onto a target ref (default: the synced default
  branch). Conflict-aware: a conflict leaves the rebase in progress and exits
  2 (agent-fixable stop) with state=conflict; the agent resolves, then
  -Continue; or -Abort to roll back cleanly. No editor, no prompts, no human
  in the middle.

.DESCRIPTION
  The rebase rail of ceremony §6 as a script: if main moved, rebase your
  branch on it and resolve THERE — never on main. This script:
    - syncs the default branch first (-NoSync to skip; the base is then whatever
      the target ref points at),
    - runs `git rebase <target>` — a conflict stops it in place (never aborts
      on its own), exits 2 with state=conflict and clear next steps; -Onto is
      ref-validated (a leading dash is rejected, no option injection),
    - -Continue resumes after resolution (GIT_EDITOR forced to true so a
      pending editor prompt can never block an agent),
    - -Abort returns to the pre-rebase branch exactly — refused while resolved
      files exist, because abort would silently discard them,
    - refuses to run while another rebase is in progress (use -Continue/-Abort).
  After a successful rebase, push with gc-push -Force (--force-with-lease).
  Repo rules win: if the repo documents its own convention, follow that
  instead of this script.

.PARAMETER Onto
  Rebase target ref. Defaults to the repo default branch.
.PARAMETER Continue
  Resume a stopped rebase after conflict resolution.
.PARAMETER Abort
  Cancel a stopped rebase and restore the pre-rebase state.
.PARAMETER NoSync
  Skip the default-branch sync before rebasing.
.PARAMETER RepoRoot
  Repository path (defaults to the current directory); git is always pinned
  with git -C.
.PARAMETER Detailed
  Restore the step narration, ok/info lines, and raw git/gh relay the terse
  default hides. Never affects the RESULT line, warnings, failures, or the
  security/remediation lines.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -File scripts\gc-rebase.ps1

.EXAMPLE
  pwsh -File scripts\gc-rebase.ps1 -Onto origin/main
#>
param(
    [string]$Onto,
    [switch]$Continue,
    [switch]$Abort,
    [switch]$NoSync,
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

    if ($Continue -and $Abort) {
        throw [GcException]::new('-Continue and -Abort are mutually exclusive', $script:GcExitPre)
    }

    $inProgress = Test-GcRebaseInProgress -Root $root

    if ($Abort) {
        # a rebase runs on a DETACHED HEAD, so no branch insight is needed here
        if (-not $inProgress) { throw [GcException]::new('no rebase in progress — nothing to abort', $script:GcExitPre) }
        # M2: never discard resolution work silently — abort is refused while
        # resolved/staged changes exist beyond the unmerged markers, AND while
        # any unmerged path's WORKTREE copy no longer contains conflict markers
        # (unstaged manual resolution is invisible to porcelain).
        $unmergedPat = '^(UU|AA|DD|AU|UA|DU|UD) '
        $resolvedWork = @(Get-GcGit -Root $root -Argv @('status','--porcelain') |
            ForEach-Object { "$_" } | Where-Object { $_ -cnotmatch $unmergedPat -and $_ -cnotmatch '^\?\?' })
        $unmergedPaths = @()
        try { $unmergedPaths = Get-GcGit -Root $root -Argv @('diff','--name-only','--diff-filter=U') } catch { }
        $editedUnmerged = @()
        foreach ($p in $unmergedPaths) {
            $abs = Join-Path $root $p
            if (-not (Test-Path -LiteralPath $abs)) { continue }
            try { $text = [System.IO.File]::ReadAllText($abs) } catch { continue }
            if ($text -notmatch '<<<<<<<') { $editedUnmerged += $p }   # markers gone → real resolution
        }
        if (@($resolvedWork).Count -gt 0 -or @($editedUnmerged).Count -gt 0) {
            $why = @()
            if (@($resolvedWork).Count -gt 0) { $why += "$($resolvedWork.Count) resolved file(s) [$($resolvedWork -join ', ')]" }
            if (@($editedUnmerged).Count -gt 0) { $why += "unstaged manual resolution in [$($editedUnmerged -join ', ')]" }
            throw [GcException]::new("abort would discard: $($why -join '; ') — abort refused; resolve fully and -Continue, or reset those paths yourself", $script:GcExitPre)
        }
        Invoke-GcGit -Root $root -Argv @('rebase','--abort')
        $b = Get-GcCurrentBranch -Root $root
        Write-GcOk "rebase aborted — back on $b, no resolutions were lost (nothing was resolved)"
        Write-GcResult -Props @{ branch = $b; action = 'aborted' }
    }

    if ($Continue) {
        if (-not $inProgress) { throw [GcException]::new('no rebase in progress — nothing to continue', $script:GcExitPre) }
        Assert-GcIdentity -Root $root
        # marker gate: staged or worktree conflict markers must never be
        # committed by --continue (battery live finding: markers were)
        $markers = @()
        try { $markers += Get-GcGit -Root $root -Argv @('grep','-n','-E','^(<<<<<<<|>>>>>>>)( |$)') } catch { }
        try { $markers += Get-GcGit -Root $root -Argv @('grep','-n','--cached','-E','^(<<<<<<<|>>>>>>>)( |$)') } catch { }
        if ($markers) {
            Write-GcFail "conflict markers still present ($(@($markers).Count) hit(s)) — resolve them first"
            Write-GcResult -Code $script:GcExitPre -Props @{ action = 'conflict'; message = 'conflict markers still present — resolve them, then gc-rebase -Continue again, or gc-rebase -Abort' }
        }
        $env:GIT_EDITOR = 'true'   # a pending editor prompt must never block an agent
        try {
            Invoke-GcGit -Root $root -Argv @('rebase','--continue')
        } finally { Remove-Item Env:\GIT_EDITOR -ErrorAction SilentlyContinue }
        if (Test-GcRebaseInProgress -Root $root) {
            Write-GcFail 'rebase is still conflicted after --continue'
            Write-GcResult -Code $script:GcExitPre -Props @{ action = 'conflict'; message = 'resolve the remaining conflicts, then gc-rebase -Continue again, or gc-rebase -Abort' }
        }
        $b = Get-GcCurrentBranch -Root $root   # re-attached once the rebase finished
        $sha = (Get-GcGit -Root $root -Argv @('rev-parse','--short','HEAD') | Select-Object -First 1).Trim()
        Write-GcOk "rebase continued — $b @ $sha"
        Write-GcResult -Props @{ branch = $b; sha = $sha; action = 'continued' }
    }

    $cur = Get-GcCurrentBranch -Root $root    # fresh rebase requires a real branch (throws Pre when detached)
    $default = Get-GcDefaultBranch -Root $root
    $onto = if ($Onto) { $Onto } else { $default }
    Assert-GcRefValue -Name '-Onto' -Value $onto   # H1: no option injection into git rebase
    if (-not $NoSync) { $null = Sync-GcDefaultBranch -Root $root -Default $default -CurrentBranch $cur }
    Write-GcInfo "rebasing $cur onto $onto..."

    try {
        Invoke-GcGit -Root $root -Argv @('rebase',$onto)
    } catch {
        if (Test-GcRebaseInProgress -Root $root) {
            # deliberate stop, state preserved — never abort on our own
            Write-GcFail "rebase stopped on a conflict ($($_.Exception.Message))"
            Write-GcResult -Code $script:GcExitPre -Props @{ branch = $cur; onto = $onto; action = 'conflict'; message = 'resolve the conflicts, then gc-rebase -Continue, or gc-rebase -Abort' }
        }
        throw   # not a conflict stop — original error
    }

    $count = (Get-GcGit -Root $root -Argv @('rev-list','--count',"$onto..HEAD") | Select-Object -First 1).Trim()
    $sha = (Get-GcGit -Root $root -Argv @('rev-parse','--short','HEAD') | Select-Object -First 1).Trim()
    Write-GcOk "rebased $cur onto $onto — $count commit(s) replayed, HEAD @ $sha"
    Write-GcResult -Props @{ branch = $cur; onto = $onto; commits = [int]$count; sha = $sha; action = 'rebased' }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}