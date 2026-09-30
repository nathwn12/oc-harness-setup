#Requires -Version 7.0
<#
.SYNOPSIS
  Housekeeper sweep for the two junk roots: dry-run report by default, and
  deletion only with -Force while the session is armed with `--clean`.

.DESCRIPTION
  `--clean` housekeeper as a script (reference/clean-mandate.md). Default roots:

      %TEMP%\opencode
      %USERPROFILE%\.cache\opencode

  `-Root <path>` overrides with a single sweep root (testing/sandbox use); the
  github\ / github\v2 structure semantics are derived under it when present.

  Phase 0 runs FIRST and unconditionally (dry-run and armed mode alike): files
  matching `*.bak*` found inside %USERPROFILE%\.config\opencode are MOVED -
  never deleted - into %USERPROFILE%\.opencode\config-backups\.

  Junk classes (the ONLY deletions permitted):
    - `*.bak*` temp config backups;
    - stale cache entries under github\v2 for plugins not in the adopter's
      live set (safe to re-fetch if ever re-added) - classified only when a
      live set is passed via -LiveCache; without one, v2 entries are
      reported, never deleted (a live cache is indistinguishable from stale
      without the list);
    - old-layout leftovers under github\ that are not github\v2\;
    - directories left empty after those deletions.

  Everything else is unclassified: reported, never deleted. Repo-local
  untracked files are listed only - this tool never deletes them.

  SAFETY RAILS (defence in depth, all enforced here):
    - without -Force nothing is deleted anywhere;
    - a deletion candidate must sit strictly under a resolved root, never be
      a reparse point, never be on the keep-list, and must scan clean for
      credential-shaped names and secret-shaped content - a hit is reported
      by path only, contents are never printed;
    - junk-class misclassification is a hard refusal: only the four classes
      above are ever deleted, everything else is reported;
    - if the keep-list cannot be resolved (script path, reference directory,
      -KeepExtra), -Force stops with exit 2;
    - the keep-list is law, PROTECT-IF-PRESENT: this script, the reference
      directory, any *.tgz npm pack, the adopter's live v2 cache entries
      (via -LiveCache), plus -KeepExtra. An absent keep is skipped with a
      note - never a hard exit.

  OUTPUT: stdout carries only the final `RESULT: <json>` line (take the LAST
  one); everything else is console narration. The terse default prints the
  would-delete/done table, the reported/kept summary, the keep-list line and
  warnings; -Detailed adds the keep ledger, the complete reported/kept list
  and the complete untracked listing.

.PARAMETER Force
  Delete the classified junk. Only pass while the session is armed with
  `--clean`; without it the sweep is a dry run.
.PARAMETER KeepExtra
  Additional paths this run must never touch (prefix semantics: a kept path
  covers everything beneath it).
.PARAMETER Root
  Optional single sweep root override (default: the two roots above). For
  sandboxed test runs; the github\ / github\v2 classes are derived under it.
.PARAMETER LiveCache
  Name prefixes of the adopter's current plugin cache entries under
  github\v2 (e.g. `owner--plugin--`). Kept as law; other `*--*--*` v2 entries
  are junk only while this list is non-empty.
.PARAMETER RepoRoot
  Path whose untracked files are listed (defaults to the current directory).
  Listing only - never deleted by this tool.
.PARAMETER Detailed
  Restore the full narration: keep ledger, complete reported/kept list,
  complete untracked listing. Never affects the RESULT line, warnings or
  failures.

.EXAMPLE
  pwsh -File scripts\gc-clean.ps1

.EXAMPLE
  # only while the session is armed with `--clean`
  pwsh -File scripts\gc-clean.ps1 -Force -KeepExtra "$env:TEMP\opencode\my-scratch"

.EXAMPLE
  # sandboxed test sweep against a scratch directory
  pwsh -File scripts\gc-clean.ps1 -Root "$env:TEMP\opencode\sweep-sandbox" -LiveCache 'acme--plugin--' -Force
