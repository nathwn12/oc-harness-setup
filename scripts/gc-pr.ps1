#Requires -Version 7.0
<#
.SYNOPSIS
  Open (or update) the pull request with the ceremony body. No editor, no
  prompts, no human in the middle.

.DESCRIPTION
  git-ceremony §4 as a script. Title defaults to the branch head commit subject
  ("Title = the commit subject"). Body is exactly the fixed shape:

      What:  <one line>
      Why:   <one line, omitted when obvious>
      Check: <the single command that proves it, or n/a>
      Risk:  <one line, or low>

  Self-healing: an existing open PR for the branch is updated in place; a
  closed PR is reopened and updated; an already-merged PR is a clean no-op.
  Requires gh (exit 3 when missing or unauthenticated).

  Repo rules win (§0): a repo with its own established PR structure — a
  .github/PULL_REQUEST_TEMPLATE.md, or a consistent sibling-PR style — supplies
  its body verbatim with -BodyFile (or -Body). The fixed shape above is the
  FALLBACK ceremony for a repo that is silent.

.PARAMETER Title
  PR title. Defaults to the branch head commit subject; validated with the
  same rule as the commit subject.
.PARAMETER What
  One line: what this PR does. Required unless -Body/-BodyFile supplies the
  repo's own body.
.PARAMETER Why
  One line: why it exists. Omit (leave empty) when obvious.
.PARAMETER Check
  The single command that proves it. Defaults to n/a.
.PARAMETER Risk
  One line risk. Defaults to low.
.PARAMETER Body
  The repo's own PR body, verbatim, for a repo with an established structure.
  Mutually exclusive with -BodyFile.
.PARAMETER BodyFile
  Path to a file holding the repo's own PR body, used verbatim. A missing,
  unreadable or empty file is a loud stop (exit 2) — never a silent empty body.
.PARAMETER Base
  Base branch. Defaults to the repo default branch.
.PARAMETER Draft
  Open as a draft (ready only when the check passes, §4).
.PARAMETER RepoRoot
  Repository path (defaults to the current directory); gh is run from the repo
  root.
