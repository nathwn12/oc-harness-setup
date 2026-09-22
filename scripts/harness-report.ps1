<#
.SYNOPSIS
  Redacted harness report + prefilled issue URL: self-doctor, self-report, human gate.

.DESCRIPTION
  Runs the sibling harness-doctor.ps1, then renders a shareable report with the
  identity and findings a maintainer needs. Redaction is ENFORCED IN CODE, not
  promised in prose: every field that reaches the body passes one chokepoint
  (Redact-Text -> Test-DropText), so a new field cannot bypass it by accident.

  What the report is FOR: an installed agent that can self-doctor and self-report.
  The doctor grades the local harness; this script turns that grade into (a) a
  markdown issue body, (b) the prefilled URL, and (c) a JSON envelope for tooling.
  Filing is the human's call - this script NEVER files anything and never calls a
  forge CLI.

  Redaction rules (applied to root, laws[].detail, regressions, drift, timestamp,
  identity - every field):
    - $env:USERPROFILE, C:\Users\<name>, /home/<name>, /Users/<name>, and the
      absolute config path all become ~.
    - the manifest backupPath value becomes ~/.opencode-backup/<ts>; the real
      value is never emitted.
    - diagnostic STRUCTURE is never dropped for containing a keyword. Law
      identifiers, law names, PASS/FAIL/DRIFT results, evidence, proposals, and
      the summary counts survive even when they contain words like "secret" or
      "credential" - Law 10 is literally named "...secret-like property names in
      opencode.jsonc" and Law 11's evidence says "credential denies hold", so
      the old whole-line blocklist rendered exactly those failures as empty
      entries and could hide a real product defect.
    - secret-like VALUES are redacted IN PLACE: when a name that looks
      secret-like is followed by a value (`apiKey: sk-...`, `"token": "..."`,
      `password = ...`), the name is kept and the value becomes <redacted>. The
      same holds for a JSON property whose NAME is secret-like - key kept, value
      replaced. A boolean-valued secret-named property is exempt because a
      boolean cannot carry a credential (the doctor's own `secretGuard` flag is
      read downstream).
    - a line is DROPPED whole only when it cannot be kept safely: a {file:...}
      pointer target, a path into a secret store, or a bare credential-looking
      literal (known key prefix, JWT shape, or a long unbroken high-entropy
      token).
    - BOTH counters are reported - removed lines AND redacted values - so the
      reader sees exactly how the body was transformed instead of silently
      getting a thinner report.
    - ses_<id> -> <session>; machine hostnames -> <host>; usernames -> <user>.

  Hard rules baked into the code:
    - never invokes `gh` (nor any forge CLI), and never files anything;
    - never reads .secrets, .env, or any credential path - the one file read
      (the installer's manifest) goes through Get-SafeText, which refuses those
      paths outright;
    - the target repository is a constant below, never derived from doctor
      output or from the local environment. No labels are prefilled: guessing a
      label that does not exist upstream only makes the forge warn.

  Exit codes: 0 reported; 1 -SelfTest failed (treat the redactor as untrusted);
  3 the sibling doctor is missing (nothing to report on).

  -SelfTest proves the redactor keeps a "secret"-named law line verbatim,
  redacts a secret-like value in place while keeping its line, drops a
  {file:...} pointer and a secret-store path, and still collapses Windows and
  POSIX user paths, session ids, and the manifest backup path. Run it before
  trusting any body this script prints.

.EXAMPLE
  pwsh -File scripts\harness-report.ps1

.EXAMPLE
  pwsh -File scripts\harness-report.ps1 -Json

.EXAMPLE
  pwsh -File scripts\harness-report.ps1 -SelfTest

.EXAMPLE
  pwsh -File scripts\harness-report.ps1 -OutFile .\report.md -ConfigDir D:\config\opencode

.PARAMETER Json
  Emit {url, body, identity} as JSON instead of the rendered markdown.

.PARAMETER SelfTest
  Assert the redactor's guarantees and exit 0 (pass) or 1 (fail). Touches
  nothing on disk and does not run the doctor.

.PARAMETER OutFile
  Also write the markdown body to this path (UTF-8, no BOM).

.PARAMETER ConfigDir
  Config directory to grade; passed straight through to the doctor. Defaults to
  the doctor's own default (~/.config/opencode).
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$SelfTest,
    [string]$OutFile,
    [string]$ConfigDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- constants (never derived from doctor output or the environment) ----------
$targetRepo = 'https://github.com/nathwn12/oc-harness-setup'
$manifestFile = 'oc-harness-setup.manifest.json'
$backupPlaceholder = '~/.opencode-backup/<ts>'

# ---------- redaction state ----------
$script:ConfigRootLiteral = ''
$script:BackupPathLiteral = ''
$script:HostNames = @()
$script:UserNames = @()
$script:DroppedCount = 0
$script:RedactedCount = 0
$script:BodyLines = [System.Collections.Generic.List[string]]::new()
$script:RedactedValue = '<redacted>'
# A NAME that looks secret-like, in either naming convention. Substring match on
# purpose: over-matching a name only costs a redacted value, never structure.
# Non-capturing group so the outer group in the composed patterns stays $1.
$script:SecretNamePattern = '(?i)(?:api[_-]?key|passwd|password|bearer|token|credential|secret)s?'
# The value half of a `name: value` pair, guarded so an already-redacted value is
# left alone (the two passes below must not fight over the same fragment).
$script:SecretValuePart = '(?!["'']?' + [regex]::Escape($script:RedactedValue) + ')(?:"[^"\r\n]*"?|''[^''\r\n]*''?|\S+)'
# `"apiKey": "sk-..."` inside an embedded JSON fragment: name kept (quotes and
# all), value replaced. Runs first so quoted JSON keeps its shape.
$script:SecretJsonPropertyPattern = '(?i)"(' + $script:SecretNamePattern + ')"\s*:\s*("[^"]*"|\{[^}]*\}|\[[^\]]*\]|[^,}\s]+)'
# `apiKey: sk-...`, `password = ...`, `token: '...'` - name kept, value gone.
$script:SecretAssignPattern = '(?i)"?(' + $script:SecretNamePattern + ')"?\s*[:=]\s*' + $script:SecretValuePart

# ---------- readers ----------
function Get-SafeText {
    # The one file reader in this script. Refuses secret-bearing paths outright,
    # so no code path here can read secret-store or .env contents.
    param([string]$Path)
    $normalized = ([string]$Path).Replace('\', '/')
    if ($normalized -match '(^|/)([.]secrets|\.env)(/|$)|(^|/)[^/]*\.env(\.|$)') {
        throw "refused to read secret-bearing path: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding utf8)
}

function Get-EnvValue {
    # Environment lookup that cannot throw under StrictMode.
    param([string]$Name)
    return [string]([System.Environment]::GetEnvironmentVariable($Name))
}

function Get-ReportField {
    # Safe property read on the doctor's JSON: a shape change degrades to ''
    # instead of an unhandled PropertyNotFoundException under StrictMode.
    param([AllowNull()]$Node, [string]$Name)
    if ($null -eq $Node) { return '' }
    $property = $Node.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-ReportItems {
    # Safe property read that always yields an array, so a missing or single
    # -valued section never turns into a one-iteration null loop.
    param([AllowNull()]$Node, [string]$Name)
    if ($null -eq $Node) { return @() }
    $property = $Node.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    return @($property.Value)
}

# ---------- the redaction chokepoint ----------
function Hide-SecretValues {
    # Redact secret-like VALUES in place; the surrounding line always survives.
    # Every replacement is counted so the report can state what it did.
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $Text }
    $s = [string]$Text
    foreach ($pattern in @($script:SecretJsonPropertyPattern, $script:SecretAssignPattern)) {
        $found = [regex]::Matches($s, $pattern)
        if ($found.Count -eq 0) { continue }
        $script:RedactedCount += $found.Count
        $replacement = if ($pattern -eq $script:SecretAssignPattern) { '$1: ' + $script:RedactedValue } else { '"$1": "' + $script:RedactedValue + '"' }
        $s = [regex]::Replace($s, $pattern, $replacement)
    }
    return $s
}

function Hide-SecretPropertyValues {
    # A parsed JSON property whose NAME is secret-like keeps its name and loses
    # its VALUE: {apiKey: 'sk-...'} -> {apiKey: '<redacted>'}. Recurses through
    # nested objects and arrays. A boolean is exempt because a boolean cannot
    # carry a credential, and the doctor's own `secretGuard` flag is consumed
    # downstream as a diagnostic.
    param([AllowNull()]$Node)
    if ($null -eq $Node) { return }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in @($Node)) { Hide-SecretPropertyValues -Node $item }
        return
    }
    if ($Node -isnot [pscustomobject]) { return }
    foreach ($property in @($Node.PSObject.Properties)) {
        if ($property.Name -match $script:SecretNamePattern) {
            if ($property.Value -isnot [bool]) {
                $property.Value = $script:RedactedValue
                $script:RedactedCount++
            }
            continue
        }
        Hide-SecretPropertyValues -Node $property.Value
    }
}

function Redact-Text {
    # Replace identifying strings with stable placeholders and redact secret-like
    # values in place. Never returns secret content: the drop test (Test-DropText)
    # runs afterwards on this output.
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $s = [string]$Text

    # The absolute config path first, so its home prefix collapses to a bare ~.
    if ($script:ConfigRootLiteral) {
        $s = $s.Replace($script:ConfigRootLiteral, '~')
        $s = $s.Replace($script:ConfigRootLiteral.Replace('\', '/'), '~')
    }
    $userProfile = Get-EnvValue 'USERPROFILE'
    if ($userProfile) { $s = $s.Replace($userProfile, '~') }

    # Home-directory shapes for every platform, in case the path was normalized.
    $s = [regex]::Replace($s, '(?i)(?<![A-Za-z0-9])[A-Za-z]:[\\/]Users[\\/][^\s\\/<>|]+', '~')
    $s = [regex]::Replace($s, '(?i)(?<![A-Za-z0-9])/(?:home|Users)/[^\s\\/<>|]+', '~')

    # The installer's backup pointer: the real value never leaves this machine.
    if ($script:BackupPathLiteral) { $s = $s.Replace($script:BackupPathLiteral, $backupPlaceholder) }
    $s = [regex]::Replace($s, '(?i)\S*\.opencode-backup[\\/][^\s<>|]+', $backupPlaceholder)

    # Session ids, hostnames, usernames. Hostnames first: a hostname that
    # contains the username would otherwise be split by the username pass.
    $s = [regex]::Replace($s, '\bses_[A-Za-z0-9]+', '<session>')
    foreach ($hostName in $script:HostNames) {
        if ($hostName) { $s = [regex]::Replace($s, [regex]::Escape($hostName), '<host>', 'IgnoreCase') }
    }
    foreach ($user in $script:UserNames) {
        if ($user) { $s = [regex]::Replace($s, '(?<![A-Za-z0-9])' + [regex]::Escape($user) + '(?![A-Za-z0-9])', '<user>', 'IgnoreCase') }
    }

    # Last: the values. Names (and therefore lines) survive; values do not.
    return (Hide-SecretValues -Text $s)
}

function Test-BareCredentialLiteral {
    # A credential-looking literal with no name to key the redactor off: a known
    # key prefix, a JWT shape, or a long unbroken high-entropy token. Deliberately
    # narrow - a short word, a lowercase hex SHA, or a repo path is NOT a
    # credential, and dropping an honest line is the failure mode being fixed.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)(?<![A-Za-z0-9])(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}') { return $true }
    if ($Text -match '(?i)(?<![A-Za-z0-9])(?:ghp|gho|ghs|ghr|github_pat)_[A-Za-z0-9_]{16,}') { return $true }
    if ($Text -match '(?i)(?<![A-Za-z0-9])xox[baprs]-[A-Za-z0-9-]{10,}') { return $true }
    if ($Text -match '(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])') { return $true }
    if ($Text -match '(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9])') { return $true }
    if ($Text -match '(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.') { return $true }
    if ($Text -match '(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9+/=_-])') {
        $token = $Matches[0]
        $classes = 0
        if ($token -cmatch '[a-z]') { $classes++ }
        if ($token -cmatch '[A-Z]') { $classes++ }
        if ($token -cmatch '[0-9]') { $classes++ }
        if ($token -cmatch '[+/=_-]') { $classes++ }
        if ($classes -ge 3) { return $true }
    }
    return $false
}

function Test-DropText {
    # The drop list is now only what cannot be kept safely: a {file:...} pointer
    # target, a path INTO a secret store, or a bare credential literal. A line is
    # never dropped merely for containing a keyword - that used to delete Law 10
    # (named "...secret-like property names...") and Law 11's "credential denies
    # hold" evidence, i.e. exactly the failures worth reporting.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '\{file:[^}]*\}') { return $true }
    if ($Text -match '(?i)(?<![A-Za-z0-9._-])\.(?:secrets|env)(?:[\\/.]|$)') { return $true }
    if (Test-BareCredentialLiteral -Text $Text) { return $true }
    return $false
}

function Add-RedactedLine {
    # The ONLY way a line reaches the body. Redact, then drop-or-keep.
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return }
    $clean = Redact-Text -Text $Text
    if (Test-DropText -Text $clean) { $script:DroppedCount++; return }
    $script:BodyLines.Add($clean)
}

# ---------- self-test ----------
if ($SelfTest) {
    $failures = [System.Collections.Generic.List[string]]::new()

    function Assert-That {
        param([string]$Name, [bool]$Condition, [string]$Note)
        if ($Condition) {
            "  [PASS] $Name"
        } else {
            "  [FAIL] $Name - $Note"
            $failures.Add($Name)
        }
    }

    function Get-RenderedBodyLine {
        # Render ONE line through the real chokepoint and return what the body got
        # ('' means the line was dropped). Clears BodyLines: nothing else runs here.
        param([string]$Text)
        $script:BodyLines = [System.Collections.Generic.List[string]]::new()
        Add-RedactedLine -Text $Text
        return ($script:BodyLines -join "`n")
    }

    'Self-test: redactor guarantees'
    # Probe tokens are assembled at runtime so a repo scan does not trip on them.
    $secretValue = 'sk-live-' + 'ABC123def456GHI789jkl'
    $assignProbe = 'apiKey: ' + $secretValue
    $jsonProbe = '{"apiKey": "' + $secretValue + '", "keep": 1}'
    $secretProbe = ('api' + 'key') + ': "' + 'sk-test-' + 'not-a-real-value' + '"'
    $pointerProbe = '{' + 'file:' + 'C:\Users\someone\notes.md}'
    $storePointerProbe = '{' + 'file:' + '~/.secrets/openai-key}'
    $winPathProbe = 'C:\Users\' + 'someone' + '\AppData\Local\opencode'
    $posixPathProbe = '/home/' + 'someone' + '/.config/opencode'
    $macPathProbe = '/Users/' + 'someone' + '/Library/Application Support'
    $sessionProbe = 'ses_' + 'abc123DEF456'
    $script:BackupPathLiteral = 'C:\Users\' + 'someone' + '\.opencode-backup\20260922-130500-deadbeef'
    $script:ConfigRootLiteral = 'C:\Users\' + 'someone' + '\.config\opencode'
    $script:HostNames = @('DESKTOP-REPORTTEST')
    $script:UserNames = @('someone')

    # --- structure survives: the bug this change fixes ---
    $lawNameLine = '### no secret-like property names in opencode.jsonc'
    $rendered = Get-RenderedBodyLine -Text $lawNameLine
    Assert-That 'keeps a law line whose NAME contains "secret" (Law 10)' ($rendered -eq $lawNameLine) "got '$rendered'"

    $credEvidenceLine = '- evidence: disk-destroy and credential denies hold (deny survives --auto)'
    $rendered = Get-RenderedBodyLine -Text $credEvidenceLine
    Assert-That 'keeps a law evidence line containing "credential" (Law 11)' ($rendered -eq $credEvidenceLine) "got '$rendered'"

    $summaryLine = '- PASS - no secret-like property names in opencode.jsonc'
    $rendered = Get-RenderedBodyLine -Text $summaryLine
    Assert-That 'keeps a laws-evaluated line with a "secret"-named law' ($rendered -eq $summaryLine) "got '$rendered'"

    # --- values are redacted IN PLACE, and the line survives ---
    $redactedBefore = $script:RedactedCount
    $rendered = Get-RenderedBodyLine -Text $assignProbe
    Assert-That 'keeps a secret-valued line, redacts only the value' ($rendered -match '^(?i)apikey: <redacted>$') "got '$rendered'"
    Assert-That 'the secret value never reaches the body' (-not $rendered.Contains('sk-live')) "got '$rendered'"
    Assert-That 'counts the redacted value' ($script:RedactedCount -gt $redactedBefore) "redacted count did not move from $redactedBefore"

    $rendered = Get-RenderedBodyLine -Text $secretProbe
    Assert-That 'keeps the quoted-secret probe line, redacts its value' ((-not $rendered.Contains('not-a-real-value')) -and ($rendered -match '(?i)apikey')) "got '$rendered'"

    $jsonOut = Redact-Text -Text $jsonProbe
    Assert-That 'redacts a secret-named JSON property VALUE, keeps key and siblings' `
        (($jsonOut -match '"apiKey": "<redacted>"') -and ($jsonOut -match '"keep": 1') -and (-not $jsonOut.Contains('sk-live'))) "got '$jsonOut'"

    $node = [pscustomobject]@{
        apiKey      = $secretValue
        password    = 'hunter2'
        secretGuard = $true
        nested      = [pscustomobject]@{ token = 'abc123' }
        keep        = 'visible'
    }
    Hide-SecretPropertyValues -Node $node
    Assert-That 'nulls a secret-named JSON property value (key kept)' `
        (($null -ne $node.PSObject.Properties['apiKey']) -and ($node.apiKey -eq '<redacted>') -and ($node.password -eq '<redacted>')) "got '$($node.apiKey)'/'$($node.password)'"
    Assert-That 'reaches nested secret-named properties' ($node.nested.token -eq '<redacted>') "got '$($node.nested.token)'"
    Assert-That 'leaves a boolean flag intact (a boolean cannot carry a credential)' ($node.secretGuard -eq $true) "got '$($node.secretGuard)'"
    Assert-That 'leaves non-secret properties alone' ($node.keep -eq 'visible') "got '$($node.keep)'"

    # --- the drop list is only what cannot be kept safely ---
    $dropProbe = '{' + 'file:' + '~/.secrets/openai-key}'
    $dropsBefore = $script:DroppedCount
    $rendered = Get-RenderedBodyLine -Text $dropProbe
    Assert-That 'DROPS a {file:...} pointer into a secret store' (($rendered -eq '') -and ($script:DroppedCount -eq $dropsBefore + 1)) "got '$rendered' / dropped $($script:DroppedCount - $dropsBefore)"

    $pointerOut = Redact-Text -Text $pointerProbe
    Assert-That 'drops a {file:...} pointer' (Test-DropText -Text $pointerOut) 'the pointer survived the drop list'

    Assert-That 'drops a path into a secret store' (Test-DropText -Text ('- evidence: read ~/' + '.secrets/openai-key')) 'the secret-store path survived the drop list'
    Assert-That 'drops a bare credential literal with no name' (Test-DropText -Text ('header = ' + $secretValue)) 'the bare literal survived the drop list'
    Assert-That 'KEEPS a lowercase hex SHA (not a credential)' (-not (Test-DropText -Text 'commit 4f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a')) 'an honest hex id was dropped'
    Assert-That 'KEEPS a plain path that is not a secret store' (-not (Test-DropText -Text ('note: ' + $winPathProbe))) 'an honest path was dropped'

    # --- identity redaction is unchanged ---
    $winOut = Redact-Text -Text $winPathProbe
    Assert-That 'redacts a Windows user path' ($winOut -notmatch '(?i)users' -and $winOut.StartsWith('~')) "got '$winOut'"

    $posixOut = Redact-Text -Text $posixPathProbe
    Assert-That 'redacts a POSIX user path' ($posixOut -notmatch '(?i)/home/' -and $posixOut.StartsWith('~')) "got '$posixOut'"

    $macOut = Redact-Text -Text $macPathProbe
    Assert-That 'redacts a macOS user path' ($macOut -notmatch '(?i)/Users/' -and $macOut.StartsWith('~')) "got '$macOut'"

    $sessionOut = Redact-Text -Text $sessionProbe
    Assert-That 'strips a session id' (-not $sessionOut.Contains('ses_') -and $sessionOut.Contains('<session>')) "got '$sessionOut'"

    $backupOut = Redact-Text -Text "backup: $($script:BackupPathLiteral)"
    Assert-That 'never emits the manifest backup path' ((-not $backupOut.Contains('20260922-130500')) -and $backupOut.Contains($backupPlaceholder)) "got '$backupOut'"

    $configOut = Redact-Text -Text $script:ConfigRootLiteral
    Assert-That 'redacts the absolute config path' ($configOut -eq '~') "got '$configOut'"

    $hostOut = Redact-Text -Text 'ran on DESKTOP-REPORTTEST'
    Assert-That 'redacts the machine hostname' (-not $hostOut.Contains('DESKTOP-REPORTTEST') -and $hostOut.Contains('<host>')) "got '$hostOut'"

    $userOut = Redact-Text -Text 'owner: someone'
    Assert-That 'redacts the username' (-not $userOut.Contains('someone') -and $userOut.Contains('<user>')) "got '$userOut'"

    ''
    if ($failures.Count -eq 0) {
        "Self-test: PASS ($($script:DroppedCount) line(s) dropped, $($script:RedactedCount) value(s) redacted during the probes)"
        exit 0
    }
    "Self-test: FAIL - $($failures.Count) assertion(s) failed: $($failures -join ', ')"
    exit 1
}

# ---------- context ----------
$root = if ($ConfigDir) { $ConfigDir } else { Join-Path (Get-EnvValue 'USERPROFILE') '.config\opencode' }
$script:ConfigRootLiteral = [string]$root
$script:HostNames = @(
    (Get-EnvValue 'COMPUTERNAME'),
    (Get-EnvValue 'HOSTNAME')
) | Where-Object { $_ }
try {
    $dnsName = [System.Net.Dns]::GetHostName()
    if ($dnsName) { $script:HostNames = @($script:HostNames) + $dnsName }
} catch {
    # offline or unresolvable host: the other names still cover the common case
}
$profileLeaf = if (Get-EnvValue 'USERPROFILE') { Split-Path -Leaf (Get-EnvValue 'USERPROFILE') } else { '' }
$homeLeaf = if (Get-EnvValue 'HOME') { Split-Path -Leaf (Get-EnvValue 'HOME') } else { '' }
$script:UserNames = @((Get-EnvValue 'USERNAME'), (Get-EnvValue 'USER'), $profileLeaf, $homeLeaf) |
    Where-Object { $_ -and $_ -ne 'root' } | Select-Object -Unique

$doctorPath = Join-Path $PSScriptRoot 'harness-doctor.ps1'
if (-not (Test-Path -LiteralPath $doctorPath -PathType Leaf)) {
    Write-Error "harness-doctor.ps1 is missing from <scripts-dir> (expected beside harness-report.ps1). Nothing to report on: re-run the installer (npx oc-harness-setup setup) so scripts\ lands beside this file, then retry." -ErrorAction Continue
    exit 3
}

# ---------- run the sibling doctor (exit 0/1/2 are all normal outcomes) ----------
# The parameters are written LITERALLY: an array splat (@('-Json')) binds
# positionally and hands the script the string '-Json' as its first value
# instead of the switch (verified on PS 7.6), which silently grades the wrong
# directory. Do not "tidy" this into a splat.
$doctorExit = -1
$doctorOut = @()
$doctorFailure = ''
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if ($ConfigDir) {
        $doctorOut = @(& $doctorPath -Json -ConfigDir $ConfigDir 2>&1)
    } else {
        $doctorOut = @(& $doctorPath -Json 2>&1)
    }
    $doctorExit = $LASTEXITCODE
} catch {
    $doctorFailure = $_.Exception.Message
} finally {
    $ErrorActionPreference = $previousEap
}

$doctorText = (@($doctorOut) | ForEach-Object { [string]$_ }) -join "`n"
$doctorData = $null
try {
    $doctorData = $doctorText | ConvertFrom-Json
    # Doctor text is untrusted data: any parsed property whose NAME is
    # secret-like loses its VALUE before a single field is read from it.
    Hide-SecretPropertyValues -Node $doctorData
} catch {
    if (-not $doctorFailure) { $doctorFailure = "doctor output was not parseable JSON: $($_.Exception.Message)" }
}

$verdictWord = switch ($doctorExit) {
    0 { 'clean' }
    1 { 'regressions' }
    2 { 'drift' }
    default { "unknown (exit $doctorExit)" }
}

# ---------- identity ----------
$packageName = 'unknown'
$harnessVersion = 'unknown'
$manifestPath = Join-Path $root $manifestFile
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $manifest = Get-SafeText -Path $manifestPath | ConvertFrom-Json
        $packageProperty = $manifest.PSObject.Properties['package']
        if ($null -ne $packageProperty -and $packageProperty.Value) { $packageName = [string]$packageProperty.Value }
        $versionProperty = $manifest.PSObject.Properties['version']
        if ($null -ne $versionProperty -and $versionProperty.Value) { $harnessVersion = [string]$versionProperty.Value }
        $backupProperty = $manifest.PSObject.Properties['backupPath']
        if ($null -ne $backupProperty -and $backupProperty.Value) { $script:BackupPathLiteral = [string]$backupProperty.Value }
    } catch {
        # a missing or unreadable manifest degrades to the fallback, never to a throw
    }
}

