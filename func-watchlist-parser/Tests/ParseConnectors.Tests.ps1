BeforeAll {
    $scriptRoot = "$PSScriptRoot\..\ParseConnectors"

    $script:TriggerMetadata = @{ InvocationId = 'test-invocation-id' }

    # Mock Azure Function bindings
    function global:Push-OutputBinding { param($Name, $Value) $script:LastResponse = $Value }
    function global:Write-Information { param($MessageData) }

    # Extract function definitions using brace-depth tracking (handles nested braces)
    $scriptContent = Get-Content "$scriptRoot\run.ps1" -Raw
    $lines = $scriptContent -split "`n"
    $currentFunc = $null
    $braceDepth = 0

    foreach ($line in $lines) {
        if ($line -match '^\s*function\s+[\w-]+' -and -not $currentFunc) {
            $currentFunc = $line
            $braceDepth = ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count -
                          ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
        }
        elseif ($currentFunc) {
            $currentFunc += "`n$line"
            $braceDepth += ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count -
                           ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            if ($braceDepth -le 0) {
                $funcDef = $currentFunc -replace '\$PSScriptRoot', "'$($scriptRoot -replace "'", "''")'"
                try { Invoke-Expression $funcDef } catch { Write-Warning "Failed to load function: $_" }
                $currentFunc = $null
            }
        }
    }
}

Describe 'Get-DomainMap' {
    It 'Loads domain map from JSON file' {
        $map = Get-DomainMap
        $map | Should -BeOfType [hashtable]
        $map.Count | Should -BeGreaterThan 50
    }

    It 'Maps single-domain entries correctly' {
        $map = Get-DomainMap
        $map['CrowdStrike'].Domain | Should -Be 'Endpoint'
        $map['CrowdStrike'].Subdomain | Should -Be 'Detection & Response'
        $map['Palo Alto'].Domain | Should -Be 'Network / Perimeter'
        $map['Palo Alto'].Subdomain | Should -Be 'Firewall & Gateway'
        $map['Okta'].Domain | Should -Be 'Identity'
        $map['Okta'].Subdomain | Should -Be 'Authentication & SSO'
    }

    It 'Maps multi-domain entries correctly' {
        $map = Get-DomainMap
        $map['Office 365'] | Should -BeLike '*Identity*'
        $map['Microsoft Defender XDR'] | Should -BeLike '*Endpoint*'
    }
}

Describe 'Resolve-Domain' {
    BeforeAll {
        $script:domainMap = Get-DomainMap
    }

    It 'Resolves known connector to correct domain' {
        $result = Resolve-Domain -ConnectorName 'CrowdStrike Falcon' -DomainMap $script:domainMap
        $result.Domain | Should -Be 'Endpoint'
        $result.Subdomain | Should -Be 'Detection & Response'
    }

    It 'Resolves partial match' {
        $result = Resolve-Domain -ConnectorName 'Palo Alto Networks NGFW' -DomainMap $script:domainMap
        $result.Domain | Should -Be 'Network / Perimeter'
        $result.Subdomain | Should -Be 'Firewall & Gateway'
    }

    It 'Returns Other for unknown connectors' {
        $result = Resolve-Domain -ConnectorName 'SomeUnknownVendor XYZ' -DomainMap $script:domainMap
        $result.Domain | Should -Be 'Other'
        $result.Subdomain | Should -Be 'Other'
    }

    It 'Resolves vulnerability management subdomain' {
        $result = Resolve-Domain -ConnectorName 'Qualys Vulnerability Scanner' -DomainMap $script:domainMap
        $result.Domain | Should -Be 'Endpoint'
        $result.Subdomain | Should -Be 'Vulnerability Management'
    }

    It 'Resolves multi-domain connector with subdomains' {
        $result = Resolve-Domain -ConnectorName 'Office 365' -DomainMap $script:domainMap
        $result.Domain | Should -BeLike '*Identity*'
        $result.Domain | Should -BeLike '*Email*'
        $result.Subdomain | Should -BeLike '*Authentication*'
    }
}