.PARAMETER Detailed
  Restore the step narration, ok/info lines, and raw git/gh relay the terse
  default hides. Never affects the RESULT line, warnings, failures, or the
  security/remediation lines.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -File scripts\gc-pr.ps1 -What 'Cap retry backoff at 30s' `
      -Check 'dotnet test' -Risk 'low' -Draft

.EXAMPLE
  # the repo has its own PR structure (§0): hand it over verbatim
  pwsh -File scripts\gc-pr.ps1 -BodyFile .\.docs\pr-body.md
#>
param(
    [string]$Title,
    [string]$What,
    [string]$Why,
    [string]$Check,
    [string]$Risk,
    [string]$Body,
    [string]$BodyFile,
    [string]$Base,
    [switch]$Draft,
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

    $cur = Get-GcCurrentBranch -Root $root
    $default = Get-GcDefaultBranch -Root $root
    $base = if ($Base) { $Base } else { $default }
    if ($Base) { Assert-GcRefValue -Name '-Base' -Value $base }
    Write-GcInfo "head: $cur  base: $base"

    # precondition, before gh: the head must already exist on the remote
    # (§4 flow: push first). A forgotten gc-push must say so, not fail deep in gh.
    $remote = Get-GcRemote -Root $root
    if (-not @(Get-GcGit -Root $root -Argv @('ls-remote','--heads',$remote,$cur))) {
        throw [GcException]::new("$cur is not on $remote — run gc-push first", $script:GcExitPre)
    }
    Assert-GcGh

    # title defaults to the commit subject, and is validated like one (§4)
    if (-not $Title) { $Title = (Get-GcGit -Root $root -Argv @('log','-1','--format=%s') | Select-Object -First 1).Trim() }
    Get-GcSubjectParts -Subject $Title | Out-Null   # throws Pre with the fix on any violation

    # body (§0 precedence): a repo with its own established PR structure
    # supplies it verbatim via -Body/-BodyFile; the fixed What/Why/Check/Risk
    # shape is the FALLBACK for a repo that is silent. An override that is
    # missing, unreadable or empty is a loud stop — a silently empty PR body is
    # worse than a failed run.
    $hasBody     = $PSBoundParameters.ContainsKey('Body')
    $hasBodyFile = $PSBoundParameters.ContainsKey('BodyFile')
    if ($hasBody -and $hasBodyFile) {
        throw [GcException]::new('-Body and -BodyFile are mutually exclusive — pass one body', $script:GcExitPre)
    }
    if ($hasBodyFile) {
        if (-not $BodyFile -or -not (Test-Path -LiteralPath $BodyFile -PathType Leaf)) {
            throw [GcException]::new("-BodyFile not found (or not a file): '$BodyFile' — pass the path to an existing PR body file", $script:GcExitPre)
        }
        try { $body = Get-Content -LiteralPath $BodyFile -Raw }
        catch { throw [GcException]::new("-BodyFile could not be read: '$BodyFile' — $($_.Exception.Message)", $script:GcExitPre) }
        if (-not $body -or -not $body.Trim()) {
            throw [GcException]::new("-BodyFile is empty: '$BodyFile' — the PR body must not be blank", $script:GcExitPre)
        }
        if ($What -or $Why -or $Check -or $Risk) {
            Write-GcWarn '-What/-Why/-Check/-Risk are ignored when -BodyFile supplies the body'
        }
    } elseif ($hasBody) {
        if (-not $Body -or -not $Body.Trim()) {
            throw [GcException]::new('-Body is empty — drop it to get the fixed What/Why/Check/Risk body', $script:GcExitPre)
        }
        $body = $Body
    } else {
        # fallback: exactly the fixed shape, one line per field
        foreach ($v in @($What, $Why, $Check, $Risk)) {
            if ($v -and ($v -match '\r?\n')) { throw [GcException]::new('body fields must be one line each — What/Why/Check/Risk', $script:GcExitPre) }
        }
        if (-not $What) { throw [GcException]::new('-What is required (or supply -Body/-BodyFile)', $script:GcExitPre) }
        $body = Format-GcPrBody -What $What -Why $Why -Check $Check -Risk $Risk
    }

    # self-heal: reuse an existing PR for this branch — but a merged PR is a
    # no-op ONLY when its head still matches local (a recreated/re-pushed
    # branch with new commits must get a FRESH PR, never a false no-op).
    $exists = $null
    try {
        $exists = Get-GcGhJson -Root $root -Argv @('pr','view',$cur,'--json','number,state,headRefOid')
    } catch {
        if ($_.Exception.Message -notmatch 'no pull requests found') { throw }
    }

    if ($exists) {
        if ($exists.state -eq 'MERGED') {
            $localHead = (Get-GcGit -Root $root -Argv @('rev-parse',$cur) | Select-Object -First 1).Trim()
            if ($localHead -eq $exists.headRefOid) {
                Write-GcOk "PR #$($exists.number) for $cur is already merged (head unchanged)"
                Write-GcResult -Props @{ number = $exists.number; action = 'no-op'; state = 'merged' }
            }
            Write-GcWarn "PR #$($exists.number) is merged but $cur has moved on ($($localHead.Substring(0,[Math]::Min(7,$localHead.Length))) != $($exists.headRefOid.Substring(0,7))) — creating a fresh PR"
            $exists = $null   # fresh PR for the new commits
        } elseif ($exists.state -eq 'CLOSED') {
            Invoke-GcGh -Root $root -Argv @('pr','reopen',"$($exists.number)")
            Write-GcInfo "reopened PR #$($exists.number)"
        }
        if ($exists) {
            $argv = @('pr','edit',"$($exists.number)",'--title',$Title,'--body',$body)
            # draft is set at create only — gh pr edit has no --draft (cannot be toggled on update)
            Invoke-GcGh -Root $root -Argv $argv
            $action = if ($exists.state -eq 'CLOSED') { 'reopened' } else { 'updated' }
            Write-GcOk "PR #$($exists.number) $action"
            $r = Get-GcGhJson -Root $root -Argv @('pr','view',"$($exists.number)",'--json','number,url')
            Write-GcResult -Props @{ number = $r.number; url = $r.url; action = $action }
        }
    }

    $argv = @('pr','create','--base',$base,'--head',$cur,'--title',$Title,'--body',$body)
    if ($Draft) { $argv += '--draft' }
    Invoke-GcGh -Root $root -Argv $argv
    $r = Get-GcGhJson -Root $root -Argv @('pr','view',$cur,'--json','number,url,isDraft')
    Write-GcOk "PR #$($r.number) created ($(if ($r.isDraft) { 'draft' } else { 'ready' }))"
    Write-GcResult -Props @{ number = $r.number; url = $r.url; action = 'created'; draft = $r.isDraft }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}