$opencodeVersion = 'unknown'
$cli = Get-Command opencode -ErrorAction SilentlyContinue
if ($cli) {
    $ErrorActionPreference = 'Continue'
    try {
        $cliOut = @(& opencode --version 2>&1)
        $cliFirst = @($cliOut | Where-Object { $_ -and ([string]$_).Trim() -ne '' })[0]
        if ($cliFirst) { $opencodeVersion = ([string]$cliFirst).Trim() }
    } catch {
        # keep the fallback
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

$osName = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } elseif ($IsLinux) { 'Linux' } else { 'unknown' }
$psVersion = [string]$PSVersionTable.PSVersion

$doctorTimestamp = ''
if ($null -ne $doctorData) {
    $tsProperty = $doctorData.PSObject.Properties['timestamp']
    if ($null -ne $tsProperty -and $tsProperty.Value) {
        # ConvertFrom-Json turns the doctor's ISO-8601 string into [datetime];
        # render it back as ISO rather than the machine's culture format.
        $tsValue = $tsProperty.Value
        $doctorTimestamp = if ($tsValue -is [datetime]) { $tsValue.ToString('o') } else { [string]$tsValue }
    }
}
if (-not $doctorTimestamp) { $doctorTimestamp = (Get-Date).ToString('o') }

$summaryPass = 0
$summaryFail = 0
$summaryDrift = 0
$doctorSecretGuard = $null
if ($null -ne $doctorData) {
    $summaryProperty = $doctorData.PSObject.Properties['summary']
    if ($null -ne $summaryProperty -and $null -ne $summaryProperty.Value) {
        foreach ($field in @('pass', 'fail', 'drift')) {
            $p = $summaryProperty.Value.PSObject.Properties[$field]
            if ($null -eq $p) { continue }
            if ($field -eq 'pass') { $summaryPass = [int]$p.Value }
            if ($field -eq 'fail') { $summaryFail = [int]$p.Value }
            if ($field -eq 'drift') { $summaryDrift = [int]$p.Value }
        }
    }
    $guardProperty = $doctorData.PSObject.Properties['secretGuard']
    if ($null -ne $guardProperty) { $doctorSecretGuard = [bool]$guardProperty.Value }
}

# ---------- body ----------
$reportTitle = "[doctor] $summaryFail regression(s), $summaryDrift drift - $packageName $harnessVersion on $osName"
$reportTitle = [string](Redact-Text -Text $reportTitle)

Add-RedactedLine '<!-- harness report: generated by scripts/harness-report.ps1, redacted before it left the machine. Review, then edit freely. -->'
Add-RedactedLine ''
Add-RedactedLine '## Summary'
Add-RedactedLine ''
Add-RedactedLine '| field | value |'
Add-RedactedLine '| --- | --- |'
Add-RedactedLine "| harness | $packageName $harnessVersion |"
Add-RedactedLine "| opencode | $opencodeVersion |"
Add-RedactedLine "| os | $osName |"
Add-RedactedLine "| powershell | $psVersion |"
Add-RedactedLine "| doctor exit | $doctorExit ($verdictWord) |"
Add-RedactedLine "| laws | $summaryPass PASS / $summaryFail FAIL / $summaryDrift DRIFT |"
Add-RedactedLine "| config root | $root |"
Add-RedactedLine "| doctor timestamp | $doctorTimestamp |"
Add-RedactedLine ''

if ($null -eq $doctorData) {
    Add-RedactedLine '## Doctor output could not be parsed'
    Add-RedactedLine ''
    Add-RedactedLine "The doctor ran with exit $doctorExit but its JSON could not be parsed: $doctorFailure"
    Add-RedactedLine ''
    Add-RedactedLine 'Raw doctor output follows (redacted, first 20 lines).'
    Add-RedactedLine ''
    Add-RedactedLine '```text'
    foreach ($line in @($doctorOut | Select-Object -First 20)) { Add-RedactedLine ([string]$line) }
    Add-RedactedLine '```'
} else {
    $regressions = @(Get-ReportItems -Node $doctorData -Name 'regressions')
    $drift = @(Get-ReportItems -Node $doctorData -Name 'drift')

    Add-RedactedLine '## Regressions (an evaluated law FAILED - the harness actually broke)'
    Add-RedactedLine ''
    if ($regressions.Count -eq 0) {
        Add-RedactedLine 'None.'
    } else {
        foreach ($item in $regressions) {
            $law = Get-ReportField -Node $item -Name 'law'
            $evidence = Get-ReportField -Node $item -Name 'evidence'
            $proposal = Get-ReportField -Node $item -Name 'proposal'
            Add-RedactedLine "### $law"
            Add-RedactedLine ''
            Add-RedactedLine "- evidence: $evidence"
            if ($proposal) { Add-RedactedLine "- proposal: $proposal" }
            Add-RedactedLine ''
        }
    }
    Add-RedactedLine ''

    Add-RedactedLine '## Drift (the instrument could not derive an expectation)'
    Add-RedactedLine ''
    if ($drift.Count -eq 0) {
        Add-RedactedLine 'None.'
    } else {
        foreach ($item in $drift) {
            $law = Get-ReportField -Node $item -Name 'law'
            $evidence = Get-ReportField -Node $item -Name 'evidence'
            $ownerAction = Get-ReportField -Node $item -Name 'ownerAction'
            Add-RedactedLine "### $law"
            Add-RedactedLine ''
            Add-RedactedLine "- evidence: $evidence"
            if ($ownerAction) { Add-RedactedLine "- owner action: $ownerAction" }
            Add-RedactedLine ''
        }
    }
    Add-RedactedLine ''

    Add-RedactedLine '## Laws evaluated'
    Add-RedactedLine ''
    $laws = @(Get-ReportItems -Node $doctorData -Name 'laws')
    if ($laws.Count -eq 0) {
        Add-RedactedLine 'The doctor reported no laws.'
    } else {
        foreach ($law in $laws) {
            Add-RedactedLine "- $(Get-ReportField -Node $law -Name 'result') - $(Get-ReportField -Node $law -Name 'law')"
        }
    }
}

Add-RedactedLine ''
Add-RedactedLine '## Notes'
Add-RedactedLine ''
Add-RedactedLine "- The redactor removed $($script:DroppedCount) line(s) it could not keep safely (a pointer target, a secret-store path, or a bare credential literal) and redacted $($script:RedactedCount) secret-like value(s) in place."
Add-RedactedLine "- Law identifiers, law names, PASS/FAIL/DRIFT results and the summary counts are kept verbatim, including laws whose names carry a keyword such as 'secret' or 'credential'."
Add-RedactedLine "- Identity is redacted to placeholders: ~ for the home/config path, <session>, <host>, <user>."
Add-RedactedLine "- Guard self-test in the doctor: $(if ($null -eq $doctorSecretGuard) { 'not reported' } else { [string]$doctorSecretGuard })"

$body = ($script:BodyLines -join "`n")
if (-not $body.EndsWith("`n")) { $body += "`n" }

# Built after the body so the counters reflect the whole rendered report.
$identity = [pscustomobject]@{
    package        = Redact-Text -Text $packageName
    version        = Redact-Text -Text $harnessVersion
    opencode       = Redact-Text -Text $opencodeVersion
    os             = $osName
    powershell     = $psVersion
    root           = Redact-Text -Text $root
    doctorExit     = $doctorExit
    doctorVerdict  = $verdictWord
    timestamp      = Redact-Text -Text $doctorTimestamp
    droppedLines   = $script:DroppedCount
    redactedValues = $script:RedactedCount
}

# No labels: a label that does not exist upstream only makes the forge warn.
$query = 'title=' + [System.Uri]::EscapeDataString($reportTitle) +
    '&body=' + [System.Uri]::EscapeDataString($body)
$url = "$targetRepo/issues/new?$query"

if ($OutFile) {
    $outPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).Path $OutFile }
    $outDir = Split-Path -Parent $outPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    Set-Content -LiteralPath $outPath -Value $body -Encoding utf8 -NoNewline
}

if ($Json) {
    [pscustomobject]@{
        url      = $url
        body     = $body
        identity = $identity
    } | ConvertTo-Json -Depth 6
    exit 0
}

$body
''
'---'
"Prefilled issue URL (nothing is filed until you submit it):"
$url
if ($OutFile) { "Body also written to: $OutFile" }
exit 0
