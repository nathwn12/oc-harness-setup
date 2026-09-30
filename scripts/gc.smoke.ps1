#Requires -Version 7.0
<#
.SYNOPSIS
  Narrow runnable check for the gc-* git-ceremony script set:
  scripts\gc-{core,branch,stage,commit,push,sync,rebase,status,bump,read,release}.ps1.

.DESCRIPTION
  Pins the agent-first contract and the ceremony rails, dependency-free (no
  Pester — none is installed on this host), in a throwaway temp repo. All
  checks must pass (exit 0); any failure exits 1.

    a. stdout contract: every invocation emits exactly one RESULT: <json>
       line, and the ok flag matches the exit code; the default is TERSE
       (RESULT line + warnings/failures/security guidance only) and -Detailed
       restores the legacy chatter — same exit code and RESULT payload in
       every mode, so the mode never changes the contract and a security line
       is never hidden.
    b. branch ceremony: valid names create and switch; bad type / bad slug /
       duplicate fail with exit 2; -Reuse switches without recreating.
    c. stage gates: missing paths fail (2); a staged .env with a secret key is
       blocked (exit 4), left UNSTAGED, and intact on disk; .env.example is
       allowed.
    d. commit ceremony: refused on the default branch (2); bad subjects fail
       (2); issue refs in the subject are refused (2); a valid subject lands
       the exact message and body; nothing staged fails (2).
    e. secret gate scans the STAGED BLOB, not the worktree: a secret added
       with plain `git add` then edited out of the worktree still blocks the
       commit (exit 4).
    f. push/sync on a remote-less repo fail/behave cleanly (2 / no-op 0).
    g. rebase self-healing: a conflict stops in place (exit 2, state keeps the
       rebase) — abort is REFUSED once a file is resolved (it would be
       discarded), -Continue finishes it; a fresh conflict then -Abort rolls
       back exactly. -Onto rejects a leading dash (no option injection).
    h. non-repo root exits 2 with the fix, per the exit-code contract.
    i. bare-origin flow: gc-push sets up the upstream and pushes; a default
       branch advanced by another clone is fast-forwarded by gc-sync, and a
       dirty tree during a needed sync is refused (2).
    j. bump ceremony (§8): one source of truth, dirty tree refused, bump table
       (minor, major, -Set), downward refused, its own commit with the exact
       ceremony subject.
    k. gc-pr body precedence (§0): a repo-supplied body (-BodyFile) reaches
       `gh pr create` verbatim and suppresses the fixed shape; without it the
       fixed What/Why/Check/Risk template is still the fallback; a missing or
       empty body file is a loud exit 2 — never a silent empty body.
    l. gc-read read-only surface: all six -What selectors emit the standard
       RESULT contract; status delegates to gc-status; an unknown selector, a
       missing -Rev, and -Limit 0 each fail with exit 2; the surface never
       moves HEAD (read-only proof).
    m. gc-release (§9): the changelog-section renderer (release body = Version
       line + section verbatim; a missing section is a Pre stop) and the script
       refusals reachable without network — no remote, dirty tree, non-default
       branch — each exit 2 with the fix named, nothing mutated.

  Run: pwsh -File scripts\gc.smoke.ps1
  ALWAYS read-only on the host: it touches only a unique temp directory under
  the OS temp root, which it deletes in finally. It never runs the real gh —
  the gc-pr body checks double `gh` with a temp PATH shim (no network).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$pwshExe = (Get-Process -Id $PID).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$bareOrigin = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-smoke-" + [guid]::NewGuid().ToString('N') + "-origin.git")
$cloneRoot  = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-smoke-" + [guid]::NewGuid().ToString('N') + "-clone")
$plainDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-plain-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
$relDir     = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-release-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $relDir -Force | Out-Null
$relRepo    = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-release-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $relRepo -Force | Out-Null

$script:Failures = 0
$script:Pass     = 0
. (Join-Path $here 'gc.core.ps1')   # extracted renderers are pinned below (Format-GcPrBody / Convert-GcMergeMode)

function Assert-That {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green; $script:Pass++ }
    else { Write-Host "[FAIL] $Name — $Detail" -ForegroundColor Red; $script:Failures++ }
}

function Invoke-GcScript {
    param([Parameter(Mandatory)][string]$Name, [string[]]$Argv, [string]$Root = $root)
    $args = @('-NoProfile','-File',(Join-Path $here "$Name.ps1"),'-RepoRoot',$Root) + @($Argv)
    $out = & $pwshExe @args 2>&1
    $lines = @($out | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $lines; Text = ($lines -join "`n") }
}

function Get-GcResultObject {
    <# the parsed RESULT json from a call; $null when the line is missing. #>
    param($Call)
    $line = @($Call.Lines | Where-Object { $_ -match '^RESULT: ' })
    if ($line.Count -ne 1) { return $null }
    try { return (($line[0] -replace '^RESULT: ','') | ConvertFrom-Json) } catch { return $null }
}

function Get-GcCanonicalResult {
    <# key-sorted rendering of a RESULT payload — order-insensitive equality. #>
    param($Call)
    $o = Get-GcResultObject $Call
    if ($null -eq $o) { return '<no RESULT>' }
    $names = @($o.PSObject.Properties.Name) | Sort-Object
    return '{' + (($names | ForEach-Object { "$_=" + (ConvertTo-Json $o.$_ -Compress) }) -join ';') + '}'
}

function Assert-GcContract {
    param([Parameter(Mandatory)]$Call, [Parameter(Mandatory)][string]$Name)
    $res = Get-GcResultObject $Call
    Assert-That "$Name — exactly one RESULT: line" ($null -ne $res) ($Call.Text)
    if ($null -ne $res) {
        Assert-That "$Name — RESULT ok flag matches exit code" ($res.ok -eq ($Call.Code -eq 0)) "exit $($Call.Code), ok=$($res.ok)"
    }
}

