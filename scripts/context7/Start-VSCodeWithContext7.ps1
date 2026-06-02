[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

& (Join-Path $PSScriptRoot 'Import-Context7ApiKey.ps1')
if ([string]::IsNullOrWhiteSpace($env:CONTEXT7_API_KEY)) {
    throw 'Failed to load CONTEXT7_API_KEY into session.'
}

$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if (-not $codeCmd) {
    throw 'VS Code CLI command not found. Install shell command: "code" and retry.'
}

Write-Host 'Starting VS Code with CONTEXT7_API_KEY loaded in process environment...' -ForegroundColor Green
& code $repoRoot
