[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$secretPath = Join-Path $repoRoot '.vscode/.secrets/context7_api_key.txt'

if (-not (Test-Path -LiteralPath $secretPath)) {
    throw "Encrypted key file not found: $secretPath. Run scripts/context7/Set-Context7ApiKey.ps1 first."
}

$encrypted = Get-Content -Path $secretPath -Raw
if ([string]::IsNullOrWhiteSpace($encrypted)) {
    throw "Encrypted key file is empty: $secretPath"
}

$secure = ConvertTo-SecureString -String $encrypted
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}

if ([string]::IsNullOrWhiteSpace($plain)) {
    throw 'Decrypted API key is empty.'
}

$env:CONTEXT7_API_KEY = $plain
Write-Host 'CONTEXT7_API_KEY loaded into current PowerShell session.' -ForegroundColor Green
