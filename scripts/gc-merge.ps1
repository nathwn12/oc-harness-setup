#Requires -Version 7.0
<#
.SYNOPSIS
  Merge a branch through its PR — squash by default, only when the checks are
  green (main stays green, §6). Then delete the branch, local and remote, and
  prune. No human in the middle.

.DESCRIPTION
  git-ceremony §6 as a script. Refuses to merge while any check is failing or
  (beyond -CheckTimeoutSec) still pending; a PR whose status rollup shows NO
  checks proceeds with a warning — required-check enforcement is gh's own
  backstop (gh refuses to merge a blocked PR). If the PR is a draft it is
  marked ready first. The merge is verified (state == MERGED) before ANY
  cleanup; the local branch is deleted only when it provably matches the
  merged PR head (no guesswork, no unguarded -D), and the remote branch only
  when the remote ref still exists. Re-runs after a completed merge are clean
  no-ops that finish leftover cleanup (self-healing, idempotent).

  Repo rules win: repos that dictate merge commits or rebase get -Mode
  merge|rebase; a repo's own documented convention always beats this script.

.PARAMETER Branch
  Head branch to merge. Defaults to the current branch. Ref-shaped and
  validated (a leading dash is rejected outright).
.PARAMETER PR
  Explicit PR number; defaults to the open PR for the branch.
.PARAMETER Mode
  Merge method: squash (default), merge, or rebase.
.PARAMETER CheckTimeoutSec
  How long to wait for pending checks before refusing (default 300; 0 = do
  not wait — refuse while pending).
.PARAMETER NoDeleteBranch
  Keep the branch after merge (ceremony deletes it; repos that want it kept
  pass this).
.PARAMETER RepoRoot
  Repository path (defaults to the current directory); git pinned with git -C,
  gh run from the repo root.
.PARAMETER Detailed
  Restore the step narration, ok/info lines, and raw git/gh relay the terse
  default hides. Never affects the RESULT line, warnings, failures, or the
  security/remediation lines.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -File scripts\gc-merge.ps1

.EXAMPLE
  pwsh -File scripts\gc-merge.ps1 -Mode merge -CheckTimeoutSec 600
#>
param(
    [string]$Branch,
    [int]$PR,
    [ValidateSet('squash','merge','rebase')][string]$Mode = 'squash',
    [int]$CheckTimeoutSec = 300,
    [switch]$AllowNoChecks,
    [switch]$NoDeleteBranch,
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Detailed,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gc.core.ps1')
if ($Detailed) { $script:GcQuiet = $false }
if ($Quiet) { $script:GcQuiet = $true }

function Get-GcChecksRollup {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$Number)
    $raw = @(Get-GcGhJson -Root $Root -Argv @('pr','view',"$Number",'--json','statusCheckRollup','--jq','.statusCheckRollup'))
    if (-not $raw -or ($raw.Count -eq 1 -and $null -eq $raw[0])) { return @() }
    return $raw
}

function Get-GcChecksVerdict {
    <#
    'pass' | 'pending' | 'fail' | 'unknown'. Handles BOTH rollup shapes under
    StrictMode: CheckRun items (status/conclusion) and legacy StatusContext
    items (state only) — property access is guarded via PSObject.Properties so
    a missing property can never throw. 'unknown' = rollup empty (no checks
    reported — gh required-check enforcement remains the backstop).
    #>
    param($Rollup)
    if (-not $Rollup) { return 'unknown' }
    foreach ($c in $Rollup) {
        if ($null -eq $c) { continue }   # a null rollup item must not crash the loop
        if ($c.PSObject.Properties['status'] -and $c.status -in @('QUEUED','IN_PROGRESS')) { return 'pending' }
        if ($c.PSObject.Properties['state'] -and $c.state -in @('FAILURE','ERROR')) { return 'fail' }
        if ($c.PSObject.Properties['state'] -and $c.state -in @('PENDING','EXPECTED')) { return 'pending' }
        if ($c.PSObject.Properties['conclusion'] -and $c.conclusion -and $c.conclusion -notin @('SUCCESS','NEUTRAL','SKIPPED')) { return 'fail' }
    }
    return 'pass'
}