try {
    # -------- setup: fresh repo with an origin-less main -------------------
    & git -C $root init -b main 2>&1 | Out-Null
    Assert-That 'setup — git init -b main' ($LASTEXITCODE -eq 0) ''
    & git -C $root config user.name 'gc smoke' | Out-Null
    & git -C $root config user.email 'gc-smoke@test' | Out-Null
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'one'
    & git -C $root add a.txt | Out-Null
    & git -C $root commit -m 'chore: seed repo' | Out-Null

    # -------- status -------------------------------------------------------
    $c = Invoke-GcScript 'gc-status'
    Assert-GcContract $c 'gc-status on fresh repo'
    Assert-That 'gc-status — reports branch main, clean' ($c.Code -eq 0 -and (Get-GcResultObject $c).branch -eq 'main' -and (Get-GcResultObject $c).clean -eq $true) ($c.Text)
    Assert-That 'gc-status default is TERSE — stdout is exactly the RESULT line' (
        @($c.Lines | Where-Object { $_ -notmatch '^RESULT: ' }).Count -eq 0
    ) ($c.Text)

    # -------- gc-read: the read-only surface (never writes) ---------------
    $headBeforeRead = (& git -C $root rev-parse HEAD).Trim()
    $c = Invoke-GcScript 'gc-read' @('-What','log')
    Assert-GcContract $c 'gc-read log'
    $log = Get-GcResultObject $c
    $firstCommit = if ($log -and $log.commits) { @($log.commits)[0] } else { $null }
    Assert-That 'gc-read log — one commit, seed subject' (
        $c.Code -eq 0 -and $null -ne $log -and $log.count -eq 1 -and $null -ne $firstCommit -and $firstCommit.subject -eq 'chore: seed repo'
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','status')
    Assert-That 'gc-read status — delegates to gc-status (branch main)' (
        $c.Code -eq 0 -and (Get-GcResultObject $c).branch -eq 'main'
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','branch-list')
    $bl = Get-GcResultObject $c
    Assert-That 'gc-read branch-list — main is current, at least one branch' (
        $c.Code -eq 0 -and $null -ne $bl -and $bl.current -eq 'main' -and $bl.count -ge 1
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','show','-Rev','HEAD')
    Assert-That 'gc-read show -Rev — text carries the commit' (
        $c.Code -eq 0 -and (Get-GcResultObject $c).rev -eq 'HEAD' -and (Get-GcResultObject $c).text -match 'seed repo'
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','diff-staged')
    Assert-That 'gc-read diff-staged — clean tree is an empty diff' (
        $c.Code -eq 0 -and (Get-GcResultObject $c).empty -eq $true
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','diff')
    Assert-That 'gc-read diff — clean tree is an empty diff' (
        $c.Code -eq 0 -and (Get-GcResultObject $c).empty -eq $true
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','bogus')
    Assert-That 'gc-read — unknown -What exits 2 naming the set' (
        $c.Code -eq 2 -and $c.Text -match 'not one of'
    ) ($c.Text)
    Assert-That 'gc-read — FAIL line visible under the terse default (never swallowed)' (
        $c.Code -eq 2 -and $c.Text -match '\[gc\] FAIL:'
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','show')
    Assert-That 'gc-read show without -Rev exits 2 naming the fix' (
        $c.Code -eq 2 -and $c.Text -match '-Rev'
    ) ($c.Text)

    $c = Invoke-GcScript 'gc-read' @('-What','log','-Limit','0')
    Assert-That 'gc-read log — -Limit 0 refused (2)' ($c.Code -eq 2) ($c.Text)

    Assert-That 'gc-read — read-only: HEAD unmoved' (
        (& git -C $root rev-parse HEAD).Trim() -eq $headBeforeRead
    ) ''

    # -------- extracted renderers (pinned without gh) ----------------------
    $b1 = Format-GcPrBody -What 'cap retry' -Why '' -Check 'n/a' -Risk 'low'
    Assert-That 'Format-GcPrBody — Why-omitted shape' ($b1 -eq "What:  cap retry`nCheck: n/a`nRisk:  low") ('[' + $b1 + ']')
    $b2 = Format-GcPrBody -What 'cap retry' -Why 'queue stalled' -Check 'dotnet test' -Risk 'medium'
    Assert-That 'Format-GcPrBody — full shape with Why' ($b2 -eq "What:  cap retry`nWhy:   queue stalled`nCheck: dotnet test`nRisk:  medium") ('[' + $b2 + ']')
    Assert-That 'Convert-GcMergeMode — flag literals' (
        (Convert-GcMergeMode -Mode squash) -eq '--squash' -and
        (Convert-GcMergeMode -Mode merge) -eq '--merge' -and
        (Convert-GcMergeMode -Mode rebase) -eq '--rebase'
    ) ''
    # Get-GcMergedMethod: label an already-merged PR from its commit subject
    Set-Content -Path (Join-Path $root 'm1.txt') -Value 'x'
    & git -C $root add m1.txt 2>&1 | Out-Null
    & git -C $root commit -m 'Merge pull request #9 from a/b' 2>&1 | Out-Null
    $sha1 = (& git -C $root rev-parse HEAD).Trim()
    Set-Content -Path (Join-Path $root 'm2.txt') -Value 'y'
    & git -C $root add m2.txt 2>&1 | Out-Null
    & git -C $root commit -m 'feat: squashed land (#8)' 2>&1 | Out-Null
    $sha2 = (& git -C $root rev-parse HEAD).Trim()
    Set-Content -Path (Join-Path $root 'm3.txt') -Value 'z'
    & git -C $root add m3.txt 2>&1 | Out-Null
    & git -C $root commit -m 'chore: rebased flat' 2>&1 | Out-Null
    $sha3 = (& git -C $root rev-parse HEAD).Trim()
    Assert-That 'Get-GcMergedMethod — merge/squash/rebase labels' (
        (Get-GcMergedMethod -Root $root -Sha $sha1) -eq 'merge' -and
        (Get-GcMergedMethod -Root $root -Sha $sha2) -eq 'squash' -and
        (Get-GcMergedMethod -Root $root -Sha $sha3) -eq 'rebase'
    ) ''

    # -------- branch ceremony ---------------------------------------------
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','smoke-change')
    Assert-GcContract $c 'gc-branch feat/smoke-change'
    Assert-That 'gc-branch — creates and switches' ($c.Code -eq 0 -and (& git -C $root rev-parse --abbrev-ref HEAD).Trim() -eq 'feat/smoke-change') ($c.Text)

    $c = Invoke-GcScript 'gc-branch' @('-Type','nope','-Slug','whatever')
    Assert-That 'gc-branch — bad type exits 2' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','Bad-Slug')
    Assert-That 'gc-branch — bad slug exits 2' ($c.Code -eq 2) ($c.Text)

    & git -C $root switch main 2>&1 | Out-Null   # off the target branch so the exists-check is reachable
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','smoke-change')
    Assert-That 'gc-branch — duplicate without -Reuse exits 2' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','smoke-change','-Reuse')
    Assert-That 'gc-branch — -Reuse switches to the existing branch (0)' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','never-existed','-Reuse')
    Assert-That 'gc-branch — -Reuse on missing branch refused (2)' ($c.Code -eq 2) ($c.Text)

    # -------- terse default: chatter off unless -Detailed, never the contract
    $cTerse  = Invoke-GcScript 'gc-branch' @('-Branch','feat/smoke-change','-Reuse')
    $cDetail = Invoke-GcScript 'gc-branch' @('-Branch','feat/smoke-change','-Reuse','-Detailed')
    $cQuiet  = Invoke-GcScript 'gc-branch' @('-Branch','feat/smoke-change','-Reuse','-Quiet')
    $cBoth   = Invoke-GcScript 'gc-branch' @('-Branch','feat/smoke-change','-Reuse','-Detailed','-Quiet')
    $terseChatter  = @($cTerse.Lines  | Where-Object { $_ -notmatch '^RESULT: ' }).Count
    $detailChatter = @($cDetail.Lines | Where-Object { $_ -notmatch '^RESULT: ' }).Count
    $bothChatter   = @($cBoth.Lines   | Where-Object { $_ -notmatch '^RESULT: ' }).Count
    Assert-That 'gc-branch default is TERSE — exit 0, chatter gated to 0 lines' (
        $cTerse.Code -eq 0 -and $terseChatter -eq 0
    ) "exit $($cTerse.Code); chatter=$terseChatter; $($cTerse.Text)"
    Assert-That 'gc-branch -Detailed — restores legacy chatter (exit 0, chatter > 0)' (
        $cDetail.Code -eq 0 -and $detailChatter -gt 0
    ) "exit $($cDetail.Code); chatter=$detailChatter"
    Assert-That 'gc-branch terse/-Detailed/-Quiet — same exit + RESULT payload every mode (chatter never changes the contract)' (
        $cQuiet.Code -eq 0 -and $cBoth.Code -eq 0 -and
        (Get-GcCanonicalResult $cTerse) -eq (Get-GcCanonicalResult $cDetail) -and
        (Get-GcCanonicalResult $cTerse) -eq (Get-GcCanonicalResult $cQuiet) -and
        (Get-GcCanonicalResult $cTerse) -eq (Get-GcCanonicalResult $cBoth)
    ) "terse=$(Get-GcCanonicalResult $cTerse) detailed=$(Get-GcCanonicalResult $cDetail) both=$(Get-GcCanonicalResult $cBoth)"
    Assert-That 'gc-branch -Detailed -Quiet — -Quiet wins, chatter gated to 0 lines' (
        $bothChatter -eq 0
    ) "chatter=$bothChatter"

    # -------- branch delete ------------------------------------------------
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','delete-me')
    Assert-That 'gc-branch -Delete setup — create delete-test branch' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Delete','feat/delete-me')
    Assert-That 'gc-branch -Delete — current branch refused (2)' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','smoke-change','-Reuse')
    Assert-That 'gc-branch — switch back before deleting' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Delete','main')
    Assert-That 'gc-branch -Delete — default branch refused (2)' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Delete','feat/does-not-exist')
    Assert-That 'gc-branch -Delete — nonexistent refused (2)' ($c.Code -eq 2) ($c.Text)

    Set-Content -Path (Join-Path $root 'a.txt') -Value 'dirty-for-delete'
    $c = Invoke-GcScript 'gc-branch' @('-Delete','feat/delete-me')
    Assert-That 'gc-branch -Delete — dirty tree refused (2)' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Delete','feat/does-not-exist')
    Assert-That 'gc-branch -Delete — nonexistent beats dirty (does-not-exist msg)' ($c.Code -eq 2 -and $c.Text -match 'does not exist') ($c.Text)
    & git -C $root checkout -- a.txt 2>&1 | Out-Null

    $c = Invoke-GcScript 'gc-branch' @('-Delete','feat/delete-me')
    Assert-That 'gc-branch -Delete — merged branch deleted (0)' ($c.Code -eq 0 -and (Get-GcResultObject $c).deleted_local -eq $true) ($c.Text)
    $gone = $( & git -C $root show-ref --verify --quiet refs/heads/feat/delete-me 2>$null; $LASTEXITCODE -ne 0 )
    Assert-That 'gc-branch -Delete — local ref actually gone' $gone ''

    $c = Invoke-GcScript 'gc-branch' @('-Type','chore','-Slug','delete-unmerged')
    Assert-That 'gc-branch -Delete setup — create unmerged branch' ($c.Code -eq 0) ($c.Text)
    Set-Content -Path (Join-Path $root 'u.txt') -Value 'unmerged'
    & git -C $root add u.txt 2>&1 | Out-Null
    & git -C $root commit -m 'chore: unmerged work' 2>&1 | Out-Null
    $c = Invoke-GcScript 'gc-branch' @('-Delete','chore/delete-unmerged')
    Assert-That 'gc-branch -Delete — unmerged refused without -Force (2)' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','smoke-change','-Reuse')
    Assert-That 'gc-branch — off the unmerged branch before force-delete' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Delete','chore/delete-unmerged','-Force')
    Assert-That 'gc-branch -Delete — unmerged deleted with -Force (0)' ($c.Code -eq 0 -and (Get-GcResultObject $c).deleted_local -eq $true) ($c.Text)
    Assert-That 'gc-branch -Delete -Force — unmerged ref gone' ($( & git -C $root show-ref --verify --quiet refs/heads/chore/delete-unmerged 2>$null; $LASTEXITCODE -ne 0 )) ''

    # -------- staging ------------------------------------------------------
    Set-Content -Path (Join-Path $root 'b.txt') -Value 'two'
    $c = Invoke-GcScript 'gc-stage' @('-Path','b.txt')
    Assert-GcContract $c 'gc-stage b.txt'
    Assert-That 'gc-stage — b.txt staged' ($c.Code -eq 0 -and ((Get-GcResultObject $c).staged -contains 'b.txt')) ($c.Text)

    $c = Invoke-GcScript 'gc-stage' @('-Path','missing-file.txt')
    Assert-That 'gc-stage — missing path exits 2' ($c.Code -eq 2) ($c.Text)

    $fakeAwsKey = 'AKIA' + 'IOSFODNN7EXAMPLE'   # assembled at runtime — no contiguous pattern in source
    Set-Content -Path (Join-Path $root '.env') -Value "KEY=$fakeAwsKey"
    $c = Invoke-GcScript 'gc-stage' @('-Path','.env')
    Assert-GcContract $c 'gc-stage .env with secret key'
    Assert-That 'gc-stage — secret blocked with exit 4' ($c.Code -eq 4) ($c.Text)
    Assert-That 'gc-stage — exit-4 security code + blocked list in RESULT' (
        $c.Code -eq 4 -and (Get-GcResultObject $c).exit -eq 4 -and
        @((Get-GcResultObject $c).blocked) -contains '.env'
    ) ($c.Text)
    Assert-That 'gc-stage — offender + remediation VISIBLE with chatter OFF (terse default)' (
        $c.Text -match 'FAIL: secret scan blocked' -and $c.Text -match '\.env' -and
        $c.Text -match 'remediation:' -and $c.Text -match '\.gitignore' -and
        $c.Text -match 'working tree untouched'
    ) ($c.Text)
    $staged = @(& git -C $root diff --cached --name-only | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    Assert-That 'gc-stage — secret file left unstaged' ($staged -notcontains '.env') ($staged -join ', ')
    Assert-That 'gc-stage — secret file intact on disk' ((Get-Content (Join-Path $root '.env') -Raw).Trim() -eq "KEY=$fakeAwsKey") ''

    Set-Content -Path (Join-Path $root '.env.example') -Value 'KEY=example'
    $c = Invoke-GcScript 'gc-stage' @('-Path','.env.example')
    Assert-That 'gc-stage — .env.example allowed (0)' ($c.Code -eq 0) ($c.Text)

    Remove-Item -LiteralPath (Join-Path $root '.env') -Force
    $c = Invoke-GcScript 'gc-stage' @('-All')
    Assert-That 'gc-stage -All — 0 and staged b.txt + .env.example' ($c.Code -eq 0 -and @((Get-GcResultObject $c).staged).Count -eq 2) ($c.Text)

    # -------- commit ceremony ---------------------------------------------
    & git -C $root switch main 2>&1 | Out-Null
    $headBeforeRefusal = (& git -C $root rev-parse HEAD).Trim()
    $c = Invoke-GcScript 'gc-commit' @('-Type','feat','-Summary','nope','-All')
    $headAfterRefusal = (& git -C $root rev-parse HEAD).Trim()
    Assert-That 'gc-commit — actionable fail-closed default refusal; HEAD unchanged (2)' ($c.Code -eq 2 -and $c.Text -match 'intentionally refusing' -and $c.Text -match 'review state' -and $c.Text -match 'R1' -and $c.Text -match 'secret gate' -and $c.Text -match '§11b' -and $c.Text -match 'unknown or disputed' -and $c.Text -match 'do not retry with raw git' -and $headBeforeRefusal -eq $headAfterRefusal) ($c.Text)
    & git -C $root switch feat/smoke-change 2>&1 | Out-Null

    $c = Invoke-GcScript 'gc-commit' @('-Type','feat','-Summary','Adds stuff.')
    Assert-That 'gc-commit — trailing period / uppercase exits 2' ($c.Code -eq 2) ($c.Text)
    $long = 'add ' + ('x' * 80)
    $c = Invoke-GcScript 'gc-commit' @('-Type','feat','-Summary',$long)
    Assert-That 'gc-commit — subject over 72 chars exits 2' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-commit' @('-Type','feat','-Summary','add login flow #123')
    Assert-That 'gc-commit — issue ref in subject refused (2)' ($c.Code -eq 2) ($c.Text)

    $c = Invoke-GcScript 'gc-commit' @('-Type','feat','-Summary','add smoke file','-Body',"covers stage`ncovers commit")
    Assert-GcContract $c 'gc-commit valid subject'
    Assert-That 'gc-commit — lands the exact subject' ($c.Code -eq 0 -and (& git -C $root log -1 --format=%s).Trim() -eq 'feat: add smoke file') ($c.Text)
    Assert-That 'gc-commit — RESULT files count is truthful (2)' ($c.Code -eq 0 -and (Get-GcResultObject $c).files -eq 2) ($c.Text)
    Assert-That 'gc-commit — body bullet landed' (((& git -C $root log -1 --format=%B) | Out-String) -match 'covers stage') ''

    # M2 issue-ref shaping: technical prose passes, real refs still caught
    Set-Content -Path (Join-Path $root 'c.txt') -Value 'three'
    $c = Invoke-GcScript 'gc-stage' @('-Path','c.txt')
    Assert-That 'M2 setup — c.txt staged' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-commit' @('-Type','feat','-Summary','bump TLS-1.3 to minimum','-All')
    Assert-That 'M2 — technical prose (TLS-1.3) accepted (0)' ($c.Code -eq 0 -and (& git -C $root log -1 --format=%s).Trim() -eq 'feat: bump TLS-1.3 to minimum') ($c.Text)
    Set-Content -Path (Join-Path $root 'd.txt') -Value 'four'
    $c = Invoke-GcScript 'gc-stage' @('-Path','d.txt')
    Assert-That 'M2 setup — d.txt staged' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-commit' @('-Type','fix','-Summary','add support for ABC-1234 gating','-All')
    Assert-That 'M2 — multi-digit ticket ref refused (2)' ($c.Code -eq 2) ($c.Text)
    & git -C $root restore --staged d.txt 2>&1 | Out-Null
    Remove-Item -LiteralPath (Join-Path $root 'd.txt') -Force

    $c = Invoke-GcScript 'gc-commit' @('-Type','feat','-Summary','nothing staged')
    Assert-That 'gc-commit — nothing staged exits 2' ($c.Code -eq 2) ($c.Text)

    # -------- secret gate scans the STAGED BLOB, not the worktree ---------
    Set-Content -Path (Join-Path $root 'settings.txt') -Value "KEY=$fakeAwsKey"
    & git -C $root add settings.txt 2>&1 | Out-Null        # plain git — bypasses gc-stage
    Set-Content -Path (Join-Path $root 'settings.txt') -Value 'KEY=benign'   # worktree no longer holds the key
    $c = Invoke-GcScript 'gc-commit' @('-Type','chore','-Summary','rotate config')
    Assert-GcContract $c 'gc-commit over staged secret (blob scan)'
    Assert-That 'gc-commit — staged secret blocked via index blob (4)' ($c.Code -eq 4) ($c.Text)
    Assert-That 'gc-commit — remediation VISIBLE with chatter OFF (terse default)' (
        $c.Code -eq 4 -and $c.Text -match 'remediation:' -and $c.Text -match 'settings\.txt'
    ) ($c.Text)
    Assert-That 'gc-commit — nothing was committed' ((& git -C $root log -1 --format=%s).Trim() -ne 'chore: rotate config') ''
    $staged = @(& git -C $root diff --cached --name-only | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    Assert-That 'gc-commit — secret file unstaged' ($staged -notcontains 'settings.txt') ($staged -join ', ')
    & git -C $root restore --staged settings.txt 2>&1 | Out-Null
    Remove-Item -LiteralPath (Join-Path $root 'settings.txt') -Force

    # -------- unborn repo + gate trip: exit 4, narrow unstage, tree intact --
    # fresh init, no commits: `git restore --staged` cannot resolve HEAD, so the
    # gate's cleanup falls back to `git rm --cached` for the offender list only.
    $unbornGate = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-smoke-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $unbornGate -Force | Out-Null
    & git -C $unbornGate init -b main 2>&1 | Out-Null
    Set-Content -Path (Join-Path $unbornGate 'notes.txt') -Value 'keep me'
    Set-Content -Path (Join-Path $unbornGate 'deploy.key') -Value 'placeholder key material'
    $c = Invoke-GcScript 'gc-stage' @('-All') -Root $unbornGate
    $uStaged = @(& git -C $unbornGate diff --cached --name-only | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $uIntact = ((Get-Content (Join-Path $unbornGate 'deploy.key') -Raw).Trim() -eq 'placeholder key material')
    Assert-That 'gc-stage unborn repo — gate exits 4, offender unstaged, tree intact' (
        $c.Code -eq 4 -and $uStaged -notcontains 'deploy.key' -and $uIntact
    ) ("exit $($c.Code); index=[$($uStaged -join ', ')]; intact=$uIntact; " + $c.Text)
    Assert-That 'gc-stage unborn repo — offender named + remediation visible with chatter OFF' (
        $c.Text -match 'deploy\.key' -and $c.Text -match 'remediation:'
    ) ($c.Text)
    Remove-Item -LiteralPath $unbornGate -Recurse -Force -ErrorAction SilentlyContinue

    # -------- push / sync on a remote-less repo ----------------------------
    $c = Invoke-GcScript 'gc-push'
    Assert-That 'gc-push — no remote exits 2, mentions remote' ($c.Code -eq 2 -and $c.Text -match 'remote') ($c.Text)
    $c = Invoke-GcScript 'gc-pr' @('-What','nope','-Check','n/a','-Risk','low')
    Assert-That 'gc-pr — unpushed head refused before gh (2)' ($c.Code -eq 2 -and $c.Text -match 'push') ($c.Text)
    $c = Invoke-GcScript 'gc-sync'
    Assert-GcContract $c 'gc-sync on remote-less repo'
    Assert-That 'gc-sync — clean no-op (skipped-local)' ($c.Code -eq 0 -and (Get-GcResultObject $c).action -eq 'skipped-local') ($c.Text)

    # unborn default: gc-sync must be a no-op, not a generic exit 1
    $unborn = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-smoke-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $unborn -Force | Out-Null
    & git -C $unborn init -b main 2>&1 | Out-Null
    $out = & $pwshExe -NoProfile -File (Join-Path $here 'gc-sync.ps1') -RepoRoot $unborn 2>&1
    Assert-That 'gc-sync — unborn default is a no-op (0)' ($LASTEXITCODE -eq 0 -and (($out | Out-String) -match 'unborn')) (($out | Out-String))
    Remove-Item -LiteralPath $unborn -Recurse -Force -ErrorAction SilentlyContinue

    # -------- rebase: conflict stop -> abort refusal -> continue -> abort --
    & git -C $root switch main 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'main change'
    & git -C $root commit -am 'chore: main side' 2>&1 | Out-Null
    & git -C $root switch feat/smoke-change 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'feat change'
    & git -C $root commit -am 'chore: feat side' 2>&1 | Out-Null

    $c = Invoke-GcScript 'gc-rebase'
    Assert-That 'gc-rebase — conflict stops in place (exit 2, action conflict)' ($c.Code -eq 2 -and (Get-GcResultObject $c).action -eq 'conflict') ($c.Text)
    $rebaseDir = (& git -C $root rev-parse --git-path rebase-merge).Trim()
    Assert-That 'gc-rebase — rebase state preserved' (Test-Path -LiteralPath (Join-Path $root $rebaseDir)) ''
    $c = Invoke-GcScript 'gc-status'
    $st = Get-GcResultObject $c
    Assert-That 'gc-status — mid-rebase: detached + rebase_in_progress + conflicts' (
        $c.Code -eq 0 -and $st.detached -eq $true -and $st.rebase_in_progress -eq $true -and $st.conflicts -ge 1
    ) ($c.Text)

    Set-Content -Path (Join-Path $root 'a.txt') -Value 'merged'
    & git -C $root add a.txt 2>&1 | Out-Null
    $c = Invoke-GcScript 'gc-rebase' @('-Abort')
    Assert-That 'gc-rebase — abort refused while resolution exists (2)' ($c.Code -eq 2 -and $c.Text -match 'abort would discard') ($c.Text)
    # marker gate: -Continue must refuse to commit leftover conflict markers
    Set-Content -Path (Join-Path $root 'a.txt') -Value "merged`n<<<<<<< HEAD leftover"
    & git -C $root add a.txt 2>&1 | Out-Null
    $c = Invoke-GcScript 'gc-rebase' @('-Continue')
    Assert-That 'gc-rebase — marker gate: -Continue refused while markers remain (2)' ($c.Code -eq 2) ($c.Text)
    Assert-That 'gc-rebase — marker gate: rebase still in progress' (Test-Path -LiteralPath (Join-Path $root $rebaseDir)) ''
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'merged'
    & git -C $root add a.txt 2>&1 | Out-Null
    $c = Invoke-GcScript 'gc-rebase' @('-Continue')
    Assert-GcContract $c 'gc-rebase -Continue after resolution'
    Assert-That 'gc-rebase — continue landed the resolution' ($c.Code -eq 0 -and (Get-Content (Join-Path $root 'a.txt') -Raw).Trim() -eq 'merged') ($c.Text)
    Assert-That 'gc-rebase — rebase state cleared' (-not (Test-Path -LiteralPath (Join-Path $root $rebaseDir))) ''

    $c = Invoke-GcScript 'gc-rebase' @('-Continue')
    Assert-That 'gc-rebase — continue with nothing in progress exits 2' ($c.Code -eq 2) ($c.Text)

    & git -C $root switch main 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'main second'
    & git -C $root commit -am 'chore: main second' 2>&1 | Out-Null
    & git -C $root switch feat/smoke-change 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'feat second'
    & git -C $root commit -am 'chore: feat second' 2>&1 | Out-Null
    $headBefore = (& git -C $root rev-parse HEAD).Trim()
    $c = Invoke-GcScript 'gc-rebase'
    Assert-That 'gc-rebase — second conflict for abort test (exit 2)' ($c.Code -eq 2) ($c.Text)
    # adv-M2: abort must refuse UNSTAGED manual resolution (markers gone in the worktree)
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'manual unstaged resolution'
    $c = Invoke-GcScript 'gc-rebase' @('-Abort')
    Assert-That 'gc-rebase — abort refused for unstaged manual resolution (2)' ($c.Code -eq 2 -and $c.Text -match 'unstaged') ($c.Text)
    & git -C $root checkout -m -- a.txt 2>&1 | Out-Null   # regenerate the conflict markers
    $c = Invoke-GcScript 'gc-rebase' @('-Abort')
    Assert-That 'gc-rebase -Abort — exit 0, back on branch' ($c.Code -eq 0 -and (& git -C $root rev-parse --abbrev-ref HEAD).Trim() -eq 'feat/smoke-change') ($c.Text)
    Assert-That 'gc-rebase -Abort — content restored, HEAD unchanged' ((Get-Content (Join-Path $root 'a.txt') -Raw).Trim() -eq 'feat second' -and (& git -C $root rev-parse HEAD).Trim() -eq $headBefore) ''

    # -------- add/add (AA) conflict: same-named file added on both sides ----
    # both branches carry the same a.txt content now — the ONLY conflict is AA
    # (the old conflict logic counted UU entries only; AA must count too)
    & git -C $root switch main 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'aligned'
    & git -C $root commit -am 'chore: align a.txt on main' 2>&1 | Out-Null
    & git -C $root switch feat/smoke-change 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'a.txt') -Value 'aligned'
    & git -C $root commit -am 'chore: align a.txt on feat' 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'shared.txt') -Value 'added on feat'
    & git -C $root add shared.txt 2>&1 | Out-Null
    & git -C $root commit -m 'chore: feat adds shared.txt' 2>&1 | Out-Null
    & git -C $root switch main 2>&1 | Out-Null
    Set-Content -Path (Join-Path $root 'shared.txt') -Value 'added on main'
    & git -C $root add shared.txt 2>&1 | Out-Null
    & git -C $root commit -m 'chore: main adds shared.txt' 2>&1 | Out-Null
    & git -C $root merge feat/smoke-change --no-edit 2>&1 | Out-Null   # AA conflict expected
    $c = Invoke-GcScript 'gc-status'
    $st = Get-GcResultObject $c
    Assert-That 'gc-status — add/add (AA) conflict counted (conflicts >= 1)' (
        $c.Code -eq 0 -and $st.conflicts -ge 1
    ) ($c.Text)
    & git -C $root merge --abort 2>&1 | Out-Null

    # -------- H1: -Onto rejects a leading dash (no option injection) -------
    $c = Invoke-GcScript 'gc-rebase' @('-Onto','--exec=echo pwned')
    Assert-That 'gc-rebase — -Onto leading dash refused (2)' ($c.Code -eq 2) ($c.Text)

    # -------- gc-merge on the default branch: clear hint, gh not touched ----
    & git -C $root switch main 2>&1 | Out-Null
    $c = Invoke-GcScript 'gc-merge'
    Assert-That 'gc-merge — on default branch exits 2 with -Branch hint, before gh' ($c.Code -eq 2 -and $c.Text -match '-Branch') ($c.Text)
    & git -C $root switch feat/smoke-change 2>&1 | Out-Null

    # -------- non-repo root: contract exit 2 with a fix hint ---------------
    $out = & $pwshExe -NoProfile -File (Join-Path $here 'gc-status.ps1') -RepoRoot $plainDir 2>&1
    Assert-That 'gc-status — non-repo root exits 2 with fix hint' ($LASTEXITCODE -eq 2 -and (($out | Out-String) -match 'RepoRoot')) (($out | Out-String))

    # -------- bare origin: push upstream, sync fast-forward, dirty refusal --
    & git -C $root init --bare $bareOrigin 2>&1 | Out-Null
    Assert-That 'bare-origin — git init --bare' ($LASTEXITCODE -eq 0) ''
    & git -C $bareOrigin symbolic-ref HEAD refs/heads/main 2>&1 | Out-Null   # Windows local clones default to master otherwise
    & git -C $root remote add origin $bareOrigin 2>&1 | Out-Null
    & git -C $root push -u origin main 2>&1 | Out-Null
    Assert-That 'bare-origin — seed main pushed' ($LASTEXITCODE -eq 0) ''
    & git -C $root switch feat/smoke-change 2>&1 | Out-Null

    $c = Invoke-GcScript 'gc-push'
    Assert-That 'gc-push — sets up the upstream on first push (0)' ($c.Code -eq 0 -and (Get-GcResultObject $c).action -eq 'pushed-with-upstream') ($c.Text)
    $c = Invoke-GcScript 'gc-push'
    Assert-That 'gc-push — second push is a plain push (0)' ($c.Code -eq 0 -and (Get-GcResultObject $c).action -eq 'pushed') ($c.Text)

    # exit-3 contract preserved WITHOUT the deleted auth probe: a gh call whose
    # own message says not-logged-in must still surface as dependency (3), not 1.
    $authShimDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-authshim-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $authShimDir -Force | Out-Null
    Set-Content -Path (Join-Path $authShimDir 'gh.ps1') -Value (@(
        'param()',
        '[Console]::Error.WriteLine("To get started with GitHub CLI, please run:  gh auth login")',
        'exit 1'
    ) -join "`n")
    $pathSaved3 = $env:PATH
    $env:PATH = "$authShimDir;$pathSaved3"
    try {
        $c = Invoke-GcScript 'gc-pr' @('-Title','chore: auth probe','-What','x')
        Assert-That 'gc-pr — gh not-logged-in exits 3 (dependency) with the login fix, probe deleted' (
            $c.Code -eq 3 -and (Get-GcResultObject $c).exit -eq 3 -and $c.Text -match 'gh auth login'
        ) ($c.Text)
    } finally {
        $env:PATH = $pathSaved3
        Remove-Item -LiteralPath $authShimDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -------- gc-pr body (§0 precedence): the repo's own body wins, the fixed
    # What/Why/Check/Risk shape stays the FALLBACK. gh is DOUBLED by a PATH shim
    # (never the real gh, no network): the shim logs every argv it receives, so
    # the body actually handed to `gh pr create` is observable without a PR.
    $shimDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("gc-shim-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
    $shimFile  = Join-Path $shimDir 'gh.ps1'
    $shimBody  = Join-Path $shimDir 'pr-body.md'
    $shimEmpty = Join-Path $shimDir 'pr-body-empty.md'
    $repoBody  = @('## What', '', 'Repo-supplied PR body.', '', '## Verification', '', 'npm run build') -join "`n"
    Set-Content -Path $shimBody  -Value $repoBody -NoNewline
    Set-Content -Path $shimEmpty -Value '' -NoNewline
    # the double is SELF-CHECKING: it carries the exact body it must receive and
    # reports (exit 7) when `gh pr create` gets anything else — the assertion is
    # the real argv, with no side-channel log. `exit` sets $LASTEXITCODE for the
    # caller, exactly like the real gh.
    $writeShim = {
        param([string]$Expect)
        $src = @(
            'param()',
            ('$expect = ''' + $Expect + ''''),
            'if ($args.Count -ge 1 -and $args[0] -eq ''auth'') { exit 0 }',
            'if ($args.Count -ge 2 -and $args[0] -eq ''pr'' -and $args[1] -eq ''view'') {',
            '  if (($args -join '' '') -match ''number,state,headRefOid'') { Write-Output ''no pull requests found''; exit 1 }',
            '  Write-Output ''{"number":4242,"url":"https://example.invalid/pull/4242","isDraft":false}''; exit 0',
            '}',
            'if ($args.Count -ge 2 -and $args[0] -eq ''pr'' -and $args[1] -eq ''create'') {',
            '  $i = [array]::IndexOf($args, ''--body'')',
            '  $got = if ($i -ge 0 -and $i + 1 -lt $args.Count) { $args[$i + 1] } else { ''<no --body>'' }',
            '  if ($got -ne $expect) { [Console]::Error.WriteLine(''SHIM MISMATCH — create got: ['' + $got + '']''); exit 7 }',
            '  exit 0',
            '}',
            'exit 0'
        ) -join "`n"
        Set-Content -Path $shimFile -Value $src
    }
    $pathSaved = $env:PATH
    $env:PATH = "$shimDir;$pathSaved"
    try {
        # terse default vs -Detailed on a gh verb (shimmed: no network)
        & $writeShim $repoBody
        $cPrTerse  = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-BodyFile',$shimBody)
        $cPrDetail = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-BodyFile',$shimBody,'-Detailed')
        $prTerseChatter  = @($cPrTerse.Lines  | Where-Object { $_ -notmatch '^RESULT: ' }).Count
        $prDetailChatter = @($cPrDetail.Lines | Where-Object { $_ -notmatch '^RESULT: ' }).Count
        Assert-That 'gc-pr default is TERSE (created, chatter 0) and -Detailed restores chatter' (
            $cPrTerse.Code -eq 0 -and $prTerseChatter -eq 0 -and
            $cPrDetail.Code -eq 0 -and $prDetailChatter -gt 0
        ) "terse exit $($cPrTerse.Code)/chat $prTerseChatter; detailed exit $($cPrDetail.Code)/chat $prDetailChatter"

        # (1) repo-supplied body: the file content, verbatim, is what gh receives
        & $writeShim $repoBody
        $c = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-BodyFile',$shimBody,'-Quiet')
        Assert-That 'gc-pr -BodyFile — body reaches gh pr create verbatim (0, created)' (
            $c.Code -eq 0 -and (Get-GcResultObject $c).action -eq 'created'
        ) $c.Text

        # (2) no override: the fixed What/Why/Check/Risk template is the fallback
        & $writeShim "What:  cap retry backoff`nCheck: dotnet test`nRisk:  low"
        $c = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-What','cap retry backoff','-Check','dotnet test','-Quiet')
        Assert-That 'gc-pr no override — fixed What/Check/Risk template still the fallback' (
            $c.Code -eq 0 -and (Get-GcResultObject $c).action -eq 'created'
        ) $c.Text

        $c = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-BodyFile',(Join-Path $shimDir 'nope.md'))
        Assert-That 'gc-pr — missing -BodyFile exits 2 naming the fix' ($c.Code -eq 2 -and $c.Text -match 'BodyFile not found') ($c.Text)
        $c = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-BodyFile',$shimEmpty)
        Assert-That 'gc-pr — empty -BodyFile exits 2 (never a silent empty body)' ($c.Code -eq 2 -and $c.Text -match 'BodyFile is empty') ($c.Text)
        $c = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-Body',$repoBody,'-BodyFile',$shimBody)
        Assert-That 'gc-pr — -Body + -BodyFile mutually exclusive (2)' ($c.Code -eq 2 -and $c.Text -match 'mutually exclusive') ($c.Text)
        $c = Invoke-GcScript 'gc-pr' @('-Title','chore: smoke pr body','-Quiet')
        Assert-That 'gc-pr — no body and no -What exits 2 naming -What' ($c.Code -eq 2 -and $c.Text -match '-What is required') ($c.Text)
    } finally {
        $env:PATH = $pathSaved
        Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # remote-only branch deletion: create + push + -DeleteRemote
    $c = Invoke-GcScript 'gc-branch' @('-Type','chore','-Slug','remote-delete-probe')
    Assert-That 'gc-branch remote-delete setup — create probe branch' ($c.Code -eq 0) ($c.Text)
    Set-Content -Path (Join-Path $root 'probe.txt') -Value 'probe'
    & git -C $root add probe.txt 2>&1 | Out-Null
    & git -C $root commit -m 'chore: remote delete probe' 2>&1 | Out-Null
    $c = Invoke-GcScript 'gc-push'
    Assert-That 'gc-branch remote-delete setup — probe pushed' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','smoke-change','-Reuse')
    Assert-That 'gc-branch — off the probe branch' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-branch' @('-Delete','chore/remote-delete-probe','-DeleteRemote','-Force')
    Assert-That 'gc-branch -Delete -DeleteRemote — local + remote gone (0)' (
        $c.Code -eq 0 -and (Get-GcResultObject $c).deleted_local -eq $true -and (Get-GcResultObject $c).deleted_remote -eq $true
    ) ($c.Text)
    $remoteGone = -not @(& git -C $root ls-remote --heads $bareOrigin 'chore/remote-delete-probe')
    Assert-That 'gc-branch -DeleteRemote — origin ref actually gone' $remoteGone ''

    & git -C $root clone -q $bareOrigin $cloneRoot 2>&1 | Out-Null
    Set-Content -Path (Join-Path $cloneRoot 'a.txt') -Value 'clone advance'
    & git -C $cloneRoot config user.name 'gc smoke' | Out-Null
    & git -C $cloneRoot config user.email 'gc-smoke@test' | Out-Null
    & git -C $cloneRoot commit -am 'chore: clone advance' 2>&1 | Out-Null
    & git -C $cloneRoot push 2>&1 | Out-Null
    Assert-That 'clone — origin main advanced' ($LASTEXITCODE -eq 0) ''

    Set-Content -Path (Join-Path $root 'b.txt') -Value 'dirty'   # tracked on feat → dirty tree
    $c = Invoke-GcScript 'gc-sync'
    Assert-That 'gc-sync — dirty tree during needed sync refused (2)' ($c.Code -eq 2) ($c.Text)
    & git -C $root checkout -- b.txt 2>&1 | Out-Null   # restore, not delete — deletion would stay dirty
    $c = Invoke-GcScript 'gc-sync'
    Assert-GcContract $c 'gc-sync fast-forward'
    Assert-That 'gc-sync — fast-forwarded to origin/main' ($c.Code -eq 0 -and (Get-GcResultObject $c).action -eq 'fast-forwarded') ($c.Text)
    $c = Invoke-GcScript 'gc-sync'
    Assert-That 'gc-sync — up-to-date second run' ($c.Code -eq 0 -and (Get-GcResultObject $c).action -eq 'up-to-date') ($c.Text)
    & git -C $root switch feat/smoke-change 2>&1 | Out-Null

    # -------- bump ceremony -------------------------------------------------
    Set-Content -Path (Join-Path $root 'package.json') -Value '{"name":"smoke","version":"1.2.3"}'
    Set-Content -Path (Join-Path $root 'b.txt') -Value 'dirty'
    $c = Invoke-GcScript 'gc-bump' @('-Minor','-Reason','dirty tree test')
    Assert-That 'gc-bump — dirty tree refused (2)' ($c.Code -eq 2) ($c.Text)
    & git -C $root checkout -- b.txt 2>&1 | Out-Null
    # the manifest itself must be committed before the bump (bump = its own commit)
    & git -C $root add package.json 2>&1 | Out-Null
    & git -C $root commit -m 'chore: seed manifest' 2>&1 | Out-Null

    $c = Invoke-GcScript 'gc-bump' @('-Minor','-Reason','adds token refresh')
    Assert-GcContract $c 'gc-bump minor'
    $ver = ((Get-Content (Join-Path $root 'package.json') -Raw) -match '"version"\s*:\s*"1\.3\.0"')
    $subj = (($(& git -C $root log -1 --format=%s) | Out-String).Trim())
    Assert-That 'gc-bump — 1.2.3 -> 1.3.0 with ceremony subject' ($c.Code -eq 0 -and $ver -and $subj -eq 'chore(release): 1.2.3 -> 1.3.0') ($c.Text)

    $c = Invoke-GcScript 'gc-bump' @('-Major','-Reason','breaking api surface')
    Assert-That 'gc-bump — major 1.3.0 -> 2.0.0' ($c.Code -eq 0 -and ((Get-Content (Join-Path $root 'package.json') -Raw) -match '"version"\s*:\s*"2\.0\.0"')) ($c.Text)
    $c = Invoke-GcScript 'gc-bump' @('-Set','1.0.0','-Reason','downward')
    Assert-That 'gc-bump — downward refused (2)' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-bump' @('-Reason','no direction')
    Assert-That 'gc-bump — no direction refused (2)' ($c.Code -eq 2) ($c.Text)
    $c = Invoke-GcScript 'gc-bump' @('-Set','5.0.0','-Reason','explicit target')
    Assert-That 'gc-bump — -Set 5.0.0 lands' ($c.Code -eq 0 -and ((Get-Content (Join-Path $root 'package.json') -Raw) -match '"version"\s*:\s*"5\.0\.0"')) ($c.Text)
    $subj = (($(& git -C $root log -1 --format=%s) | Out-String).Trim())
    Assert-That 'gc-bump — -Set subject exact' ($subj -eq 'chore(release): 2.0.0 -> 5.0.0') ($subj)
    $c = Invoke-GcScript 'gc-bump' @('-Patch','-Reason','battery patch proof')
    $ver = ((Get-Content (Join-Path $root 'package.json') -Raw) -match '"version"\s*:\s*"5\.0\.1"')
    $subj = (($(& git -C $root log -1 --format=%s) | Out-String).Trim())
    Assert-That 'gc-bump — -Patch path 5.0.0 -> 5.0.1' ($c.Code -eq 0 -and $ver -and $subj -eq 'chore(release): 5.0.0 -> 5.0.1') ($c.Text)

    # -------- gc-release (§9): renderers + refusals, no gh/npm/network -----
    Set-Content -Path (Join-Path $relDir 'CHANGELOG.md') -Value (@(
        '# Changelog','',
        '## 2.0.0 (2026-01-01)','',
        '### Added','',
        '- newest thing','',
        '## 1.9.0','',
        '### Fixed','',
        '- older fix','',
        '- second older line'
    ) -join "`n")
    $sec = @(Get-GcChangelogSection -Root $relDir -Version '2.0.0')
    Assert-That 'Get-GcChangelogSection — body without heading, stops at next section' (
        $sec.Count -eq 3 -and $sec[0] -eq '### Added' -and $sec[2] -eq '- newest thing'
    ) ('[' + ($sec -join '|') + ']')
    $secLast = @(Get-GcChangelogSection -Root $relDir -Version '1.9.0')
    Assert-That 'Get-GcChangelogSection — last section runs to EOF, blank-trimmed' (
        $secLast.Count -eq 5 -and $secLast[4] -eq '- second older line'
    ) ('[' + ($secLast -join '|') + ']')
    $relBody = Format-GcReleaseBody -Version '2.0.0' -Lines $sec
    Assert-That 'Format-GcReleaseBody — Version line + section verbatim' (
        $relBody -eq "Version: 2.0.0`n`n### Added`n`n- newest thing"
    ) ('[' + $relBody + ']')
    $relMissing = $null
    try { Get-GcChangelogSection -Root $relDir -Version '9.9.9' | Out-Null } catch { $relMissing = $_ }
    Assert-That 'Get-GcChangelogSection — missing section is a Pre stop (2) naming the fix' (
        $null -ne $relMissing -and $relMissing.Exception -is [GcException] -and
        $relMissing.Exception.Code -eq 2 -and $relMissing.Exception.Message -match 'no section'
    ) "$relMissing"

    & git -C $relRepo init -b main 2>&1 | Out-Null
    & git -C $relRepo config user.name 'gc smoke' 2>&1 | Out-Null
    & git -C $relRepo config user.email 'gc-smoke@test' 2>&1 | Out-Null
    Set-Content -Path (Join-Path $relRepo 'seed.txt') -Value 'x'
    & git -C $relRepo add seed.txt 2>&1 | Out-Null
    & git -C $relRepo commit -m 'chore: seed' 2>&1 | Out-Null
    $c = Invoke-GcScript 'gc-release' @('-MovingLatest') -Root $relRepo
    Assert-GcContract $c 'gc-release no-remote'
    Assert-That 'gc-release — no remote refused (2), names the fix' (
        $c.Code -eq 2 -and $c.Text -match 'no git remote'
    ) ($c.Text)
    Set-Content -Path (Join-Path $relRepo 'dirty.txt') -Value 'y'
    $c = Invoke-GcScript 'gc-release' @('-MovingLatest') -Root $relRepo
    Assert-GcContract $c 'gc-release dirty tree'
    Assert-That 'gc-release — dirty tree refused (2), names clean' (
        $c.Code -eq 2 -and $c.Text -match 'not clean'
    ) ($c.Text)
    Remove-Item -LiteralPath (Join-Path $relRepo 'dirty.txt') -Force
    $c = Invoke-GcScript 'gc-branch' @('-Type','feat','-Slug','rel-probe') -Root $relRepo
    Assert-That 'gc-release setup — feature branch created' ($c.Code -eq 0) ($c.Text)
    $c = Invoke-GcScript 'gc-release' @('-MovingLatest') -Root $relRepo
    Assert-That 'gc-release — non-default branch refused (2), names the switch' (
        $c.Code -eq 2 -and $c.Text -match "switch to 'main'"
    ) ($c.Text)

    # -------- status again: everything reported ----------------------------
    $c = Invoke-GcScript 'gc-status'
    $st = Get-GcResultObject $c
    Assert-That 'gc-status — final snapshot sane' ($c.Code -eq 0 -and $st.branch -eq 'feat/smoke-change' -and $st.default -eq 'main' -and $st.upstream -eq 'origin/feat/smoke-change') ($c.Text)
} catch {
    Write-Host "[FAIL] smoke crashed: $($_.Exception.Message)" -ForegroundColor Red
    $script:Failures++
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $bareOrigin -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $plainDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $relDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $relRepo -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$total = $script:Pass + $script:Failures
if ($script:Failures -eq 0) {
    Write-Host "gc smoke: $script:Pass/$total checks passed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "gc smoke: $($script:Failures) of $total checks failed" -ForegroundColor Red
    exit 1
}
