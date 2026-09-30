<#
    backup-config.ps1 - copy a config file into ~\.opencode\config-backups with keep-last-5 retention.

    Usage: scripts\backup-config.ps1 -Path <file>

    Pure byte copy; file contents are never read or modified. Outputs only the
    created backup path (one line). See reference\backup-convention.md.
#>
param(
    [Parameter(Mandatory=$true)][string]$Path
)

$resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
if (-not $resolved) {
    throw "backup-config.ps1: file not found: '$Path'"
}
if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "backup-config.ps1: not a file: '$resolved'"
}

$destRoot = Join-Path $env:USERPROFILE '.opencode\config-backups'
New-Item -ItemType Directory -Path $destRoot -Force | Out-Null

# Guard: never back up a file that already lives inside the backup root.
$destRootPrefix = $destRoot.TrimEnd('\') + '\'
if ($resolved.Path.StartsWith($destRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "backup-config.ps1: refusing to back up a file inside the backup root: '$destRoot'"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$name = Split-Path -Leaf $resolved
$dest = Join-Path $destRoot "$stamp-$name.bak"

Copy-Item -LiteralPath $resolved -Destination $dest -Force

# Timestamp-prefixed names sort lexicographically; keep only the newest 5.
Get-ChildItem -LiteralPath $destRoot -Filter "*-$name.bak" -File |
    Sort-Object -Property Name -Descending |
    Select-Object -Skip 5 |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

Write-Output $dest