#Requires -Version 7.0
<#
.SYNOPSIS
  §9 single-release machinery: ONE moving `latest` tag, ONE release entry whose
  body is rendered from CHANGELOG.md. Never a second entry.

.DESCRIPTION
  git-ceremony §9 as a script. Invariants enforced:
    - AT MOST ONE release entry, permanently. An existing `latest` release is
      EDITED, never duplicated; zero release entries → exactly one is created;
      any other shape (more than one entry, or a single entry under a foreign
      tag, draft or prerelease) is REFUSED loudly, before anything moves.
    - ONE moving tag: `latest` is a pointer, not a version tag —
        git tag -f latest <head-sha>
        git push --force origin latest
      The bare force is deliberate and documented (the §6 lease-only rule
      reserves plain --force for exactly this pointer); never per-version tags.
    - body rendered from CHANGELOG.md: the version comes from package.json (the
      npm manifest — one source of truth, §8) and its section from the
      changelog; the number is never hardcoded in two places.
    - the pointer tags the REMOTE default-branch head: the checkout must BE the
      default branch (detached/other-branch refused), the tree must be clean,
      the branch is synced first (fetch + ff-only, §1) and refused when local
      head ≠ remote head — a stale or unpushed head is never tagged.
    - npm gate: refuses a version npm does not have; a release entry for an
      unpublished version is a lie. npm missing or unreachable → exit 3.
    - idempotent: a second run moves the pointer and rewrites the body, and
      never creates a second release.
  Repo rules win (§0): a repo with its own release process is not migrated by
  force; the repo's process stays the answer.

.PARAMETER RepoRoot
  Repository path (defaults to the current directory); git is always pinned
  with git -C.
.PARAMETER MovingLatest
  Required explicit opt-in. This wrapper implements a nonstandard single moving
  `latest` release and must only be used when repository policy declares it.
.PARAMETER Detailed
  Restore the step narration, ok/info lines, and raw git/gh relay the terse
  default hides. Never affects the RESULT line, warnings, failures, or the
  security/remediation lines.
.PARAMETER Quiet
  Accepted for compatibility and now a no-op: the default is already terse.
  -Quiet forces the gate closed and so wins if passed with -Detailed.

.EXAMPLE
  pwsh -NoProfile -File scripts\gc-release.ps1 -MovingLatest -RepoRoot <repo-path>
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$MovingLatest,
    [switch]$Detailed,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gc.core.ps1')
if ($Detailed) { $script:GcQuiet = $false }
if ($Quiet) { $script:GcQuiet = $true }

function Read-GcPackageIdentity {
    <#
    package.json name + version: the npm identity and the §8 one source of
    truth for the version. Pre failures name the fix; a private package is
    refused (nothing is published, so an entry would be a lie).
    #>
    param([Parameter(Mandatory)][string]$Root)
    $abs = Join-Path $Root 'package.json'
    if (-not (Test-Path -LiteralPath $abs)) {
        throw [GcException]::new('package.json not found — gc-release cuts npm releases; this repo has no npm manifest', $script:GcExitPre)
    }
    try { $pkg = Get-Content -LiteralPath $abs -Raw | ConvertFrom-Json }
    catch { throw [GcException]::new("package.json does not parse: $($_.Exception.Message)", $script:GcExitPre) }
    if ($pkg.PSObject.Properties.Name -contains 'private' -and $pkg.private) {
        throw [GcException]::new('package.json is private — nothing is published to npm, so a release entry would be a lie', $script:GcExitPre)
    }
    $name = if ($pkg.PSObject.Properties.Name -contains 'name') { "$($pkg.name)".Trim() } else { '' }
    $version = if ($pkg.PSObject.Properties.Name -contains 'version') { "$($pkg.version)".Trim() } else { '' }
    if (-not $name -or -not $version) {
        throw [GcException]::new('package.json is missing name or version — repo defect', $script:GcExitPre)
    }
    return [pscustomobject]@{ Name = $name; Version = $version }
}

