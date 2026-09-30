param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  $stateRoot = if ($env:XDG_STATE_HOME) {
    $env:XDG_STATE_HOME
  } else {
    Join-Path $env:USERPROFILE '.local\state'
  }

  $servicePath = Join-Path $stateRoot 'opencode\service.json'
  if (-not (Test-Path -LiteralPath $servicePath)) {
    $servicePath = Join-Path $env:USERPROFILE '.config\opencode\service.json'
  }

  if (-not (Test-Path -LiteralPath $servicePath)) {
    throw 'OpenCode service registration not found'
  }

  $service = Get-Content -LiteralPath $servicePath -Raw | ConvertFrom-Json
  if (-not $service.password) { throw 'service registration has no password' }
  if (-not $service.url -and -not $service.port) { throw 'service registration has neither url nor port' }
  $baseUrl = if ($service.url) { "$($service.url)" } else { "http://127.0.0.1:$($service.port)" }
  $serviceUri = [uri]$baseUrl
  if ($serviceUri.Scheme -notin @('http', 'https') -or -not $serviceUri.IsLoopback) {
    throw 'service registration URL must be loopback HTTP(S)'
  }
  $token = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes("opencode:$($service.password)")
  )
  $headers = @{ Authorization = "Basic $token" }
  $sessionId = $Target.Trim()
  if (-not $sessionId) { throw 'target must not be empty' }

  if ($sessionId -notmatch '^ses_') {
    $activeResponse = Invoke-RestMethod "$baseUrl/api/session/active" -Headers $headers -TimeoutSec 8
    $activeIds = if ($null -eq $activeResponse.data) {
      @()
    } else {
      @($activeResponse.data.PSObject.Properties | ForEach-Object { $_.Name })
    }
    $query = [uri]::EscapeDataString(($sessionId -replace '^(the|a|an)\s+', ''))
    $searchResponse = Invoke-RestMethod "$baseUrl/api/session?search=$query&order=desc&limit=20" -Headers $headers -TimeoutSec 8
    $searchItems = if ($null -eq $searchResponse.data) { @() } else { @($searchResponse.data) }
    $matches = @($searchItems | Where-Object { $null -ne $_ -and $activeIds -contains $_.id })

    if ($matches.Count -ne 1) {
      throw "expected one running match for '$Target'; found $($matches.Count)"
    }
    $sessionId = $matches[0].id
  }

  if ($sessionId -notmatch '^ses_[A-Za-z0-9]+$') { throw 'target is not a valid session ID' }
  $escapedSessionId = [uri]::EscapeDataString($sessionId)
  $result = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/session/$escapedSessionId/interrupt" -Headers $headers -TimeoutSec 8
  "interrupted=$($result.interrupted)"
} catch {
  "kill failed: $($_.Exception.Message)"
  exit 1
}
