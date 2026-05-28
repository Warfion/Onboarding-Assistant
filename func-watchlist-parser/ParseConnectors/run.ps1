using namespace System.Net
using namespace System.IO
using namespace System.IO.Compression

param($Request, $TriggerMetadata)

# ============================================================
# ParseConnectors — Azure Function (HTTP POST)
# Input:  { connectorsIndexMarkdown, repoZipBase64|repoZipUrl, sourceVersion, options }
# Output: { csv, stats }
# ============================================================

$ErrorActionPreference = 'Stop'

# --- Lightweight shared-secret gate for Logic App calls ---
$expectedSharedSecret = [Environment]::GetEnvironmentVariable('REFRESH_SHARED_SECRET')
if (-not [string]::IsNullOrWhiteSpace($expectedSharedSecret)) {
    $providedSharedSecret = $null
    if ($Request -and $Request.Headers) {
        foreach ($headerName in $Request.Headers.Keys) {
            if ($headerName -ieq 'x-refresh-secret') {
                $headerValue = $Request.Headers[$headerName]
                if ($headerValue -is [System.Array]) {
                    $providedSharedSecret = [string]($headerValue[0])
                } else {
                    $providedSharedSecret = [string]$headerValue
                }
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($providedSharedSecret) -or $providedSharedSecret -ne $expectedSharedSecret) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Unauthorized
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = @{ error = 'Unauthorized' }
        })
        return
    }
}

# --- Structured logging helper ---
function Write-Trace {
    param(
        [string]$Message,
        [string]$Level = 'Information',
        [hashtable]$Properties = @{}
    )
    $entry = @{
        timestamp    = (Get-Date -Format 'o')
        level        = $Level
        message      = $Message
        invocationId = $TriggerMetadata.InvocationId
    }
    foreach ($k in $Properties.Keys) { $entry[$k] = $Properties[$k] }
    # Write-Information feeds into App Insights traces via host configuration
    Write-Information ($entry | ConvertTo-Json -Compress -Depth 3)
}

# --- Load domain map from config ---
function Get-DomainMap {
    $mapPath = Join-Path $PSScriptRoot 'domain-map.json'
    $raw = Get-Content $mapPath -Raw | ConvertFrom-Json

    $domainMap = @{}
    foreach ($prop in ($raw.PSObject.Properties | Where-Object { $_.Name -ne '_multiDomain' })) {
        # Key format: "Domain / Subdomain" — split on LAST " / " delimiter
        $key = $prop.Name
        $lastSep = $key.LastIndexOf(' / ')
        if ($lastSep -gt 0) {
            $domain = $key.Substring(0, $lastSep)
            $subdomain = $key.Substring($lastSep + 3)
        } else {
            $domain = $key
            $subdomain = $key
        }
        foreach ($pattern in $prop.Value) {
            $domainMap[$pattern] = @{ Domain = $domain; Subdomain = $subdomain }
        }
    }
    if ($raw._multiDomain) {
        foreach ($entry in $raw._multiDomain.PSObject.Properties) {
            # Multi-domain values are comma-separated "Domain / Subdomain" pairs
            $domainMap[$entry.Name] = $entry.Value
        }
    }
    return $domainMap
}

# --- Resolve domain for a connector name ---
function Resolve-Domain {
    param(
        [string]$ConnectorName,
        [hashtable]$DomainMap
    )
    foreach ($pattern in $DomainMap.Keys) {
        if ($ConnectorName -like "*$pattern*") {
            $val = $DomainMap[$pattern]
            if ($val -is [hashtable]) {
                return $val
            }
            # Multi-domain string: parse each "Domain / Subdomain" entry
            $domains = @()
            $subdomains = @()
            foreach ($part in ($val -split ',')) {
                $trimmed = $part.Trim()
                $lastSep = $trimmed.LastIndexOf(' / ')
                if ($lastSep -gt 0) {
                    $domains += $trimmed.Substring(0, $lastSep)
                    $subdomains += $trimmed.Substring($lastSep + 3)
                } else {
                    $domains += $trimmed
                    $subdomains += $trimmed
                }
            }
            return @{ Domain = ($domains -join ', '); Subdomain = ($subdomains -join ', ') }
        }
    }
    return @{ Domain = 'Other'; Subdomain = 'Other' }
}

