#Requires -Version 7.0
<#
.SYNOPSIS
  Start a unit of work from truth: sync the default branch, then create <type>/<slug>.

.DESCRIPTION
  git-ceremony §1-§2 as a script. Fetches origin, fast-forwards the default
  branch (never manufactures a merge, refuses to branch from a stale or
  diverged default), validates the branch name, and creates the branch from the
  synced default HEAD. Idempotent: already on the branch is a no-op; -Reuse
  switches to an existing branch instead of failing.

  Dynamic content in (type + slug), fixed ceremony out. Repo rules win: if the
  repo documents its own convention, follow that instead of this script.

.PARAMETER Type
  One of: feat, fix, chore, docs, refactor, test, perf, hotfix, wt.
.PARAMETER Slug
  Kebab-case 2-5 words, letters/digits only; describes the change, not the
  author or the date.
.PARAMETER Branch
  Full <type>/<slug> name; alternative to passing Type + Slug.
.PARAMETER Reuse
  Switch to the branch when it already exists instead of failing.
.PARAMETER Delete
  Delete a branch instead of creating one: local delete, plus remote when
  -DeleteRemote is given. Never the default branch, never the current branch,
  never with a dirty tree; an unmerged branch is refused without -Force
  (squash-merged branches legitimately need -Force — the commit lives in the
  default branch, not in branch ancestry).
.PARAMETER DeleteRemote
  With -Delete: also delete <branch> on the remote (origin by default,
  verified to exist first — never a blind push --delete).
