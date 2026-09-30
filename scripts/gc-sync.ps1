#Requires -Version 7.0
<#
.SYNOPSIS
  Sync the default branch to its remote head: fetch origin, then fast-forward
  only. Standalone ceremony §1 — use it at session start and before a rebase.

.DESCRIPTION
  The pull step of the ceremony as a stand-alone script. Fetch + fast-forward
  the default branch; never manufactures a merge; refuses to switch branches
  when the tree is dirty (commit or stash first). A repo with no origin is a
  clean no-op ('skipped-local'). Leaves you on the default branch when a
  fast-forward was needed, exactly where you were otherwise.

  Repo rules win: if the repo documents its own update convention, follow
  that instead of this script.

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
  pwsh -File scripts\gc-sync.ps1
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
    Write-GcInfo "repo: $root"

    $default = Get-GcDefaultBranch -Root $root
    # branch only — targeted rev-parse, no worktree walk (the state this reads
    # would be dropped by the fetch in Sync-GcDefaultBranch anyway).
    $cur = try { Get-GcCurrentBranch -Root $root -Targeted } catch { $null }
    if (-not (Test-GcRef -Root $root -Ref "refs/heads/$default")) {
        Write-GcOk "default branch '$default' is unborn (no commits) — nothing to sync"
        Write-GcResult -Props @{ default = $default; action = 'unborn' }
    }
    $action = Sync-GcDefaultBranch -Root $root -Default $default -CurrentBranch $cur

    $sha = (Get-GcGit -Root $root -Argv @('rev-parse','--short',"$default") | Select-Object -First 1).Trim()
    Write-GcOk "default branch ($default) @ $sha — sync: $action"
    Write-GcResult -Props @{ default = $default; sha = $sha; action = $action }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}