#>
param(
    [switch]$Force,
    [string[]]$KeepExtra = @(),
    [string]$Root = '',
    [string[]]$LiveCache = @(),
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Detailed
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gc.core.ps1')
if ($Detailed) { $script:GcQuiet = $false }

# --- constants ----------------------------------------------------------------
# live v2 cache entry name prefixes the sweep must never touch - adopter-set
# (reference/clean-mandate.md - keep-list is law; empty = no live set known)
$script:CleanLiveCachePrefixes = @($LiveCache)
# secret-scan bounds: config backups are tiny; anything bigger is refused
# (kept) rather than deleted unverified - fail-safe, never fail-fast
$script:CleanScanMaxBytes = 2MB
$script:CleanScanMaxFiles = 2000

# --- sweep state (populated before any scan) ----------------------------------
$script:CleanRoots = [System.Collections.Generic.List[string]]::new()
$script:CleanStructureDirs = [System.Collections.Generic.List[string]]::new()
$script:CleanUnitParents = [System.Collections.Generic.List[string]]::new()
$script:CleanKeepFiles = [System.Collections.Generic.List[string]]::new()
$script:CleanKeepPrefixes = [System.Collections.Generic.List[string]]::new()
$script:CleanKeepHits = [System.Collections.Generic.List[object]]::new()
$script:CleanWouldDelete = [System.Collections.Generic.List[object]]::new()
$script:CleanReported = [System.Collections.Generic.List[object]]::new()
$script:CleanUnclassified = 0

# --- helpers ------------------------------------------------------------------
function ConvertTo-CleanPath {
    <# absolute path, no trailing separator; throws when unnormalisable. #>
    param([Parameter(Mandatory)][string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd([char]'\', [char]'/')
}

function Test-CleanKept {
    <# keep-list is law: exact file keeps and prefix (subtree) keeps. #>
    param([Parameter(Mandatory)][string]$Path)
    foreach ($f in $script:CleanKeepFiles) {
        if ($Path.Equals($f, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($p in $script:CleanKeepPrefixes) {
        if ($Path.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Path.StartsWith($p + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-CleanUnderRoot {
    <# strictly under a resolved sweep root - nothing else can EVER be deleted. #>
    param([Parameter(Mandatory)][string]$Path)
    foreach ($r in $script:CleanRoots) {
        if ($Path.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-CleanStructureDir {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($s in $script:CleanStructureDirs) {
        if ($Path -ieq $s) { return $true }
    }
    return $false
}

function Test-CleanUnitParent {
    <# unclassified items are itemized at unit level only (root children and
       the structured github\ / github\v2 levels); a nested file inside an
       unclassified kept subtree belongs to that unit's report, not a unit. #>
    param([Parameter(Mandatory)][string]$Parent)
    foreach ($p in $script:CleanUnitParents) {
        if ($Parent -ieq $p) { return $true }
    }
    return $false
}

function Test-CleanLiveCache {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($p in $script:CleanLiveCachePrefixes) {
        if ($Name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-CleanCredentialName {
    <# credential-shaped leaf names are never deleted; .env.example-style safe
       names stay deletable as junk, matching the core secret gate. #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -match $script:GcSecretSafeFilenameRe) { return $false }
    return ($Name -match $script:GcSecretFilenameRe)
}

function Get-CleanFileVerdict {
    <# $null = scanned clean; otherwise the reason the file must be KEPT.
       Content is read only to prove the absence of secret shapes. #>
    param([Parameter(Mandatory)][string]$File)
    $len = 0L
    try { $len = [System.IO.FileInfo]::new($File).Length } catch { return 'unreadable - kept' }
    if ($len -gt $script:CleanScanMaxBytes) { return "larger than $([int]($script:CleanScanMaxBytes / 1KB)) KB - cannot verify secret-free, kept" }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($File) } catch { return 'unreadable - kept' }
    foreach ($re in $script:GcSecretContentRes) {
        if ($text -match $re) { return 'secret-shaped content - kept, contents not printed' }
    }
    return $null
}

function Get-CleanTreeVerdict {
    <# $null = every contained file scanned clean; otherwise the reason the
       whole tree must be KEPT (reparse points and oversized trees refuse). #>
    param([Parameter(Mandatory)][string]$Dir)
    $seen = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Dir)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($d)) } catch { return 'unreadable subtree - kept' }
        foreach ($e in $entries) {
            $attr = $null
            try { $attr = [System.IO.File]::GetAttributes($e) } catch { }
            if ($null -eq $attr) { return 'entry unreadable during scan - kept' }
            if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { return 'contains a reparse point - kept' }
            if ($attr -band [System.IO.FileAttributes]::Directory) { $stack.Push($e); continue }
            $seen++
            if ($seen -gt $script:CleanScanMaxFiles) { return "more than $($script:CleanScanMaxFiles) files - cannot verify secret-free, kept" }
            if (Test-CleanCredentialName ([System.IO.Path]::GetFileName($e))) { return 'credential-shaped filename inside - kept' }
            $v = Get-CleanFileVerdict -File $e
            if ($v) { return "$v (inside this tree)" }
        }
    }
    return $null
}

function Get-CleanTreeSize {
    <# bytes under a path (files only; reparse points skipped). #>
    param([Parameter(Mandatory)][string]$Path)
    [long]$sum = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($d)) } catch { continue }
        foreach ($e in $entries) {
            $attr = $null
            try { $attr = [System.IO.File]::GetAttributes($e) } catch { }
            if ($null -eq $attr) { continue }
            if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($attr -band [System.IO.FileAttributes]::Directory) { $stack.Push($e); continue }
            try { $sum += [System.IO.FileInfo]::new($e).Length } catch { }
        }
    }
    return $sum
}

function Test-CleanEmptyDir {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try {
        $en = [System.IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator()
        try { return -not $en.MoveNext() } finally { $en.Dispose() }
    } catch { return $false }
}

# --- main ---------------------------------------------------------------------
try {
    # --- phase 0: relocate stray *.bak* under the config dir (enforcement net) ---
    # Non-destructive and UNCONDITIONAL (dry-run and armed mode alike): any
    # `*.bak*` file found inside %USERPROFILE%\.config\opencode - placed there
    # by any means, including manual commands - is MOVED, never deleted, into
    # %USERPROFILE%\.opencode\config-backups\. `-Recurse` does not descend
    # into reparse points; that stays true (no -FollowSymlink).
    if ($env:USERPROFILE) {
        $cfgDir = ConvertTo-CleanPath (Join-Path $env:USERPROFILE '.config\opencode')
        $bakDst = ConvertTo-CleanPath (Join-Path $env:USERPROFILE '.opencode\config-backups')
        if (Test-Path -LiteralPath $cfgDir -PathType Container) {
            if (-not (Test-Path -LiteralPath $bakDst -PathType Container)) {
                try { New-Item -ItemType Directory -Path $bakDst -Force -ErrorAction Stop | Out-Null }
                catch { Write-GcWarn "phase 0: cannot create $bakDst - $($_.Exception.Message)" }
            }
            if (Test-Path -LiteralPath $bakDst -PathType Container) {
                foreach ($f in @(Get-ChildItem -LiteralPath $cfgDir -Recurse -File -Force | Where-Object { $_.Name -like '*.bak*' })) {
                    $dest = Join-Path $bakDst $f.Name
                    $i = 1
                    while (Test-Path -LiteralPath $dest) {
                        $dest = Join-Path $bakDst ('{0}-{1}{2}' -f $f.BaseName, $i, $f.Extension)
                        $i++
                    }
                    try {
                        Move-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop
                        Write-GcNotice "moved: $($f.FullName) -> $dest"
                    } catch { Write-GcWarn "phase 0: move failed - $($f.FullName): $($_.Exception.Message)" }
                }
            }
        }
    } else {
        Write-GcWarn 'phase 0: %USERPROFILE% is not set - config-backups relocation skipped'
    }
    # roots first: a root that cannot be resolved is skipped, loudly
    $tempRoot = $null; $cacheRoot = $null; $cacheGithub = $null; $cacheV2 = $null
    $rootProblems = [System.Collections.Generic.List[string]]::new()

    if ($Root) {
        try {
            $tempRoot = ConvertTo-CleanPath $Root
            if ([System.IO.Path]::GetPathRoot($tempRoot) -eq $tempRoot) { throw 'resolves to a volume root' }
            $script:CleanRoots.Add($tempRoot)
            $cacheGithub = Join-Path $tempRoot 'github'
            $cacheV2 = Join-Path $cacheGithub 'v2'
        } catch { $rootProblems.Add("-Root ${Root}: $($_.Exception.Message)"); $tempRoot = $null }
    } else {
        $tempBase = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        if ($tempBase) {
            try {
                $tempRoot = ConvertTo-CleanPath (Join-Path $tempBase 'opencode')
                if ([System.IO.Path]::GetPathRoot($tempRoot) -eq $tempRoot) { throw 'resolves to a volume root' }
                $script:CleanRoots.Add($tempRoot)
            } catch { $rootProblems.Add("%TEMP%\opencode: $($_.Exception.Message)"); $tempRoot = $null }
        } else {
            $rootProblems.Add('%TEMP% and GetTempPath() are both unavailable')
        }

        if ($env:USERPROFILE) {
            try {
                $cacheRoot = ConvertTo-CleanPath (Join-Path $env:USERPROFILE '.cache\opencode')
                if ([System.IO.Path]::GetPathRoot($cacheRoot) -eq $cacheRoot) { throw 'resolves to a volume root' }
                $script:CleanRoots.Add($cacheRoot)
                $cacheGithub = Join-Path $cacheRoot 'github'
                $cacheV2 = Join-Path $cacheGithub 'v2'
            } catch { $rootProblems.Add('%USERPROFILE%\.cache\opencode: ' + $_.Exception.Message); $cacheRoot = $null }
        } else {
            $rootProblems.Add('%USERPROFILE% is not set')
        }
    }

    # structure dirs the empty-dir sweep must never remove (github\v2 is the
    # live cache layout, not junk)
    foreach ($d in @($tempRoot, $cacheRoot, $cacheGithub, $cacheV2)) {
        if ($d) { $script:CleanStructureDirs.Add($d) }
    }
    # unit level for the unclassified report: immediate children of these dirs
    foreach ($d in @($tempRoot, $cacheRoot, $cacheGithub, $cacheV2)) {
        if ($d) { $script:CleanUnitParents.Add($d) }
    }

    # --- keep-list registration (must succeed before any deletion) ------------
    $keepProblems = [System.Collections.Generic.List[string]]::new()
    function Add-CleanKeep {
        <# register one keep; an unnormalisable path is a recorded problem -
           never silently dropped from the law. Absent keeps are registered as
           prefix keeps (most conservative): PROTECT-IF-PRESENT - they are
           skipped with a note, never fatal. #>
        param(
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][string]$Path,
            [ValidateSet('prefix', 'file', 'auto')][string]$Kind = 'auto'
        )
        try {
            $abs = ConvertTo-CleanPath $Path
            if ($Kind -eq 'auto') {
                if (Test-Path -LiteralPath $abs -PathType Container) { $Kind = 'prefix' }
                elseif (Test-Path -LiteralPath $abs -PathType Leaf) { $Kind = 'file' }
                else {
                    $Kind = 'prefix'   # absent keeps are treated as subtrees (most conservative)
                    Write-GcWarn "keep not present, PROTECT-IF-PRESENT (registered as subtree): $Label ($Path)"
                }
            }
            if ($Kind -eq 'file') { $script:CleanKeepFiles.Add($abs) } else { $script:CleanKeepPrefixes.Add($abs) }
        } catch {
            $keepProblems.Add("$Label ($Path): $($_.Exception.Message)")
        }
    }

    if ($PSScriptRoot) {
        Add-CleanKeep -Label 'this script' -Path (Join-Path $PSScriptRoot 'gc-clean.ps1') -Kind auto
        Add-CleanKeep -Label 'reference directory' -Path (Join-Path $PSScriptRoot '..\reference') -Kind prefix
    } else {
        $keepProblems.Add('this script and the reference directory: script root unresolved')
    }
    foreach ($k in $KeepExtra) {
        if (-not $k) { $keepProblems.Add('-KeepExtra: empty path ignored'); continue }
        Add-CleanKeep -Label '-KeepExtra' -Path $k -Kind auto
    }

    # defence in depth: -Force with an unresolvable keep-list is a loud stop
    if ($Force -and $keepProblems.Count -gt 0) {
        foreach ($p in $keepProblems) { Write-GcFail "keep-list cannot be resolved: $p" }
        Write-GcResult -Code $script:GcExitPre -Props @{ message = 'keep-list cannot be resolved - refusing to delete' }
    }
    foreach ($p in $keepProblems) { Write-GcWarn "keep-list incomplete: $p" }
    foreach ($p in $rootProblems) { Write-GcWarn "root skipped: $p" }

    # --- scan ------------------------------------------------------------------
    function Add-CleanReport {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Reason)
        $script:CleanReported.Add([pscustomobject]@{ Path = $Path; Reason = $Reason })
    }

    function Add-CleanJunk {
        <# a pattern hit: size it, verify it is secret-free, then either queue
           it for deletion or downgrade it to reported/kept. #>
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][ValidateSet('file', 'dir')][string]$Kind,
            [Parameter(Mandatory)][string]$Class
        )
        $verdict = if ($Kind -eq 'file') { Get-CleanFileVerdict -File $Path } else { Get-CleanTreeVerdict -Dir $Path }
        if ($verdict) {
            Add-CleanReport -Path $Path -Reason "$Class candidate but $verdict"
            Write-GcWarn "kept ($Class): $Path - $verdict"
            return
        }
        [long]$size = 0
        if ($Kind -eq 'file') {
            try { $size = [System.IO.FileInfo]::new($Path).Length } catch { $size = 0 }
        } else {
            $size = Get-CleanTreeSize -Path $Path
        }
        $script:CleanWouldDelete.Add([pscustomobject]@{ Path = $Path; Kind = $Kind; Class = $Class; Size = $size })
    }

    foreach ($root in $script:CleanRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-GcWarn "root missing, skipped: $root"
            continue
        }
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try { $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($dir)) }
            catch { Write-GcWarn "unreadable directory skipped: $dir - $($_.Exception.Message)"; continue }
            foreach ($entry in $entries) {
                $attr = $null
                try { $attr = [System.IO.File]::GetAttributes($entry) } catch { }
                if ($null -eq $attr) { Add-CleanReport -Path $entry -Reason 'vanished or unreadable during the scan'; continue }

                $name = [System.IO.Path]::GetFileName($entry)
                $parent = [System.IO.Path]::GetDirectoryName($entry)
                $isDir = ($attr -band [System.IO.FileAttributes]::Directory) -ne 0

                if ($attr -band [System.IO.FileAttributes]::ReparsePoint) {
                    Add-CleanReport -Path $entry -Reason 'reparse point - never followed or deleted'
                    continue
                }
                if (Test-CleanKept -Path $entry) {
                    $script:CleanKeepHits.Add([pscustomobject]@{ Path = $entry; Kind = $(if ($isDir) { 'dir' } else { 'file' }) })
                    continue
                }
                if (-not $isDir -and ($name -like '*.tgz')) {
                    $script:CleanKeepHits.Add([pscustomobject]@{ Path = $entry; Kind = 'tgz' })
                    continue
                }

                if ($isDir) {
                    if (Test-CleanStructureDir -Path $entry) { $stack.Push($entry); continue }   # github / github\v2: descend
                    if ($cacheV2 -and ($parent -ieq $cacheV2) -and (Test-CleanLiveCache -Name $name)) {
                        # live cache entries are keep-list: recorded, never scanned, never touched
                        $script:CleanKeepHits.Add([pscustomobject]@{ Path = $entry; Kind = 'live-cache' })
                        continue
                    }
                    if ($cacheGithub -and ($parent -ieq $cacheGithub) -and ($name -ine 'v2')) {
                        Add-CleanJunk -Path $entry -Kind dir -Class 'old-layout'
                        continue
                    }
                    if ($cacheV2 -and ($parent -ieq $cacheV2) -and ($name -like '*--*--*') -and ($script:CleanLiveCachePrefixes.Count -gt 0) -and -not (Test-CleanLiveCache -Name $name)) {
                        Add-CleanJunk -Path $entry -Kind dir -Class 'stale-cache'
                        continue
                    }
                    if ($name -like '*.bak*') {
                        Add-CleanJunk -Path $entry -Kind dir -Class 'bak'
                        continue
                    }
                    if (Test-CleanUnitParent -Parent $parent) {
                        $script:CleanUnclassified++
                        Add-CleanReport -Path $entry -Reason 'unclassified - kept'
                    }
                    $stack.Push($entry)
                    continue
                }

                if (Test-CleanCredentialName -Name $name) {
                    Add-CleanReport -Path $entry -Reason 'credential-shaped filename - kept'
                    continue
                }
                if ($name -like '*.bak*') {
                    Add-CleanJunk -Path $entry -Kind file -Class 'bak'
                    continue
                }
                if (Test-CleanUnitParent -Parent $parent) {
                    $script:CleanUnclassified++
                    Add-CleanReport -Path $entry -Reason 'unclassified - kept'
                }
            }
        }
    }

    # --- report / delete -------------------------------------------------------
    $items = $script:CleanWouldDelete.Count
    [long]$bytes = 0
    foreach ($i in $script:CleanWouldDelete) { $bytes += $i.Size }

    $deleted = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $removedEmpty = [System.Collections.Generic.List[string]]::new()
    [long]$freed = 0

    if ($Force) {
        # deletion order: files first, then classified trees, then the dirs
        # those deletions left empty
        foreach ($item in @($script:CleanWouldDelete | Where-Object { $_.Kind -eq 'file' } | Sort-Object -Property Path)) {
            if (-not (Test-CleanUnderRoot -Path $item.Path) -or (Test-CleanKept -Path $item.Path)) {
                $failures.Add("$($item.Path): refused - outside a resolved root or on the keep-list")
                continue
            }
            if (-not (Test-Path -LiteralPath $item.Path)) { continue }   # vanished since the scan: nothing to do
            try { Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop; $deleted.Add($item); $freed += $item.Size }
            catch { $failures.Add("$($item.Path): $($_.Exception.Message)") }
        }
        foreach ($item in @($script:CleanWouldDelete | Where-Object { $_.Kind -eq 'dir' } | Sort-Object -Property Path)) {
            if (-not (Test-CleanUnderRoot -Path $item.Path) -or (Test-CleanKept -Path $item.Path)) {
                $failures.Add("$($item.Path): refused - outside a resolved root or on the keep-list")
                continue
            }
            if (-not (Test-Path -LiteralPath $item.Path)) { continue }
            try { Remove-Item -LiteralPath $item.Path -Force -Recurse -ErrorAction Stop; $deleted.Add($item); $freed += $item.Size }
            catch { $failures.Add("$($item.Path): $($_.Exception.Message)") }
        }
        # empty-dir sweep: only parents a deletion may have emptied, never the
        # roots and never the github\ / github\v2 structure
        $starts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $deleted) {
            $p = [System.IO.Path]::GetDirectoryName($item.Path)
            if ($p) { $starts.Add($p) }
        }
        foreach ($start in $starts) {
            $d = $start
            while ($d) {
                if (-not (Test-CleanUnderRoot -Path $d)) { break }
                if ((Test-CleanKept -Path $d) -or (Test-CleanStructureDir -Path $d)) { break }
                if (-not (Test-CleanEmptyDir -Path $d)) { break }
                try { Remove-Item -LiteralPath $d -Force -ErrorAction Stop; $removedEmpty.Add($d) }
                catch { $failures.Add("${d}: $($_.Exception.Message)"); break }
                $d = [System.IO.Path]::GetDirectoryName($d)
            }
        }
    }

    if ($Force) {
        if ($deleted.Count -gt 0) {
            Write-GcNotice 'deleted:'
            foreach ($i in @($deleted | Sort-Object -Property Path)) {
                Write-GcNotice ("  {0,12:N0} B  [{1}] {2}" -f $i.Size, $i.Class, $i.Path)
            }
        } else {
            Write-GcNotice 'deleted: nothing'
        }
        if ($removedEmpty.Count -gt 0) { Write-GcNotice "empty directories removed: $($removedEmpty.Count)" }
        Write-GcNotice "freed $freed B across $($deleted.Count) item(s)"
    } else {
        if ($items -gt 0) {
            Write-GcNotice 'would-delete (dry-run):'
            foreach ($i in @($script:CleanWouldDelete | Sort-Object -Property Path)) {
                Write-GcNotice ("  {0,12:N0} B  [{1}] {2}" -f $i.Size, $i.Class, $i.Path)
            }
            Write-GcNotice "would free $bytes B across $items item(s); -Force (only while --clean is armed) performs the deletion"
        } else {
            Write-GcNotice 'would-delete: none - sweep is clean'
        }
    }

    if ($script:CleanReported.Count -gt 0) {
        Write-GcNotice "reported - kept: $($script:CleanReported.Count) item(s) ($($script:CleanUnclassified) unclassified) - never deleted"
        $limit = if ($Detailed) { $script:CleanReported.Count } else { [Math]::Min(20, $script:CleanReported.Count) }
        $shown = 0
        foreach ($r in @($script:CleanReported | Sort-Object -Property Path)) {
            if ($shown -ge $limit) { break }
            Write-GcNotice "  reported - kept: $($r.Path) - $($r.Reason)"
            $shown++
        }
        if ($shown -lt $script:CleanReported.Count) {
            Write-GcNotice "  ... $($script:CleanReported.Count - $shown) more item(s) - -Detailed lists all"
        }
    } else {
        Write-GcNotice 'reported - kept: none'
    }

    if ($Detailed) {
        foreach ($k in @($script:CleanKeepHits | Sort-Object -Property Path)) {
            Write-GcNotice "  kept [$($k.Kind)]: $($k.Path)"
        }
    }

    # keep-list confirmation: the baseline keeps, checked after the sweep.
    # PROTECT-IF-PRESENT: an absent keep is skipped with a note - never fatal.
    $keepPresent = [System.Collections.Generic.List[string]]::new()
    $keepAbsent = [System.Collections.Generic.List[string]]::new()
    if ($PSScriptRoot) {
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'gc-clean.ps1') -PathType Leaf) { $keepPresent.Add('this script') } else { $keepAbsent.Add('this script') }
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\reference') -PathType Container) { $keepPresent.Add('reference directory') } else { $keepAbsent.Add('reference directory') }
    }
    if ($script:CleanLiveCachePrefixes.Count -gt 0) {
        $liveFound = 0
        if ($cacheV2 -and (Test-Path -LiteralPath $cacheV2 -PathType Container)) {
            $liveFound = @(Get-ChildItem -Force -LiteralPath $cacheV2 -Directory | Where-Object { Test-CleanLiveCache -Name $_.Name }).Count
        }
        if ($liveFound -ge $script:CleanLiveCachePrefixes.Count) {
            $keepPresent.Add("live v2 cache entries $liveFound/$($script:CleanLiveCachePrefixes.Count)")
        } else {
            $keepAbsent.Add("live v2 cache entries ($liveFound/$($script:CleanLiveCachePrefixes.Count) present)")
        }
    }
    $tgzCount = @($script:CleanKeepHits | Where-Object { $_.Kind -eq 'tgz' }).Count
    if ($tgzCount -gt 0) { $keepPresent.Add("$tgzCount *.tgz pack(s)") }
    if ($keepPresent.Count -gt 0) { Write-GcNotice "keep-list intact: $($keepPresent -join ', ')" }
    if ($keepAbsent.Count -gt 0) { Write-GcWarn "keep-list item(s) not present - skipped, never fatal: $($keepAbsent -join ', ')" }

    # repo-local untracked: listed only - this tool never deletes them
    $untracked = @()
    if ($RepoRoot -and (Test-Path -LiteralPath $RepoRoot)) {
        $gitTop = $null
        try { $gitTop = (Get-GcGit -Root $RepoRoot -Argv @('rev-parse', '--show-toplevel') | Select-Object -First 1).Trim() } catch { }
        if ($gitTop) {
            try { $untracked = @(Get-GcGit -Root $gitTop -Argv @('ls-files', '--others', '--exclude-standard')) }
            catch { Write-GcWarn "untracked listing skipped: $($_.Exception.Message)" }
        } else {
            Write-GcInfo "RepoRoot is not a git work tree - no untracked listing ($RepoRoot)"
        }
    }
    if ($untracked.Count -gt 0) {
        if ($Force) {
            # -Force ran: untracked files are listed dry-run only - here the
            # count is awareness; the itemized listing belongs to the dry run
            Write-GcNotice "repo-local untracked: $($untracked.Count) present - never deleted by this tool (dry-run listing only)"
        } else {
            Write-GcNotice "repo-local untracked (dry-run listing only - never deleted by this tool): $($untracked.Count)"
            $show = if ($Detailed) { $untracked } else { @($untracked | Select-Object -First 10) }
            foreach ($u in $show) { Write-GcNotice "  [untracked] $u" }
            if (-not $Detailed -and $untracked.Count -gt 10) {
                Write-GcNotice "  ... $($untracked.Count - 10) more (-Detailed lists all)"
            }
        }
    }

    if ($Force) {
        if ($failures.Count -gt 0) {
            foreach ($f in $failures) { Write-GcFail "deletion failed: $f" }
            Write-GcResult -Code $script:GcExitFail -Props @{ mode = 'clean'; items = $deleted.Count; bytes = $freed; message = "$($failures.Count) deletion(s) failed" }
        }
        Write-GcResult -Props @{ mode = 'clean'; items = $deleted.Count; bytes = $freed }
    }
    Write-GcResult -Props @{ mode = 'dry-run'; items = $items; bytes = $bytes }
} catch [GcException] {
    Write-GcFail $_.Exception.Message
    Write-GcResult -Code $_.Exception.Code -Props @{ message = $_.Exception.Message }
} catch {
    Write-GcFail "unexpected: $($_.Exception.Message)"
    Write-GcResult -Code $script:GcExitFail -Props @{ message = $_.Exception.Message }
}