.PARAMETER Force
  With -Delete: allow deleting an unmerged branch (its commits are not in the
  default branch's history — loud warning).
.PARAMETER SkipSync
  Skip fetch + fast-forward of the default branch. Only when you just synced;
  the ceremony default is to sync.
.PARAMETER RepoRoot
  Repository path (defaults to the current directory). Every git call is pinned
  with git -C, so the ambient shell cwd never matters (worktree rails, §10).
.PARAMETER Detailed
  Restore the step narration, ok/info lines, and raw git/gh relay the terse
  default hides. Never affects the RESULT line, warnings, failures, or the
  security/remediation lines.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -File scripts\gc-branch.ps1 -Type feat -Slug token-refresh

.EXAMPLE
  pwsh -File scripts\gc-branch.ps1 -Branch 'fix/login-timeout' -Reuse

.EXAMPLE
  pwsh -File scripts\gc-branch.ps1 -Delete 'feat/token-refresh' -DeleteRemote -Force
#>
param(
    [string]$Type,
    [string]$Slug,
    [string]$Branch,
    [string]$Delete,
    [switch]$DeleteRemote,
    [switch]$Force,
    [switch]$Reuse,
    [switch]$SkipSync,
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
    $default = Get-GcDefaultBranch -Root $root
    Write-GcInfo "default branch: $default"
    $cur = try { Get-GcCurrentBranch -Root $root } catch { $null }

    # -------- delete verb ---------------------------------------------------
    if ($Delete) {
        $del = $Delete
        Assert-GcRefValue -Name '-Delete' -Value $del
        if ($del -eq $default) {
            throw [GcException]::new("never delete the default branch ($default)", $script:GcExitPre)
        }
        if ($del -eq $cur) {
            throw [GcException]::new("cannot delete the current branch — switch away first (gc-branch -Reuse <branch>)", $script:GcExitPre)
        }
        $localExists = Test-GcRef -Root $root -Ref "refs/heads/$del"
        $remote = $null
        if ($DeleteRemote) {
            try { $remote = Get-GcRemote -Root $root } catch { throw [GcException]::new("no remote — cannot delete $del remotely", $script:GcExitPre) }
        }
        $remoteExists = $false
        if ($remote) { $remoteExists = [bool]@(Get-GcGit -Root $root -Argv @('ls-remote','--heads',$remote,$del)) }
        if (-not $localExists -and -not $remoteExists) {
            throw [GcException]::new("branch '$del' does not exist (local or $remote)", $script:GcExitPre)
        }
        if (-not (Test-GcCleanTree -Root $root)) {
            throw [GcException]::new('tree is dirty — commit or stash before deleting a branch', $script:GcExitPre)
        }
        $deletedLocal = $false; $deletedRemote = $false
        $localShaBefore = $null
        if ($localExists) {
            $merged = $false
            try { Get-GcGit -Root $root -Argv @('merge-base','--is-ancestor',$del,$default) | Out-Null; $merged = $true } catch { }
            if (-not $merged -and -not $Force) {
                throw [GcException]::new("branch '$del' is unmerged into $default — deletion discards its commits; pass -Force to delete anyway (squash-merged branches legitimately need -Force: the commit lives in $default, not in branch ancestry)", $script:GcExitPre)
            }
            if (-not $merged -and $Force) { Write-GcWarn "deleting unmerged branch '$del' with -Force — its commits are NOT in $default's history" }
            $localShaBefore = (Get-GcGit -Root $root -Argv @('rev-parse',$del) | Select-Object -First 1).Trim()
            Invoke-GcGit -Root $root -Argv @('branch', $(if ($merged) { '-d' } else { '-D' }), $del)
            $deletedLocal = $true
        }
        if ($remote -and $remoteExists) {
            # remote gate mirrors the local one (adv-L1): fetch, then oid-compare
            # when local existed, and the merged/-Force gate when remote-only.
            Invoke-GcGit -Root $root -Argv @('fetch',$remote)
            $remoteFetched = Test-GcRef -Root $root -Ref "refs/remotes/$remote/$del"
            if ($remoteFetched) {
                if ($localShaBefore) {
                    $remoteSha = (Get-GcGit -Root $root -Argv @('rev-parse',"$remote/$del") | Select-Object -First 1).Trim()
                    if ($remoteSha -ne $localShaBefore) {
                        throw [GcException]::new("remote $del ($remoteSha) differs from local ($localShaBefore) — verify before deleting", $script:GcExitPre)
                    }
                } else {
                    $remoteMerged = $false
                    try { Get-GcGit -Root $root -Argv @('merge-base','--is-ancestor',"$remote/$del",$default) | Out-Null; $remoteMerged = $true } catch { }
                    if (-not $remoteMerged -and -not $Force) {
                        throw [GcException]::new("remote branch '$del' is unmerged into $default — pass -Force to delete it", $script:GcExitPre)
                    }
                    if (-not $remoteMerged -and $Force) { Write-GcWarn "deleting unmerged remote branch '$del' with -Force" }
                }
                Invoke-GcGit -Root $root -Argv @('push',$remote,'--delete',$del)
                $deletedRemote = $true
            }
        }
        Write-GcOk "deleted $del (local=$deletedLocal remote=$deletedRemote)"
        Write-GcResult -Props @{ branch = $del; deleted_local = $deletedLocal; deleted_remote = $deletedRemote; force = [bool]$Force; action = 'deleted' }
    }

    $name = if ($Branch) { $Branch }
            elseif ($Type -and $Slug) { "$Type/$Slug" }
            else { throw [GcException]::new('give -Branch ''<type>/<slug>'' or -Type + -Slug', $script:GcExitPre) }
    if (-not (Test-GcBranchName -Branch $name)) {
        throw [GcException]::new("branch name rejected: $name", $script:GcExitPre)
    }
    if ($cur -eq $name) {
        Write-GcOk "already on $name"
        Write-GcResult -Props @{ branch = $name; action = 'no-op' }
    }

    $exists = Test-GcRef -Root $root -Ref "refs/heads/$name"
    if (-not $exists -and $Reuse) {
        throw [GcException]::new("branch '$name' does not exist — -Reuse cannot create it; never reuse a merged branch name (§2); gc-branch a fresh <type>/<slug>", $script:GcExitPre)
    }
    if ($exists -and -not $Reuse) {
        throw [GcException]::new("branch '$name' exists — pass -Reuse to switch to it", $script:GcExitPre)
    }
    if ($exists) {
        Invoke-GcGit -Root $root -Argv @('switch',$name)
        Write-GcOk "switched to existing $name"
        Write-GcResult -Props @{ branch = $name; action = 'reused' }
    }

    if (-not $SkipSync) {
        $null = Sync-GcDefaultBranch -Root $root -Default $default -CurrentBranch $cur
    } else {
        Write-GcInfo 'sync skipped (-SkipSync)'
    }

    if (Test-GcRef -Root $root -Ref "refs/heads/$default") {
        Invoke-GcGit -Root $root -Argv @('switch','-c',$name,$default)
    } else {
        # unborn default (fresh repo, zero commits): create from current HEAD
        Invoke-GcGit -Root $root -Argv @('switch','-c',$name)
        Write-GcWarn "default branch '$default' is unborn — created $name from the current unborn HEAD"
    }

    $sha = (Get-GcGit -Root $root -Argv @('rev-parse','--short',"$name") | Select-Object -First 1).Trim()
    Write-GcOk "created $name from $default @ $sha"
    Write-GcResult -Props @{ branch = $name; base = $default; base_sha = $sha; action = 'created' }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}