Describe 'ConvertTo-ConnectorObject' {
    BeforeAll {
        $script:domainMap = Get-DomainMap
        $script:badgePatterns = @{
            '🚫' = 'Deprecated'; '⚠️' = 'Unpublished'; '🔍' = 'Discovered'
            '➕' = 'HasDocs';     '🔶' = 'CLv1'
        }
        $script:descriptions = @{ 'test-connector' = 'A test description' }
    }

    It 'Parses a standard connector row' {
        $cells = @('📊', '[Test Connector](connectors/test-connector.md)', 'Microsoft', 'Direct', '5', 'Solution A')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells `
            -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns `
            -Descriptions $script:descriptions `
            -DomainMap $script:domainMap `
            -SourceVersion 'abc123' `
            -RawConnector $cells[1]

        $result.'Connector Name' | Should -Be 'Test Connector'
        $result.'Connector ID' | Should -Be 'test-connector'
        $result.'Vendor' | Should -Be 'Microsoft Corporation'
        $result.'Method' | Should -Be 'Direct'
        $result.'Table Count' | Should -Be 5
        $result.'Solution' | Should -Be 'Solution A'
        $result.'Status' | Should -Be 'Active'
        $result.'Source Version' | Should -Be 'abc123'
        $result.'Connector Description' | Should -Be 'A test description'
    }

    It 'Normalizes Microsoft to Microsoft Corporation' {
        $cells = @('📊', 'Some Connector', 'Microsoft', 'API', '3', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Vendor' | Should -Be 'Microsoft Corporation'
    }

    It 'Extracts deprecated flag from emoji' {
        $cells = @('🚫', '🚫 Old Connector', 'Vendor', 'Syslog', '1', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Status' | Should -Be 'Deprecated'
        $result.'Flags' | Should -Match 'Deprecated'
    }

    It 'Marks deprecated when in deprecated section' {
        $cells = @('📊', 'Still Active Name', 'Vendor', 'API', '2', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $true `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Status' | Should -Be 'Deprecated'
    }

    It 'Returns null for empty connector name' {
        $cells = @('📊', '', 'Vendor', 'API', '2', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result | Should -BeNullOrEmpty
    }

    It 'Strips [Deprecated] prefix from name' {
        $cells = @('📊', '[Deprecated] Legacy Connector', 'Vendor', 'API', '1', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Connector Name' | Should -Be 'Legacy Connector'
    }

    It 'Parses table count from mixed text' {
        $cells = @('📊', 'Connector X', 'Vendor', 'API', '12 tables', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Table Count' | Should -Be 12
    }

    It 'Strips reference-style markdown links from name' {
        $cells = @('📊', '[[Deprecated] Awake Security via Legacy Agent][connectors/awake-security]', 'Arista Networks', 'AMA', '1', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Connector Name' | Should -Be 'Awake Security via Legacy Agent'
        $result.'Status' | Should -Be 'Deprecated'
    }

    It 'Sets Status to Deprecated when name contains Deprecated prefix' {
        $cells = @('📊', '[Deprecated] Old Connector', 'Vendor', 'API', '1', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Status' | Should -Be 'Deprecated'
    }

    It 'Strips inline markdown link with nested brackets like [[Recommended] Name](url)' {
        $raw = '[[Recommended] Infoblox Cloud Data Connector via AMA](connectors/infobloxclouddataconnectorama.md)'
        $cells = @('<img>', $raw, 'Infoblox', '[AMA](methods/ama.md)', '1', '[Infoblox](solutions/infoblox.md)')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $raw

        $result.'Connector Name' | Should -Be 'Infoblox Cloud Data Connector via AMA'
        $result.'Connector ID'   | Should -Be 'infobloxclouddataconnectorama'
        $result.'Vendor'         | Should -Be 'Infoblox'
        $result.'Method'         | Should -Be 'AMA'
    }

    It 'Strips simple inline markdown link [DNS](url) to plain name' {
        $raw = '[DNS](connectors/dns.md)'
        $cells = @('<img>', $raw, 'Microsoft', '[AMA](methods/ama.md)', '2', '[Windows Server DNS](solutions/windows-server-dns.md)')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $raw

        $result.'Connector Name' | Should -Be 'DNS'
        $result.'Connector ID'   | Should -Be 'dns'
    }

    It 'Includes Subdomain field in output' {
        $cells = @('📊', '[CrowdStrike Falcon](connectors/crowdstrike.md)', 'CrowdStrike', 'API', '5', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Domain' | Should -Be 'Endpoint'
        $result.'Subdomain' | Should -Be 'Detection & Response'
    }

    It 'Sets Subdomain to Other for unknown connectors' {
        $cells = @('📊', 'Unknown Fancy Connector', 'SomeVendor', 'API', '1', '')
        $result = ConvertTo-ConnectorObject `
            -Cells $cells -IsDeprecatedSection $false `
            -BadgePatterns $script:badgePatterns -Descriptions @{} `
            -DomainMap $script:domainMap -SourceVersion 'v1' -RawConnector $cells[1]

        $result.'Domain' | Should -Be 'Other'
        $result.'Subdomain' | Should -Be 'Other'
    }
}

Describe 'ConvertFrom-ConnectorMarkdown' {
    BeforeAll {
        $script:domainMap = Get-DomainMap
    }

    It 'Parses a minimal markdown table' {
        $markdown = @"
## A

| | Connector | Publisher | Method | Tables | Solution |
|---|---|---|---|---|---|
| 📊 | Alpha Connector | AlphaCorp | API | 3 | Alpha Solution |
| 📊 | Beta Connector | BetaCorp | Syslog | 1 | Beta Solution |
"@
        $result = ConvertFrom-ConnectorMarkdown `
            -Markdown $markdown -Descriptions @{} -DomainMap $script:domainMap `
            -SourceVersion 'test' -IncludeDeprecated $true

        $result.Count | Should -Be 2
        $result[0].'Connector Name' | Should -Be 'Alpha Connector'
        $result[1].'Connector Name' | Should -Be 'Beta Connector'
    }

    It 'Handles deprecated section correctly' {
        $markdown = @"
## A

| | Connector | Publisher | Method | Tables | Solution |
|---|---|---|---|---|---|
| 📊 | Active One | Vendor | API | 1 | Sol |

## 🚫 Deprecated

| | Connector | Publisher | Method | Tables | Solution |
|---|---|---|---|---|---|
| 🚫 | Old One | Vendor | Syslog | 0 | Sol |
"@
        $result = @(ConvertFrom-ConnectorMarkdown `
            -Markdown $markdown -Descriptions @{} -DomainMap $script:domainMap `
            -SourceVersion 'test' -IncludeDeprecated $true)

        $active = @($result | Where-Object { $_.'Status' -eq 'Active' })
        $deprecated = @($result | Where-Object { $_.'Status' -eq 'Deprecated' })
        $active.Count | Should -Be 1
        $deprecated.Count | Should -Be 1
    }

    It 'Excludes deprecated when IncludeDeprecated is false' {
        $markdown = @"
## 🚫 Deprecated

| | Connector | Publisher | Method | Tables | Solution |
|---|---|---|---|---|---|
| 🚫 | Old One | Vendor | Syslog | 0 | Sol |
"@
        $result = ConvertFrom-ConnectorMarkdown `
            -Markdown $markdown -Descriptions @{} -DomainMap $script:domainMap `
            -SourceVersion 'test' -IncludeDeprecated $false

        $result.Count | Should -Be 0
    }

    It 'Skips rows with fewer than 5 cells' {
        $markdown = @"
## A

| | Connector | Publisher | Method | Tables | Solution |
|---|---|---|---|---|---|
| 📊 | Good Row | Vendor | API | 3 | Sol |
| 📊 | Bad Row | Short |
"@
        $result = @(ConvertFrom-ConnectorMarkdown `
            -Markdown $markdown -Descriptions @{} -DomainMap $script:domainMap `
            -SourceVersion 'test' -IncludeDeprecated $true)

        $result.Count | Should -Be 1
    }

    It 'Preserves escaped pipes (\|) inside table cells' {
        $markdown = @"
## A

| | Connector | Publisher | Method | Tables | Solution |
|---|---|---|---|---|---|
| <img> | [1Password (Serverless)](connectors/1passwordccpdefinition.md) | 1Password | [CCF\|Azure Function](methods/ccf-azure-function.md) | 1 | [1Password](solutions/1password.md) |
"@
        $result = @(ConvertFrom-ConnectorMarkdown `
            -Markdown $markdown -Descriptions @{} -DomainMap $script:domainMap `
            -SourceVersion 'test' -IncludeDeprecated $true)

        $result.Count | Should -Be 1
        $result[0].'Connector Name' | Should -Be '1Password (Serverless)'
        $result[0].'Method' | Should -Be 'CCF|Azure Function'
        $result[0].'Table Count' | Should -Be 1
    }
}

Describe 'Test-ConnectorData' {
    It 'Returns no errors for valid data' {
        $connectors = [System.Collections.Generic.List[object]]::new()
        $connectors.Add([ordered]@{ 'Connector Name' = 'A'; 'Status' = 'Active' })
        $connectors.Add([ordered]@{ 'Connector Name' = 'B'; 'Status' = 'Deprecated' })

        $result = Test-ConnectorData -Connectors $connectors
        $result.Errors.Count | Should -Be 0
        $result.DuplicatesRemoved | Should -Be 0
    }

    It 'Detects empty connector names' {
        $connectors = [System.Collections.Generic.List[object]]::new()
        $connectors.Add([ordered]@{ 'Connector Name' = ''; 'Status' = 'Active' })

        $result = Test-ConnectorData -Connectors $connectors
        $result.Errors | Should -Contain '1 connectors have empty names'
    }

    It 'Deduplicates by keeping first occurrence' {
        $connectors = [System.Collections.Generic.List[object]]::new()
        $connectors.Add([ordered]@{ 'Connector Name' = 'Dup'; 'Status' = 'Active'; 'Vendor' = 'First' })
        $connectors.Add([ordered]@{ 'Connector Name' = 'Dup'; 'Status' = 'Active'; 'Vendor' = 'Second' })

        $result = Test-ConnectorData -Connectors $connectors
        $result.DuplicatesRemoved | Should -Be 1
        $result.Connectors.Count | Should -Be 1
        $result.Connectors[0].'Vendor' | Should -Be 'First'
    }

    It 'Reports error when no connectors parsed' {
        $connectors = [System.Collections.Generic.List[object]]::new()

        $result = Test-ConnectorData -Connectors $connectors
        $result.Errors | Should -Contain 'No connectors parsed from markdown'
    }
}

Describe 'Get-DescriptionsFromZip filter logic' {
    BeforeAll {
        # Helper that replicates the extraction logic from Get-DescriptionsFromZip
        function Invoke-DescriptionExtract {
            param([string]$Content)
            $lines = $Content -split "`n" | ForEach-Object { $_.Trim() }
            $pastHeading = $false
            foreach ($line in $lines) {
                if ($line -match '^#') { $pastHeading = $true; continue }
                if ($pastHeading -and $line -ne '' -and $line -notmatch '^\|' -and $line -notmatch '^\[!' -and $line -notmatch '^>' -and $line -notmatch '^<' -and $line -notmatch '^\*\*Browse' -and $line -notmatch '^↑' -and $line -notmatch '^---+$') {
                    $cleaned = $line -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
                    if ($cleaned -match '(?i)^(Back to |← )') { continue }
                    $cleaned = $cleaned -replace '<(?:br|/?p|/?div|/?li|/?ol|/?ul)[^>]*>', "`n" -replace '<[^>]+>', '' -replace '[ ]{2,}', ' ' -replace '\n+', "`n"
                    return $cleaned.Trim()
                }
            }
            return $null
        }
    }

    It 'Skips Browse breadcrumb lines and returns actual description' {
        $content = @"
# Connector Title
**Browse:** 🏠 · Solutions · Connectors · Methods
<img src="logo.png" />
> Some blockquote
| Table | Header |
[!INCLUDE [banner](includes/banner.md)]
The actual description of this connector goes here.
"@
        Invoke-DescriptionExtract $content | Should -Be 'The actual description of this connector goes here.'
    }

    It 'Skips Back to navigation links and returns actual description' {
        $content = @"
# CrowdStrike Falcon
[Back to Connectors Index](../index.md)
The CrowdStrike Falcon connector provides the capability to ingest events.
"@
        Invoke-DescriptionExtract $content | Should -Be 'The CrowdStrike Falcon connector provides the capability to ingest events.'
    }

    It 'Skips upward arrow Back to line, horizontal rule, and table to find description' {
        $content = @"
# 1Password (Serverless)
<img src="https://example.com/logo.svg" alt="" width="75" height="75">
**Browse:** [🏠](../README.md) · [Solutions](../solutions-index.md) · [Connectors](../connectors-index.md)
↑ [Back to Connectors Index](../connectors-index.md)
---
| Attribute | Value |
|:----------|:------|
| **Connector ID** | 1Password |
The 1Password CCP connector allows the user to ingest events into Microsoft Sentinel.
"@
        Invoke-DescriptionExtract $content | Should -Be 'The 1Password CCP connector allows the user to ingest events into Microsoft Sentinel.'
    }

    It 'Strips inline HTML tags from descriptions' {
        $content = @"
# CrowdStrike FDR
The connector ingests FDR events.<p><span style='color:red;'>NOTE:</span></p><div><p>1. License required.</p></div>
"@
        Invoke-DescriptionExtract $content | Should -Be "The connector ingests FDR events.`nNOTE:`n1. License required."
    }

    It 'Returns first valid line when no noise is present' {
        $content = @"
# Simple Connector
This connector ingests data from the source.
"@
        Invoke-DescriptionExtract $content | Should -Be 'This connector ingests data from the source.'
    }
}

Describe 'ConvertTo-WatchlistCsv' {
    It 'Produces valid CSV with header' {
        $connectors = [System.Collections.Generic.List[object]]::new()
        $connectors.Add([ordered]@{
            'Connector Name' = 'Test'
            'Connector ID' = 'test'
            'Connector Description' = 'Simple description'
            'Vendor' = 'TestCorp'
            'Method' = 'API'
            'Table Count' = 3
            'Solution' = 'Sol'
            'Status' = 'Active'
            'Flags' = ''
            'Source Version' = 'v1'
            'Domain' = 'Other'
            'Subdomain' = 'Other'
        })

        $csv = ConvertTo-WatchlistCsv -Connectors $connectors
        $lines = $csv -split "`n"
        $lines.Count | Should -Be 2  # header + 1 data row
        $lines[0] | Should -Match 'Connector Name'
        $lines[0] | Should -Match 'Subdomain'
    }

    It 'Preserves newlines in descriptions' {
        $connectors = [System.Collections.Generic.List[object]]::new()
        $connectors.Add([ordered]@{
            'Connector Name' = 'Test'
            'Connector ID' = 'test'
            'Connector Description' = "Has`r`nnewlines`ninside"
            'Vendor' = 'V'; 'Method' = 'M'; 'Table Count' = 0
            'Solution' = ''; 'Status' = 'Active'; 'Flags' = ''
            'Source Version' = 'v1'; 'Domain' = 'Other'; 'Subdomain' = 'Other'
        })

        $csv = ConvertTo-WatchlistCsv -Connectors $connectors
        $csv | Should -Match 'newlines'
    }
}
