#Requires -Version 7.0
<#
.SYNOPSIS
  Stage content with ceremony gates: add the given paths (or -All), run the
  secret scan, report exactly what landed in the index.

.DESCRIPTION
  The index is where ceremony violations get caught cheaply. This script adds
  paths, then scans the newly staged files for obvious secret shapes — a hit
  leaves the offending files UNSTAGED (working tree untouched) and exits 4
  with the file list, so the agent can fix and retry without losing anything.
  Nothing staged (unchanged / ignored paths) is a clean no-op, exit 0.

  Repo rules win: if the repo documents its own convention, follow that
  instead of this script.

  Output contract: stdout is exactly one RESULT: <json> line with staged
  file names and count; logs go to the console.

.PARAMETER Path
  Files or globs to stage, relative to the repo root (or absolute). ONE path
  or glob per -Path invocation — pwsh -File does not array-bind a comma list
  ('a,b' arrives as a single literal path). Stage many at once with -All.
.PARAMETER All
  Stage everything (git add -A) instead of specific paths.
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
  pwsh -File scripts\gc-stage.ps1 -Path 'src/foo.ts' -Path 'docs/foo.md'

.EXAMPLE
  pwsh -File scripts\gc-stage.ps1 -All
#>
param(
    [string[]]$Path,
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

    if (-not $All -and -not $Path) {
        throw [GcException]::new('give -Path <files-or-globs> or -All', $script:GcExitPre)
    }

    if (-not $All) {
        # validate every path resolves before touching the index (atomic gate)
        foreach ($p in $Path) {
            $joined = Join-Path $root $p
            if ($p -match '[*?\[]') {
                $matched = @(Get-ChildItem -Path $joined -Force -ErrorAction SilentlyContinue)
                if ($matched.Count -eq 0) {
                    throw [GcException]::new("no files match glob '$p' (under $root)", $script:GcExitPre)
                }
            } elseif (-not (Test-Path -LiteralPath $joined)) {
                throw [GcException]::new("path does not exist: $p (under $root)", $script:GcExitPre)
            }
        }
        Invoke-GcGit -Root $root -Argv (@('add','--') + $Path)
        Write-GcOk "staged $($Path -join ', ')"
    } else {
        Invoke-GcGit -Root $root -Argv @('add','-A')
        Write-GcOk 'staged all changes (-All)'
    }

    # security gate on exactly what is now staged
    Stop-GcOnSecrets -Root $root

    $staged = @(Get-GcStagedNames -Root $root)
    if (-not $staged) {
        Write-GcInfo 'nothing staged — paths unchanged, ignored, or already staged'
        Write-GcResult -Props @{ staged = @(); count = 0; action = 'no-op' }
    }

    $stat = Get-GcGit -Root $root -Argv @('diff','--cached','--stat')
    Write-GcNote (($stat -join "`n"))
    Write-GcOk "staged $($staged.Count) file(s)"
    Write-GcResult -Props @{ staged = $staged; count = $staged.Count; action = 'staged' }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}