try {
    $root = Resolve-GcRoot -Path $RepoRoot
    Write-GcInfo "repo: $root"

    $head = if ($Branch) { $Branch } else { Get-GcCurrentBranch -Root $root }
    if ($Branch) { Assert-GcRefValue -Name '-Branch' -Value $head }
    $default = Get-GcDefaultBranch -Root $root
    if ($head -eq $default) {
        throw [GcException]::new("you are on the default branch ($default) — nothing to merge; pass -Branch <head> to finish an already-merged PR or gc-branch a new unit of work", $script:GcExitPre)
    }

    Assert-GcGh

    # resolve the PR ONCE — statusCheckRollup rides along, so the checks verdict
    # costs no second gh call (was: 2x pr view, plus a re-poll per wait tick)
    $prFields = 'number,state,headRefName,headRefOid,baseRefName,isDraft,mergeCommit,statusCheckRollup'
    $prInfo = $null
    if ($PR) {
        try { $prInfo = Get-GcGhJson -Root $root -Argv @('pr','view',"$PR",'--json',$prFields) }
        catch { throw [GcException]::new("no PR #$PR — $($_.Exception.Message)", $script:GcExitPre) }
        if ($prInfo.headRefName -ne $head) {
            throw [GcException]::new("PR #$PR is for branch $($prInfo.headRefName), not $head", $script:GcExitPre)
        }
    } else {
        try {
            $prInfo = Get-GcGhJson -Root $root -Argv @('pr','view',$head,'--json',$prFields)
        } catch {
            if ($_.Exception.Message -match 'no pull requests found') {
                throw [GcException]::new("no open PR for $head — create one with gc-pr", $script:GcExitPre)
            }
            throw
        }
    }

    $n = $prInfo.number
    $base = $prInfo.baseRefName
    Assert-GcRefValue -Name 'base branch' -Value $base   # hostile gh data is validated too
    if ($base -ne $default) {
        throw [GcException]::new("PR #$n targets base '$base', not the default branch '$default' — mis-targeted PR; retarget it (gh pr edit --base) or merge by hand", $script:GcExitPre)
    }
    Write-GcInfo "PR #$n : $head -> $base (state $($prInfo.state))"

    if ($prInfo.state -eq 'MERGED') {
        Write-GcOk "PR #$n already merged — finishing leftover cleanup"
        # truthful method label comes from the merge commit itself (gh exposes
        # no message) — resolved after the cleanup fetches it (freshMerged=false).
        $mergedSha = if ($prInfo.mergeCommit) { $prInfo.mergeCommit.oid } else { '' }
        $freshMerged = $false
        # fall through to cleanup only
    } elseif ($prInfo.state -eq 'CLOSED') {
        throw [GcException]::new("PR #$n is closed — re-open or create a new PR before merging", $script:GcExitPre)
    } else {
        # main stays green (§6): refuse failing, wait bounded for pending
        $verdict = Get-GcChecksVerdict -Rollup @($prInfo.statusCheckRollup | Where-Object { $null -ne $_ })
        if ($verdict -eq 'fail') {
            throw [GcException]::new('checks are FAILING — main stays green; fix, push, and re-run', $script:GcExitPre)
        }
        if ($verdict -eq 'unknown' -and -not $AllowNoChecks) {
            throw [GcException]::new('no checks visible in the status rollup — refusing; re-run with -AllowNoChecks only when the repository intentionally has no CI checks', $script:GcExitPre)
        }
        if ($verdict -eq 'unknown') {
            Write-GcWarn 'no checks visible; proceeding only because -AllowNoChecks was explicit'
        }
        if ($verdict -eq 'pending') {
            if ($CheckTimeoutSec -le 0) {
                throw [GcException]::new('checks still pending and -CheckTimeoutSec 0 — re-run gc-merge when they finish', $script:GcExitPre)
            }
            # ungated: with chatter off a silent 15s-poll wait looked hung for up
            # to 5 minutes. One phase line + one per tick, no change to interval.
            Write-GcNotice "checks pending — waiting up to ${CheckTimeoutSec}s (poll every 15s)"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($verdict -eq 'pending' -and $sw.Elapsed.TotalSeconds -lt $CheckTimeoutSec) {
                Start-Sleep -Seconds 15
                $verdict = Get-GcChecksVerdict -Rollup (Get-GcChecksRollup -Root $root -Number $n)
                if ($verdict -eq 'pending') { Write-GcNotice "  still waiting: $([int]$sw.Elapsed.TotalSeconds)s elapsed of ${CheckTimeoutSec}s" }
            }
            if ($verdict -eq 'fail') {
                throw [GcException]::new('checks turned FAILING while waiting — main stays green; fix, push, and re-run', $script:GcExitPre)
            }
            if ($verdict -eq 'pending') {
                throw [GcException]::new("checks still pending after ${CheckTimeoutSec}s — re-run gc-merge when they finish", $script:GcExitPre)
            }
        }
        if ($prInfo.isDraft) {
            Invoke-GcGh -Root $root -Argv @('pr','ready',"$n")
            Write-GcInfo "PR #$n marked ready"
        }
        $method = Convert-GcMergeMode -Mode $Mode
        Write-GcInfo "merging PR #$n with $Mode..."
        Invoke-GcGh -Root $root -Argv @('pr','merge',"$n",$method)
        $st = Get-GcGhJson -Root $root -Argv @('pr','view',"$n",'--json','state,mergeStateStatus,mergeCommit')
        if ($st.state -ne 'MERGED') {
            throw [GcException]::new("merge did not land — gh reports mergeStateStatus '$($st.mergeStateStatus)' — likely conflicts: rebase on $default, gc-push -Force (lease), re-run", $script:GcExitPre)
        }
        $mergedSha = $st.mergeCommit.oid
        $freshMerged = $true
        Write-GcOk "PR #$n merged ($Mode) @ $mergedSha"
    }

    # ----- cleanup: branch deletion, local and remote, verified ------------
    $deletedLocal = $false; $deletedRemote = $false; $syncSkipped = $false
    $cleanupWarn = $null; $keptWarn = $null
    if (-not $NoDeleteBranch) {
        try {
            Invoke-GcGit -Root $root -Argv @('switch',$base)   # cannot delete the branch we are on
            if ((Test-GcRef -Root $root -Ref "refs/heads/$head") -and $head -ne (Get-GcCurrentBranch -Root $root)) {
                $localNow = (Get-GcGit -Root $root -Argv @('rev-parse',$head) | Select-Object -First 1).Trim()
                if ($localNow -eq $prInfo.headRefOid) {
                    Invoke-GcGit -Root $root -Argv @('branch','-D',$head)
                    $deletedLocal = $true
                } else {
                    $keptWarn = "local $head moved after merge ($localNow != merged $($prInfo.headRefOid)) — left intact (name re-used?)"
                }
            }
            $remote = $null
            try { $remote = Get-GcRemote -Root $root } catch { }
            if ($remote) {
                $remoteHeads = @(Get-GcGit -Root $root -Argv @('ls-remote','--heads',$remote,$head))
                if ($remoteHeads) {
                    # remote delete is oid-gated like the local one: a post-merge
                    # push or a re-used name must never be wiped.
                    $remoteSha = ($remoteHeads[0] -split "`t")[0].Trim()
                    if ($remoteSha -eq $prInfo.headRefOid) {
                        Invoke-GcGit -Root $root -Argv @('push',$remote,'--delete',$head)
                        $deletedRemote = $true
                    } else {
                        $keptWarn = "remote $head moved after merge ($remoteSha != merged $($prInfo.headRefOid)) — remote left intact"
                    }
                }
            }
            $remotes = @(Get-GcGit -Root $root -Argv @('remote'))
            if ($remotes -contains 'origin') {
                Invoke-GcGit -Root $root -Argv @('fetch','--prune','origin')
            }
        } catch {
            $cleanupWarn = "cleanup incomplete: $($_.Exception.Message)"
        }
        # post-merge sync is best-effort: a dirty tree or stray untracked files
        # must never fail an already-landed merge — warn instead, self-heal later.
        try {
            $null = Sync-GcDefaultBranch -Root $root -Default $base -CurrentBranch (Get-GcCurrentBranch -Root $root)
        } catch {
            $syncSkipped = $true
            Write-GcWarn "post-merge sync skipped: $($_.Exception.Message)"
        }
        if ($cleanupWarn) { Write-GcWarn $cleanupWarn }
        if ($keptWarn) { Write-GcWarn $keptWarn }
    }

    # truthful merge-method label: our own run knows it; an already-merged PR's
    # method is read from the merge commit itself (now fetched by the cleanup)
    $modeOut = if ($freshMerged) { $Mode } else { Get-GcMergedMethod -Root $root -Sha $mergedSha }

    $props = @{
        number = $n
        mode = $modeOut
        sha = $mergedSha
        branch = $head
        branch_deleted_local = $deletedLocal
        branch_deleted_remote = $deletedRemote
        sync_skipped = $syncSkipped
    }
    if ($keptWarn) { $props.branch_kept = $keptWarn }
    if ($cleanupWarn) {
        $props.cleanup = $cleanupWarn
        Write-GcFail "merged but cleanup incomplete: $cleanupWarn — re-run gc-merge to finish it"
        Write-GcResult -Code $script:GcExitFail -Props $props
    }
    Write-GcOk "PR #$n merged ($modeOut) — branch cleanup done"
    Write-GcResult -Props $props
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}
