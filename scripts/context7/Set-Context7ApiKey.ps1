[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$secretDir = Join-Path $repoRoot '.vscode/.secrets'
$secretPath = Join-Path $secretDir 'context7_api_key.txt'

if (-not (Test-Path -LiteralPath $secretDir)) {
    New-Item -ItemType Directory -Path $secretDir | Out-Null
}

$secure = Read-Host -Prompt 'Enter CONTEXT7_API_KEY' -AsSecureString
if ($secure.Length -eq 0) {
    throw 'No API key entered. Aborting.'
}

$encrypted = ConvertFrom-SecureString -SecureString $secure
Set-Content -Path $secretPath -Value $encrypted -NoNewline

Write-Host "Saved encrypted key to $secretPath" -ForegroundColor Green
Write-Host 'Run scripts/context7/Import-Context7ApiKey.ps1 before starting VS Code tasks that need Context7.' -ForegroundColor Cyan