# --- Download ZIP from URL if needed ---
function Get-ZipBase64 {
    param(
        [string]$ZipBase64,
        [string]$RepoZipUrl
    )
    if ($ZipBase64) { return $ZipBase64 }
    if (-not $RepoZipUrl) { return $null }

    try {
        Write-Trace "Downloading ZIP from URL" -Properties @{ url = $RepoZipUrl }
        $response = Invoke-WebRequest -Uri $RepoZipUrl -UseBasicParsing -MaximumRetryCount 2
        Write-Trace "ZIP downloaded" -Properties @{ sizeBytes = $response.Content.Length }
        return [Convert]::ToBase64String($response.Content)
    }
    catch {
        Write-Trace "ZIP download failed, continuing without descriptions" -Level 'Warning' -Properties @{ error = $_.ToString() }
        return $null
    }
}

# --- Extract descriptions from repo ZIP ---
function Get-DescriptionsFromZip {
    param([string]$ZipBase64)
    $descriptions = @{}
    if (-not $ZipBase64) { return $descriptions }

    try {
        $zipBytes = [Convert]::FromBase64String($ZipBase64)
        $memStream = [MemoryStream]::new($zipBytes)
        $archive = [ZipArchive]::new($memStream, [ZipArchiveMode]::Read)

        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match 'Solutions Docs/connectors/([^/]+)\.md$') {
                $slug = $Matches[1]
                $reader = [StreamReader]::new($entry.Open())
                $content = $reader.ReadToEnd()
                $reader.Close()

                # Extract first non-heading, non-empty paragraph after the first heading
                $lines = $content -split "`n" | ForEach-Object { $_.Trim() }
                $pastHeading = $false
                foreach ($line in $lines) {
                    if ($line -match '^#') { $pastHeading = $true; continue }
                    if ($pastHeading -and $line -ne '' -and $line -notmatch '^\|' -and $line -notmatch '^\[!' -and $line -notmatch '^>' -and $line -notmatch '^<' -and $line -notmatch '^\*\*Browse' -and $line -notmatch '^↑' -and $line -notmatch '^---+$') {
                        $cleaned = $line -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
                        if ($cleaned -match '(?i)^(Back to |← )') { continue }
                        $cleaned = $cleaned -replace '<(?:br|/?p|/?div|/?li|/?ol|/?ul)[^>]*>', "`n" -replace '<[^>]+>', '' -replace '[ ]{2,}', ' ' -replace '\n+', "`n"
                        $descriptions[$slug] = $cleaned.Trim()
                        break
                    }
                }
            }
        }
        $archive.Dispose()
        $memStream.Dispose()
        Write-Trace "Descriptions extracted from ZIP" -Properties @{ count = $descriptions.Count }
    }
    catch {
        Write-Trace "ZIP parsing failed, continuing without descriptions" -Level 'Warning' -Properties @{ error = $_.ToString() }
    }
    return $descriptions
}

# --- Parse a single markdown table row into a connector object ---
function ConvertTo-ConnectorObject {
    param(
        [string[]]$Cells,
        [bool]$IsDeprecatedSection,
        [hashtable]$BadgePatterns,
        [hashtable]$Descriptions,
        [hashtable]$DomainMap,
        [string]$SourceVersion,
        [string]$RawConnector
    )

    # Strip inline markdown links [text](url) — supports nested brackets like [[Recommended] Name](url)
    $connectorName = $RawConnector -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^\)]*\)', '$1'
    # Strip reference-style links [text][ref]
    $connectorName = $connectorName -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\[[^\]]+\]', '$1'
    # Unwrap plain bracket-wrapped names like [DNS] → DNS
    $connectorName = $connectorName -replace '^\s*\[([^\[\]]+)\]\s*$', '$1'

    # Extract flags from emoji badges
    $flags = @()
    foreach ($emoji in $BadgePatterns.Keys) {
        if ($connectorName -match [regex]::Escape($emoji)) {
            $flags += $BadgePatterns[$emoji]
        }
    }
    # Strip emojis, prefixes, and normalize whitespace
    $connectorName = $connectorName -replace '[🚫⚠️🔍➕🔶]', ''
    $connectorName = $connectorName -replace '\s+', ' '
    $connectorName = $connectorName.Trim()

    # Detect deprecated prefix BEFORE stripping it
    $hasDeprecatedPrefix = $connectorName -match '(?i)^\[?Deprecated\]?'
    $connectorName = $connectorName -replace '^\[(Deprecated|DEPRECATED|Recommended)\]\s*', ''

    if ($connectorName -eq '' -or $connectorName -eq 'Connector') { return $null }

    # Status
    $status = if ($IsDeprecatedSection -or $flags -contains 'Deprecated' -or $hasDeprecatedPrefix) { 'Deprecated' } else { 'Active' }

    # Vendor (normalize Microsoft → Microsoft Corporation)
    $vendor = ($Cells[2] -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^\)]*\)', '$1' -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\[[^\]]+\]', '$1' -replace '^\[([^\[\]]+)\]$', '$1').Trim()
    if ($vendor -eq 'Microsoft') { $vendor = 'Microsoft Corporation' }

    # Method, Table count, Solution
    $method = ($Cells[3] -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^\)]*\)', '$1' -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\[[^\]]+\]', '$1' -replace '^\[([^\[\]]+)\]$', '$1').Trim()
    if ($method -eq '' -or $method -eq 'Unknown') { $method = 'Native' }
    $tableCount = 0
    if ($Cells[4] -match '(\d+)') { $tableCount = [int]$Matches[1] }
    $solution = if ($Cells.Count -ge 6) { ($Cells[5] -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^\)]*\)', '$1' -replace '\[((?:[^\[\]]|\[[^\]]*\])*)\]\[[^\]]+\]', '$1' -replace '^\[([^\[\]]+)\]$', '$1').Trim() } else { '' }

    # Description (from ZIP slug lookup)
    $slug = ''
    if ($RawConnector -match '\]\(connectors/([^)]+)\.md\)') { $slug = $Matches[1] }
    elseif ($RawConnector -match '\]\[connectors/([^\]]+)\]') { $slug = $Matches[1] }
    $description = if ($slug -and $Descriptions.ContainsKey($slug)) { $Descriptions[$slug] } else { '' }

    # Domain + Subdomain
    $resolved = Resolve-Domain -ConnectorName $connectorName -DomainMap $DomainMap

    return [ordered]@{
        'Connector Name'        = $connectorName
        'Connector ID'          = $slug
        'Connector Description' = $description
        'Vendor'                = $vendor
        'Method'                = $method
        'Table Count'           = $tableCount
        'Solution'              = $solution
        'Status'                = $status
        'Flags'                 = ($flags -join ', ')
        'Source Version'        = $SourceVersion
        'Domain'                = $resolved.Domain
        'Subdomain'             = $resolved.Subdomain
    }
}

