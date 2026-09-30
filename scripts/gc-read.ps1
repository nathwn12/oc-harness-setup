#Requires -Version 7.0
<#
.SYNOPSIS
  Read-only git surface for the git-ceremony toolset — one selector, six reads,
  zero writes.

.DESCRIPTION
  The ceremony scripts cover mutation; this covers inspection, so an
  MCP-routed agent never has to drop to raw git to review the staged diff
  (git-ceremony §3's last gate) or to look at history. Every read is pinned
  `git -C <root>` and drawn from a fixed, read-only subcommand set — there is
  no code path here that can touch the index, the working tree, a ref, or a
  remote.

  Selectors (-What):
    diff-staged  git diff --staged        (the §3 pre-commit gate)
    diff         git diff                 (unstaged changes)
    log          git log --oneline-like   (newest -Limit, default 20)
    show         git show --stat          (needs -Rev)
    branch-list  local branches + upstream + head sha
    status       delegates to gc-status.ps1 (reuse, not reimplementation)

  Output is the standard contract: exactly one stdout line `RESULT: <json>`
  (see gc.core.ps1). Text payloads (diff/show) are relayed verbatim in the
  RESULT — reads are free, so nothing is truncated here; scope a diff with
  -Path and cap history with -Limit instead.

.PARAMETER What
  One of: diff-staged · diff · log · show · branch-list · status.
.PARAMETER Path
  Optional single pathspec to scope -What diff-staged / diff.
.PARAMETER Rev
  Revision for -What show (required there); ref-shaped and validated.
.PARAMETER Limit
  Maximum commits for -What log (default 20; must be >= 1).
.PARAMETER RepoRoot
  Repository path (defaults to the current directory).
.PARAMETER Detailed
  Restore the step narration, ok/info lines, and raw git/gh relay the terse
  default hides. gc-read's payload (diff/show/log) is data and is always in the
  RESULT line, so -Detailed never gates it.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -File scripts\gc-read.ps1 -What diff-staged
.EXAMPLE
  pwsh -File scripts\gc-read.ps1 -What log -Limit 5
.EXAMPLE
  pwsh -File scripts\gc-read.ps1 -What show -Rev HEAD
#>
param(
    [Parameter(Mandatory)][string]$What,
    [string]$Path,
    [string]$Rev,
    [int]$Limit = 20,
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Detailed,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gc.core.ps1')
if ($Detailed) { $script:GcQuiet = $false }
if ($Quiet) { $script:GcQuiet = $true }

$script:GcReadSelectors = @('diff-staged','diff','log','show','branch-list','status')

try {
    # validated in-body (not a ValidateSet) so a bad selector still emits the
    # contract RESULT line and exit 2, never a bare pwsh binder failure.
    if ($script:GcReadSelectors -cnotcontains $What) {
        throw [GcException]::new("-What '$What' is not one of: $($script:GcReadSelectors -join ', ')", $script:GcExitPre)
    }

    if ($What -eq 'status') {
        # reuse the existing read surface: run gc-status.ps1 and relay its single
        # RESULT line + exit code byte-for-byte. No reimplementation, no second
        # source of truth for the snapshot shape. Delegated BEFORE resolving the
        # root: the child runs the same `rev-parse --show-toplevel` itself, so
        # resolving here first would be a second, wasted spawn.
        $pwsh = (Get-Process -Id $PID).Path
        if (-not $pwsh) { $pwsh = 'pwsh' }
        $child = & $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'gc-status.ps1') -RepoRoot $RepoRoot -Quiet 2>&1
        $code = $LASTEXITCODE
        $res = @($child | ForEach-Object { "$_" } | Where-Object { $_ -match '^RESULT: ' } | Select-Object -Last 1)
        if ($res.Count -eq 1) { Write-Output $res[0]; exit $code }
        Write-GcResult -Code $script:GcExitFail -Props @{ message = 'gc-read: status relay produced no RESULT line' }
    }

    $root = Resolve-GcRoot -Path $RepoRoot

    $branch = try { Get-GcCurrentBranch -Root $root } catch { '(detached)' }

    switch ($What) {
        'diff-staged' {
            $argv = @('diff','--staged','--no-color')
            if ($Path) { $argv += @('--',$Path) }
            $text = (@(Get-GcGit -Root $root -Argv $argv) -join "`n")
            Write-GcResult -Props @{ what = $What; repo = $root; branch = $branch; empty = [string]::IsNullOrEmpty($text); diff = $text }
        }
        'diff' {
            $argv = @('diff','--no-color')
            if ($Path) { $argv += @('--',$Path) }
            $text = (@(Get-GcGit -Root $root -Argv $argv) -join "`n")
            Write-GcResult -Props @{ what = $What; repo = $root; branch = $branch; empty = [string]::IsNullOrEmpty($text); diff = $text }
        }
        'log' {
            if ($Limit -le 0) { throw [GcException]::new('-Limit must be >= 1', $script:GcExitPre) }
            $raw = @(Get-GcGit -Root $root -Argv @('log','-n',"$Limit",'--no-color','--pretty=format:%h%x09%s'))
            $commits = @($raw | Where-Object { $_ } | ForEach-Object {
                $parts = "$_" -split "`t", 2
                [pscustomobject]@{ sha = $parts[0]; subject = if ($parts.Count -gt 1) { $parts[1] } else { '' } }
            })
            Write-GcResult -Props @{ what = $What; repo = $root; branch = $branch; count = $commits.Count; commits = $commits }
        }
        'show' {
            if (-not $Rev) { throw [GcException]::new('-What show needs -Rev <ref> — e.g. -Rev HEAD', $script:GcExitPre) }
            Assert-GcRefValue -Name '-Rev' -Value $Rev
            $text = (@(Get-GcGit -Root $root -Argv @('show','--no-color','--stat','--format=fuller',$Rev)) -join "`n")
            Write-GcResult -Props @{ what = $What; repo = $root; branch = $branch; rev = $Rev; text = $text }
        }
        'branch-list' {
            # literal tab, not %x09: `git branch --format` does not expand %xNN
            # (it prints it verbatim), so the separator is a real tab character.
            $tab = [char]9
            $fmt = '%(HEAD)' + $tab + '%(refname:short)' + $tab + '%(upstream:short)' + $tab + '%(objectname:short)'
            $raw = @(Get-GcGit -Root $root -Argv @('branch','--no-color',"--format=$fmt"))
            $branches = @($raw | Where-Object { $_ } | ForEach-Object {
                $p = "$_" -split "`t"
                [pscustomobject]@{
                    current  = ($p[0].Trim() -eq '*')
                    name     = if ($p.Count -gt 1) { $p[1] } else { '' }
                    upstream = if ($p.Count -gt 2) { $p[2] } else { '' }
                    sha      = if ($p.Count -gt 3) { $p[3] } else { '' }
                }
            })
            $cur = $branches | Where-Object { $_.current } | Select-Object -First 1
            $current = if ($cur) { $cur.name } else { $null }
            Write-GcResult -Props @{ what = $What; repo = $root; branch = $branch; current = $current; count = $branches.Count; branches = $branches }
        }
    }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}
