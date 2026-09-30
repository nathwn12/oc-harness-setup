#Requires -Version 7.0
<#
.SYNOPSIS
  Version bump per ceremony §8: detect the repo's single manifest, apply the
  bump table, justify it, and land the bump as its own commit. No tags, no
  release body, no human in the middle.

.DESCRIPTION
  git-ceremony §8 as a script. Rules enforced:
    - one source of truth: exactly one manifest (package.json, pyproject.toml,
      Cargo.toml, or a VERSION file) may exist — two is a repo defect, stop.
    - repo-declared format wins: only 3-part MAJOR.MINOR.PATCH is auto-bumped;
      CalVer, 4-part, or build numbers are refused (repo convention wins, bump
      by hand).
    - the bump table: -Major resets MINOR and PATCH to 0; -Minor resets PATCH
      to 0; -Patch increments PATCH. -Set forces an explicit version.
    - never bump downward, never reuse a version (§8).
    - every bump is justified: -Reason (one line) lands in the bump commit.
    - the bump is its own commit: `chore(release): <old> -> <new>`; a dirty
      tree is refused, and the bump refuses to commit on the default branch
      (the release commit ships through a PR, §6/§11b).
  Write-back is text-preserving (only the version value changes), verified by
  re-reading the manifest before the commit.

.PARAMETER Major
  Breaking API or behavior change (resets MINOR, PATCH).
.PARAMETER Minor
  New backward-compatible capability (resets PATCH).
.PARAMETER Patch
  Bug fix, no new surface.
.PARAMETER Set
  Explicit target version MAJOR.MINOR.PATCH (still justified, still no
  downward moves).
.PARAMETER Reason
  Required one-line justification — what kind of change forced which digit.
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
  pwsh -File scripts\gc-bump.ps1 -Minor -Reason 'adds token refresh endpoint (backward compatible)'
#>
param(
    [switch]$Major,
    [switch]$Minor,
    [switch]$Patch,
    [string]$Set,
    [Parameter(Mandatory)][string]$Reason,
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Detailed,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gc.core.ps1')
if ($Detailed) { $script:GcQuiet = $false }
if ($Quiet) { $script:GcQuiet = $true }

function Get-GcManifestEncoding {
    <# detect the manifest's byte-encoding (BOM/UTF-16) so write-back preserves
       it — the "only the version value changes" promise must survive. #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return @{ Enc = [System.Text.UTF8Encoding]::new($true); Name = 'utf8-bom' } }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return @{ Enc = [System.Text.UnicodeEncoding]::new($false, $true); Name = 'utf16-le' } }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return @{ Enc = [System.Text.UnicodeEncoding]::new($true, $true); Name = 'utf16-be' } }
    return @{ Enc = [System.Text.UTF8Encoding]::new($false); Name = 'utf8' }
}

function Read-GcVersion {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Manifest, [Parameter(Mandatory)][hashtable]$Encoding)
    $abs = Join-Path $Root $Manifest
    $enc = $Encoding.Enc
    $content = $enc.GetString([System.IO.File]::ReadAllBytes($abs))
    switch -Regex ($Manifest) {
        'package\.json$' {
            if ($content -notmatch '"version"\s*:\s*"([^"]+)"') { throw [GcException]::new("package.json has no version field — repo defect", $script:GcExitPre) }
            return $Matches[1]
        }
        '\.toml$' {
            if ($content -notmatch '(?m)^version\s*=\s*"([^"]+)"') { throw [GcException]::new("$Manifest has no top-level version entry — repo defect", $script:GcExitPre) }
            return $Matches[1]
        }
        '^VERSION$' {
            $v = $content.Trim()
            if (-not $v) { throw [GcException]::new('VERSION file is empty — repo defect', $script:GcExitPre) }
            return $v
        }
        default { throw [GcException]::new("unsupported manifest: $Manifest", $script:GcExitPre) }
    }
}

function Write-GcVersion {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Manifest, [Parameter(Mandatory)][string]$Old, [Parameter(Mandatory)][string]$New, [Parameter(Mandatory)][hashtable]$Encoding)
    $abs = Join-Path $Root $Manifest
    $enc = $Encoding.Enc
    $content = $enc.GetString([System.IO.File]::ReadAllBytes($abs))
    switch -Regex ($Manifest) {
        'package\.json$' {
            $content = $content -replace '("version"\s*:\s*")[^"]+(")', "`${1}$New`${2}"
        }
        '\.toml$' {
            $content = $content -replace '(?m)^(version\s*=\s*")[^"]+(")', "`${1}$New`${2}"
        }
        '^VERSION$' {
            $content = $New + "`n"
        }
    }
    [System.IO.File]::WriteAllBytes($abs, $enc.GetBytes($content))
    # verify the write-back, never trust the replace
    $readBack = Read-GcVersion -Root $Root -Manifest $Manifest -Encoding $Encoding
    if ($readBack -ne $New) {
        throw [GcException]::new("write-back verification failed — manifest reads '$readBack', expected '$New'; nothing was committed", $script:GcExitFail)
    }
}