function Assert-GcNpmVersionPublished {
    <#
    The npm gate, explicit and loud: a version npm does not have is refused
    with the fix named (a release entry for an unpublished version is a lie).
    npm absent, or a query failure that is NOT "version absent", is a
    dependency stop (exit 3) — the check must never be skipped silently.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version)
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw [GcException]::new('npm is not installed or not on PATH — cannot verify the published version; install Node/npm and re-run', $script:GcExitDep)
    }
    $query = "$Name@$Version"
    $out = & npm view $query version 2>&1
    $code = $LASTEXITCODE
    $text = if ($null -eq $out) { '' } else { (@($out) -join "`n") }
    if ($code -ne 0) {
        if ($text -match 'E404|ETARGET|No match found|No matching version|not found') {
            throw [GcException]::new("npm does not have $query — publish it first (npm publish), then cut the release; a release entry for an unpublished version is a lie", $script:GcExitPre)
        }
        throw [GcException]::new("npm view $query failed (exit $code): $($text.Trim()) — cannot verify the published version", $script:GcExitDep)
    }
    $reported = @($text -split "`r?`n" | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -eq $Version })
    if ($reported.Count -lt 1) {
        throw [GcException]::new("npm did not report $query as published (saw: $($text.Trim())) — refusing; a release entry for an unpublished version is a lie", $script:GcExitPre)
    }
}

