#Requires -Version 7.0
<#
.SYNOPSIS
  Push the current branch. Self-healing upstream: a branch with no upstream is
  pushed with -u automatically; a rejected push needs a rebase, or -Force
  which retries with --force-with-lease only.

.DESCRIPTION
  git-ceremony §4/§6 push rails as a script. Always pins git -C and pushes an
  explicit ref — never the ambient branch. Force-push is lease-only and is
  REFUSED outright on the default branch (never force-push a shared branch).
  Local-only repos (no remote) fail cleanly with exit 2.

  Repo rules win: if the repo's branch protection dictates push behavior,
  follow that instead of this script.

.PARAMETER Remote
  Remote name; defaults to origin, else the sole remote when unambiguous.
.PARAMETER Force
  Retry a rejected push with --force-with-lease — never plain --force. Only
  meaningful on your own PR branch.
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
  pwsh -File scripts\gc-push.ps1

.EXAMPLE
  pwsh -File scripts\gc-push.ps1 -Force
#>
param(
    [string]$Remote,
    [switch]$Force,
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

    # push needs the branch name and nothing else — a targeted rev-parse, not a
    # full worktree walk (the walk cost scales with the repo; this is the path
    # the old twelve-call preamble kept cheap).
    $cur = Get-GcCurrentBranch -Root $root -Targeted
    $default = Get-GcDefaultBranch -Root $root
    if ($Force) {
        if ($cur -eq $default) {
            throw [GcException]::new("refusing to force-push the default branch ($default) — §6: never force-push a shared branch", $script:GcExitPre)
        }
        # §6: force-push only your own PR branch — a type/slug branch.
        if ($cur -cnotmatch '^[a-z]+(/[a-z0-9-]+)+$') {
            throw [GcException]::new("force-push only your own PR branch (§6) — '$cur' is not a <type>/<slug> branch; never force a shared branch", $script:GcExitPre)
        }
        Write-GcWarn 'lease-only: protects against a stale tracking ref, but a fresh fetch right after a teammate push can defeat it — verify you own this branch'
    }

    $remote = if ($Remote) {
        if (-not (@(Get-GcGit -Root $root -Argv @('remote')) -contains $Remote)) {
            throw [GcException]::new("remote '$Remote' does not exist", $script:GcExitPre)
        }
        $Remote
    } else { Get-GcRemote -Root $root }

    $hasUpstream = $true
    try { Get-GcGit -Root $root -Argv @('rev-parse','--abbrev-ref','--symbolic-full-name',"${cur}@{upstream}") | Out-Null } catch { $hasUpstream = $false }

    $argv = if ($hasUpstream) { @('push',$remote,$cur) } else { @('push','-u',$remote,$cur) }
    $FAILED_REMOTE_RE = 'rejected|non-fast-forward|fetch first|not fast-forward|stale info'
    $usedForce = $false
    try {
        Invoke-GcGit -Root $root -Argv $argv
    } catch {
        $isRemoteReject = $_.Exception.Message -match $FAILED_REMOTE_RE
        if ($isRemoteReject -and $Force) {
            Write-GcWarn 'push rejected — retrying with --force-with-lease'
            Invoke-GcGit -Root $root -Argv @('push','--force-with-lease',$remote,$cur)
            $usedForce = $true
        } elseif ($isRemoteReject) {
            throw [GcException]::new("push rejected (non-fast-forward) — rebase on $remote/$cur first, or retry with -Force (--force-with-lease only)", $script:GcExitPre)
        } else {
            throw   # network/auth/other — original error
        }
    }

    $sha = (Get-GcGit -Root $root -Argv @('rev-parse',$cur) | Select-Object -First 1).Trim()
    $short = (Get-GcGit -Root $root -Argv @('rev-parse','--short',$cur) | Select-Object -First 1).Trim()
    $action = if ($usedForce) { 'forced' } elseif (-not $hasUpstream) { 'pushed-with-upstream' } else { 'pushed' }
    Write-GcOk "pushed $cur -> $remote/$cur @ $short"
    Write-GcResult -Props @{ branch = $cur; remote = $remote; sha = $sha; action = $action }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}