try {
    $root = Resolve-GcRoot -Path $RepoRoot
    Write-GcInfo "repo: $root"

    $cur = Get-GcCurrentBranch -Root $root
    $default = Get-GcDefaultBranch -Root $root
    if ($cur -eq $default) {
        throw [GcException]::new("refusing to bump on the default branch ($default) — the release commit ships through a PR (§6/§11b); gc-branch first", $script:GcExitPre)
    }

    # exactly one bump direction
    $flags = @([bool]$Major, [bool]$Minor, [bool]$Patch)
    $given = @($flags | Where-Object { $_ }).Count + $(if ($Set) { 1 } else { 0 })
    if ($given -ne 1) {
        throw [GcException]::new('pick exactly one: -Major, -Minor, -Patch, or -Set <version>', $script:GcExitPre)
    }
    if ($Reason -match '\r?\n' -or $Reason.Length -gt 200) {
        throw [GcException]::new('-Reason must be one line, ≤200 chars', $script:GcExitPre)
    }

    # one source of truth (§8)
    $manifests = @(@('package.json','pyproject.toml','Cargo.toml','VERSION') | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) })
    if (-not $manifests) {
        throw [GcException]::new('no version manifest found — expected package.json, pyproject.toml, Cargo.toml, or a VERSION file', $script:GcExitPre)
    }
    if (@($manifests).Count -gt 1) {
        throw [GcException]::new("multiple manifests ($($manifests -join ', ')) — two sources of truth; fix before bumping (§8)", $script:GcExitPre)
    }
    $manifest = $manifests[0]

    $manifestAbs = Join-Path $root $manifest
    $manifestEnc = Get-GcManifestEncoding -Path $manifestAbs
    $old = Read-GcVersion -Root $root -Manifest $manifest -Encoding $manifestEnc
    if ($old -notmatch '^\d+\.\d+\.\d+$') {
        throw [GcException]::new("repo version '$old' is not MAJOR.MINOR.PATCH — repo-declared format wins; bump it by hand (§8)", $script:GcExitPre)
    }

    $maj, $min, $pat = $old -split '\.' | ForEach-Object { [int]$_ }
    if ($Set) {
        if ($Set -notmatch '^\d+\.\d+\.\d+$') { throw [GcException]::new("-Set must be MAJOR.MINOR.PATCH", $script:GcExitPre) }
        $new = $Set; $kind = 'set'
    } elseif ($Major) { $maj++; $new = "$maj.0.0"; $kind = 'major' }
    elseif ($Minor) { $min++; $new = "$maj.$min.0"; $kind = 'minor' }
    else            { $pat++; $new = "$maj.$min.$pat"; $kind = 'patch' }

    if ([version]$new -le [version]$old) {
        throw [GcException]::new("$new is not above $old — never bump downward, never reuse a version (§8)", $script:GcExitPre)
    }

    # the bump is its own commit — a dirty tree is refused, not mixed in
    if (-not (Test-GcCleanTree -Root $root)) {
        throw [GcException]::new('tree is not clean — the bump must be its own commit; commit or stash the feature work first (§8)', $script:GcExitPre)
    }
    Assert-GcIdentity -Root $root

    Write-GcInfo "bumping ${manifest}: $old -> $new ($kind)"
    Write-GcVersion -Root $root -Manifest $manifest -Old $old -New $new -Encoding $manifestEnc

    $subject = "chore(release): $old -> $new"
    Get-GcSubjectParts -Subject $subject | Out-Null   # ceremony-valid message
    $argv = @('commit','-m',$subject,'-m',"-${kind}: $Reason")
    Invoke-GcGit -Root $root -Argv (@('add','--',$manifest))
    Stop-GcOnSecrets -Root $root   # same gate as gc-commit — a manifest must never smuggle a secret
    Invoke-GcGit -Root $root -Argv $argv

    $sha = (Get-GcGit -Root $root -Argv @('rev-parse','--short','HEAD') | Select-Object -First 1).Trim()
    Write-GcOk "$subject @ $sha"
    Write-GcResult -Props @{ manifest = $manifest; old = $old; new = $new; kind = $kind; reason = $Reason; sha = $sha; action = 'bumped' }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}