function Get-GcReleases {
    <# `gh release list` as an Object[] — empty when none. ALWAYS an array, so
       every caller's .Count / [0] works under Set-StrictMode: a bare `return
       @($raw)` unwraps at the function boundary (empty → $null, one → scalar),
       which crashed the one-entry read before anything was moved. #>
    param([Parameter(Mandatory)][string]$Root)
    $raw = Get-GcGhJson -Root $Root -Argv @('release','list','--limit','5','--json','tagName,isDraft,isPrerelease,isLatest')
    if ($null -eq $raw) { $raw = @() }
    return ,[Object[]]$raw
}

try {
    if (-not $MovingLatest) {
        throw [GcException]::new('gc-release implements the nonstandard moving-latest scheme; repository policy must require it and the caller must pass -MovingLatest', $script:GcExitPre)
    }
    $root = Resolve-GcRoot -Path $RepoRoot
    Write-GcInfo "repo: $root"

    # --- the head that will be tagged: default branch, clean, synced, remote ---
    $cur = Get-GcCurrentBranch -Root $root
    $default = Get-GcDefaultBranch -Root $root
    if ($cur -ne $default) {
        throw [GcException]::new("refusing to release from '$cur' — the pointer tags the default-branch head; switch to '$default' first", $script:GcExitPre)
    }
    if (-not (Test-GcCleanTree -Root $root)) {
        throw [GcException]::new('tree is not clean — commit or stash first; the pointer tags the exact published tree', $script:GcExitPre)
    }
    $remote = Get-GcRemote -Root $root
    if ($remote -ne 'origin') { Invoke-GcGit -Root $root -Argv @('fetch','--prune',$remote) }
    Sync-GcDefaultBranch -Root $root -Default $default -CurrentBranch $cur | Out-Null
    $remoteRef = "refs/remotes/$remote/$default"
    if (-not (Test-GcRef -Root $root -Ref $remoteRef)) {
        throw [GcException]::new("$remote/$default has no remote head — push the default branch first", $script:GcExitPre)
    }
    $head  = ((Get-GcGit -Root $root -Argv @('rev-parse','HEAD') | Select-Object -First 1) -split '\s+')[0]
    $rhead = ((Get-GcGit -Root $root -Argv @('rev-parse',$remoteRef) | Select-Object -First 1) -split '\s+')[0]
    if ($head -ne $rhead) {
        throw [GcException]::new("local $default is not at $remote/$default ($($head.Substring(0,7)) vs $($rhead.Substring(0,7))) — the pointer must tag the remote head; sync or push the default branch first, then re-run", $script:GcExitPre)
    }

    # --- identity, body (§8/§9), npm gate --------------------------------------
    $pkg = Read-GcPackageIdentity -Root $root
    $section = Get-GcChangelogSection -Root $root -Version $pkg.Version
    $body = Format-GcReleaseBody -Version $pkg.Version -Lines $section
    Write-GcInfo "rendered $(@($section).Count) changelog line(s) for $($pkg.Name)@$($pkg.Version)"
    Assert-GcNpmVersionPublished -Name $pkg.Name -Version $pkg.Version
    Write-GcOk "npm has $($pkg.Name)@$($pkg.Version)"

    # --- one-entry invariant: read BEFORE anything moves -----------------------
    Assert-GcGh
    $entries = Get-GcReleases -Root $root
    if ($entries.Count -eq 0) {
        $action = 'created'
    } elseif ($entries.Count -eq 1 -and $entries[0].tagName -eq 'latest') {
        if ($entries[0].isDraft -or $entries[0].isPrerelease) {
            throw [GcException]::new("the 'latest' release entry is a draft or prerelease — §9 keeps one live normal entry; publish or normalize it first", $script:GcExitPre)
        }
        $action = 'updated'
    } else {
        $tags = @($entries | ForEach-Object { $_.tagName }) -join ', '
        throw [GcException]::new("refusing: release entries beyond the single 'latest' pointer exist ($tags) — §9 allows at most one entry, permanently; delete or reconcile the strays first", $script:GcExitPre)
    }

    # --- the pointer: deliberate bare force, documented above ------------------
    Invoke-GcGit -Root $root -Argv @('tag','-f','latest',$head)
    Invoke-GcGit -Root $root -Argv @('push','--force',$remote,'refs/tags/latest')
    Write-GcOk "latest -> $($head.Substring(0,7)) (pointer moved; force is deliberate)"

    # --- the one entry: edit when it exists, create only when none does --------
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-release-body-" + [guid]::NewGuid().ToString('N') + ".md")
    try {
        Set-Content -LiteralPath $tmp -Value $body -NoNewline
        if ($action -eq 'created') {
            Invoke-GcGh -Root $root -Argv @('release','create','latest','--title',$pkg.Name,'--notes-file',$tmp,'--verify-tag','--latest')
        } else {
            Invoke-GcGh -Root $root -Argv @('release','edit','latest','--title',$pkg.Name,'--notes-file',$tmp,'--latest')
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    # --- verify, never trust ----------------------------------------------------
    $view = Get-GcGhJson -Root $root -Argv @('release','view','latest','--json','tagName,name,url')
    if ($view.tagName -ne 'latest') {
        throw [GcException]::new("release verification failed — gh reports tag '$($view.tagName)', expected 'latest'", $script:GcExitFail)
    }
    $final = Get-GcReleases -Root $root
    if ($final.Count -ne 1 -or $final[0].tagName -ne 'latest' -or -not $final[0].isLatest) {
        throw [GcException]::new("release verification failed — expected exactly one entry for 'latest' marked latest; got $(@($final | ForEach-Object { "$($_.tagName)(latest=$($_.isLatest))" }) -join ', ')", $script:GcExitFail)
    }
    $lsLine = @(Get-GcGit -Root $root -Argv @('ls-remote',$remote,'refs/tags/latest') | Select-Object -First 1)[0]
    $remoteSha = if ($lsLine) { ($lsLine -split '\s+')[0] } else { '' }
    if ($remoteSha -ne $head) {
        throw [GcException]::new("remote '$remote' latest tag is '$remoteSha', expected '$head' — pointer verification failed", $script:GcExitFail)
    }

    Write-GcOk "release ${action}: $($pkg.Name) v$($pkg.Version) @ latest ($($view.url))"
    Write-GcResult -Props @{
        action    = $action
        name      = $pkg.Name
        version   = $pkg.Version
        tag       = 'latest'
        sha       = $head
        url       = $view.url
        is_latest = [bool]$final[0].isLatest
        remote    = $remote
    }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}