# --- Parse all connectors from markdown ---
function ConvertFrom-ConnectorMarkdown {
    param(
        [string]$Markdown,
        [hashtable]$Descriptions,
        [hashtable]$DomainMap,
        [string]$SourceVersion,
        [bool]$IncludeDeprecated
    )

    $badgePatterns = @{
        '🚫' = 'Deprecated'; '⚠️' = 'Unpublished'; '🔍' = 'Discovered'
        '➕' = 'HasDocs';     '🔶' = 'CLv1'
    }

    $connectors = [System.Collections.Generic.List[object]]::new()
    $lines = $Markdown -split "`n"
    $inTable = $false
    $isDeprecatedSection = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match '## 🚫 Deprecated') { $isDeprecatedSection = $true; $inTable = $false; continue }
        if ($trimmed -match '^## [A-Z#]$' -or $trimmed -match '^## [A-Z]$') { $isDeprecatedSection = $false; $inTable = $false; continue }
        if ($trimmed -match '^\|\s*\|\s*Connector\s*\|') { $inTable = $true; continue }
        if ($trimmed -match '^\|[\s:|-]+\|$') { continue }

        if ($inTable -and $trimmed -match '^\|') {
            # Preserve escaped pipes (\|) inside cells before splitting on |, then restore
            $protectedLine = $trimmed -replace '\\\|', '<<ESCPIPE>>'
            $rawCells = $protectedLine -split '\|'
            # A markdown table row starts and ends with |, so first/last split elements are empty wrappers
            if ($rawCells.Count -lt 3) { continue }
            $cells = $rawCells[1..($rawCells.Count - 2)] | ForEach-Object { ($_ -replace '<<ESCPIPE>>', '|').Trim() }
            if ($cells.Count -lt 5) { continue }

            $obj = ConvertTo-ConnectorObject `
                -Cells $cells `
                -IsDeprecatedSection $isDeprecatedSection `
                -BadgePatterns $badgePatterns `
                -Descriptions $Descriptions `
                -DomainMap $DomainMap `
                -SourceVersion $SourceVersion `
                -RawConnector $cells[1]

            if (-not $obj) { continue }
            if ($obj.'Status' -eq 'Deprecated' -and -not $IncludeDeprecated) { continue }

            $connectors.Add($obj)
        }
    }

    return $connectors
}

# --- Validate parsed connectors, deduplicate, return errors ---
function Test-ConnectorData {
    param([System.Collections.Generic.List[object]]$Connectors)

    $errors = @()
    if ($Connectors.Count -eq 0) { $errors += 'No connectors parsed from markdown' }

    $emptyNames = @($Connectors | Where-Object { -not $_.'Connector Name' })
    if ($emptyNames.Count -gt 0) { $errors += "$($emptyNames.Count) connectors have empty names" }

    $invalidStatuses = @($Connectors | Where-Object { $_.'Status' -notin @('Active', 'Deprecated') })
    if ($invalidStatuses.Count -gt 0) { $errors += "$($invalidStatuses.Count) connectors have invalid status" }

    # Deduplicate (keep first occurrence)
    $dupeGroups = @($Connectors | Group-Object { $_.'Connector Name' } | Where-Object { $_.Count -gt 1 })
    if ($dupeGroups.Count -gt 0) {
        $seen = @{}
        $deduped = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $Connectors) {
            $name = $c.'Connector Name'
            if (-not $seen.ContainsKey($name)) { $seen[$name] = $true; $deduped.Add($c) }
        }
        return @{ Errors = $errors; Connectors = $deduped; DuplicatesRemoved = $dupeGroups.Count }
    }

    return @{ Errors = $errors; Connectors = $Connectors; DuplicatesRemoved = 0 }
}

# --- Convert connector list to CSV string ---
function ConvertTo-WatchlistCsv {
    param([System.Collections.Generic.List[object]]$Connectors)

    $csvObjects = $Connectors | ForEach-Object { [PSCustomObject]$_ }
    $csvLines = @($csvObjects | ConvertTo-Csv)
    return ($csvLines -join "`n")
}

