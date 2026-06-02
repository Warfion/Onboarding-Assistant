[CmdletBinding()]
param(
    [switch]$ImportKey,
    [int]$RetryCount = 2,
    [int]$RetryDelaySeconds = 2,
    [int]$ExpiryWarningDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ImportKey) {
    & (Join-Path $PSScriptRoot 'Import-Context7ApiKey.ps1')
}

if ([string]::IsNullOrWhiteSpace($env:CONTEXT7_API_KEY)) {
    Write-Error 'Missing CONTEXT7_API_KEY in environment. Import it first (scripts/context7/Import-Context7ApiKey.ps1).'
    exit 1
}

function Get-JwtExpiryUtc {
    param([string]$Token)

    if ($Token -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
        return $null
    }

    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) {
        return $null
    }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4 -ne 0) {
        $payload += '='
    }

    try {
        $bytes = [Convert]::FromBase64String($payload)
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        $obj = $json | ConvertFrom-Json
        if ($null -eq $obj.exp) {
            return $null
        }

        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$obj.exp).UtcDateTime
    } catch {
        return $null
    }
}

$expiresUtc = Get-JwtExpiryUtc -Token $env:CONTEXT7_API_KEY
if ($null -ne $expiresUtc) {
    $remaining = $expiresUtc - [DateTime]::UtcNow
    if ($remaining.TotalSeconds -le 0) {
        Write-Error "CONTEXT7_API_KEY is expired (exp=$($expiresUtc.ToString('u'))). Refresh it now."
        exit 1
    }

    if ($remaining.TotalDays -le $ExpiryWarningDays) {
        Write-Warning "CONTEXT7_API_KEY expires in $([Math]::Floor($remaining.TotalDays)) day(s) on $($expiresUtc.ToString('u'))."
    }
}

$probeUri = 'https://api.mcp.github.com'
$headers = @{
    Authorization = "Bearer $($env:CONTEXT7_API_KEY)"
}

for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
    try {
        $null = Invoke-WebRequest -Uri $probeUri -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        Write-Host 'Context7 preflight passed: authentication probe returned success.' -ForegroundColor Green
        exit 0
    } catch {
        $statusCode = $null
        $message = $_.Exception.Message

        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 401 -or $message -match '401') {
            Write-Error 'Context7 authentication failed (401 token invalid/expired). Refresh key and rerun preflight.'
            exit 1
        }

        if ($attempt -lt $RetryCount) {
            Write-Warning "Context7 probe transient failure (attempt $($attempt + 1)/$($RetryCount + 1)): $message"
            Start-Sleep -Seconds $RetryDelaySeconds
            continue
        }

        Write-Warning 'Context7 probe failed after retries. Continue with clear warning and fallback documentation sources for this session.'
        Write-Warning "Last probe error: $message"
        exit 2
    }
}