# ============================================================
# MAIN FLOW
# ============================================================

Write-Trace "Function invoked" -Properties @{
    hasMarkdown  = [bool]$Request.Body.connectorsIndexMarkdown
    hasZipBase64 = [bool]$Request.Body.repoZipBase64
    hasZipUrl    = [bool]$Request.Body.repoZipUrl
    sourceVersion = $Request.Body.sourceVersion
}

# --- Read input ---
$body           = $Request.Body
$indexMd        = $body.connectorsIndexMarkdown
$sourceVersion  = $body.sourceVersion
$options        = $body.options
$includeDeprecated = if ($options -and $options.includeDeprecated -eq $false) { $false } else { $true }

if (-not $indexMd) {
    Write-Trace "Rejected: missing connectorsIndexMarkdown" -Level 'Warning'
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::BadRequest
        Body        = '{"error":"connectorsIndexMarkdown is required"}'
        ContentType = 'application/json'
    })
    return
}

# --- Resolve ZIP (download if URL provided) ---
$zipBase64 = Get-ZipBase64 -ZipBase64 $body.repoZipBase64 -RepoZipUrl $body.repoZipUrl

# --- Load config + extract descriptions ---
$domainMap    = Get-DomainMap
$descriptions = Get-DescriptionsFromZip -ZipBase64 $zipBase64

# --- Parse markdown → connector objects ---
$connectors = ConvertFrom-ConnectorMarkdown `
    -Markdown $indexMd `
    -Descriptions $descriptions `
    -DomainMap $domainMap `
    -SourceVersion $sourceVersion `
    -IncludeDeprecated $includeDeprecated

Write-Trace "Parsing complete" -Properties @{ rawCount = $connectors.Count }

# --- Validate + deduplicate ---
$validation = Test-ConnectorData -Connectors $connectors

if ($validation.DuplicatesRemoved -gt 0) {
    Write-Trace "Duplicates removed" -Level 'Warning' -Properties @{ count = $validation.DuplicatesRemoved }
    $connectors = $validation.Connectors
}

if ($validation.Errors.Count -gt 0) {
    Write-Trace "Validation failed" -Level 'Error' -Properties @{ errors = $validation.Errors; parsedCount = $connectors.Count }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = [HttpStatusCode]::UnprocessableEntity
        Body        = (@{ errors = $validation.Errors; parsedCount = $connectors.Count } | ConvertTo-Json -Depth 5)
        ContentType = 'application/json'
    })
    return
}

# --- Build CSV + stats ---
$csvString       = ConvertTo-WatchlistCsv -Connectors $connectors
$activeCount     = @($connectors | Where-Object { $_.'Status' -eq 'Active' }).Count
$deprecatedCount = @($connectors | Where-Object { $_.'Status' -eq 'Deprecated' }).Count

$result = @{
    csv   = $csvString
    stats = @{
        total         = $connectors.Count
        active        = $activeCount
        deprecated    = $deprecatedCount
        sourceVersion = $sourceVersion
    }
} | ConvertTo-Json -Depth 5 -Compress

Write-Trace "Success" -Properties @{ total = $connectors.Count; active = $activeCount; deprecated = $deprecatedCount }

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode  = [HttpStatusCode]::OK
    Body        = $result
    ContentType = 'application/json'
})
