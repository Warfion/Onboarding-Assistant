[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$SubscriptionId,
    [string]$WorkspaceResourceId,
    [string]$WorkspaceName,
    [string]$ResourceGroupName,
    [string]$LogicAppName = 'la-watchlist-refresh',
    [switch]$DeleteResourceGroup,
    [switch]$SkipSentinelContributorCleanup,
    [switch]$SkipPrincipalDeletion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AzCliInstalled {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required but was not found in PATH.'
    }
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        $joined = $Arguments -join ' '
        throw "Azure CLI command failed: az $joined`n$output"
    }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $jsonStart = [Math]::Min(
        (@($text.IndexOf('{'), $text.IndexOf('[')) | Where-Object { $_ -ge 0 } | Measure-Object -Minimum).Minimum,
        [int]::MaxValue
    )

    if ($jsonStart -eq [int]::MaxValue) {
        throw "Azure CLI returned non-JSON output for: az $($Arguments -join ' ')`n$text"
    }

    $jsonText = $text.Substring($jsonStart)
    return $jsonText | ConvertFrom-Json
}

function Parse-ResourceId {
    param([Parameter(Mandatory = $true)][string]$ResourceId)

    $parts = $ResourceId -split '/'
    if ($parts.Length -lt 9 -or $parts[1] -ne 'subscriptions' -or $parts[3] -ne 'resourceGroups') {
        throw "Invalid resource ID format: $ResourceId"
    }

    return [pscustomobject]@{
        SubscriptionId = $parts[2]
        ResourceGroupName = $parts[4]
    }
}

function Resolve-WorkspaceResourceId {
    param(
        [string]$ExplicitWorkspaceResourceId,
        [string]$ExplicitWorkspaceName,
        [string]$ExplicitResourceGroupName
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitWorkspaceResourceId)) {
        return $ExplicitWorkspaceResourceId
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitResourceGroupName)) {
        $workspaceQuery = if (-not [string]::IsNullOrWhiteSpace($ExplicitWorkspaceName)) {
            "[?name=='$ExplicitWorkspaceName'].id"
        } else {
            '[].id'
        }

        $workspaces = @(Invoke-AzJson -Arguments @(
                'resource', 'list',
                '-g', $ExplicitResourceGroupName,
                '--resource-type', 'Microsoft.OperationalInsights/workspaces',
                '--query', $workspaceQuery,
                '-o', 'json'
            ))

        if ($workspaces.Count -eq 0) {
            throw "No Log Analytics workspace found in resource group '$ExplicitResourceGroupName'."
        }

        if ($workspaces.Count -gt 1) {
            Write-Host "Multiple workspaces found in resource group '$ExplicitResourceGroupName'. Re-run with -WorkspaceResourceId:" -ForegroundColor Yellow
            $workspaces | ForEach-Object { Write-Host " - $_" }
            throw 'Workspace resolution is ambiguous.'
        }

        return $workspaces[0]
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitWorkspaceName)) {
        $subscriptionIds = @(Invoke-AzJson -Arguments @(
                'account', 'list',
                '--query', "[?state=='Enabled'].id",
                '-o', 'json'
            ))

        $workspaceMatches = @()
        foreach ($subId in $subscriptionIds) {
            $ids = @(Invoke-AzJson -Arguments @(
                    'resource', 'list',
                    '--subscription', $subId,
                    '--resource-type', 'Microsoft.OperationalInsights/workspaces',
                    '--query', "[?name=='$ExplicitWorkspaceName'].id",
                    '-o', 'json'
                ))

            foreach ($id in $ids) {
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    $workspaceMatches += $id
                }
            }
        }

        $workspaces = @($workspaceMatches | Sort-Object -Unique)

        if ($workspaces.Count -eq 0) {
            throw "No workspace discovered with name '$ExplicitWorkspaceName'. Provide -WorkspaceResourceId explicitly."
        }

        if ($workspaces.Count -gt 1) {
            Write-Host "Multiple workspaces found with name '$ExplicitWorkspaceName'. Re-run with -WorkspaceResourceId:" -ForegroundColor Yellow
            $workspaces | ForEach-Object { Write-Host " - $_" }
            throw 'Workspace resolution is ambiguous.'
        }

        return $workspaces[0]
    }

    $query = @"
resources
| where type =~ 'microsoft.operationsmanagement/solutions'
| where name startswith 'SecurityInsights('
| extend workspaceResourceId = tostring(properties.workspaceResourceId)
| where isnotempty(workspaceResourceId)
| project workspaceResourceId
| distinct workspaceResourceId
"@

    $result = Invoke-AzJson -Arguments @('graph', 'query', '-q', $query, '--first', '1000', '-o', 'json')
    $rows = @($result.data)
    $workspaces = @()
    foreach ($row in $rows) {
        $id = ($row | Select-Object -ExpandProperty workspaceResourceId -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $workspaces += $id
        }
    }

    if ($workspaces.Count -eq 0) {
        throw 'No Sentinel-enabled workspace discovered. Provide -WorkspaceResourceId explicitly.'
    }

    if ($workspaces.Count -gt 1) {
        Write-Host 'Multiple Sentinel-enabled workspaces found. Re-run with -WorkspaceResourceId (or provide -WorkspaceName with -ResourceGroupName):' -ForegroundColor Yellow
        $workspaces | ForEach-Object { Write-Host " - $_" }
        throw 'Workspace resolution is ambiguous.'
    }

    return $workspaces[0]
}

function Remove-RoleAssignmentsByIds {
    param([string[]]$AssignmentIds)

    foreach ($id in @($AssignmentIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($PSCmdlet.ShouldProcess($id, 'Delete role assignment')) {
            & az role assignment delete --ids $id | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to delete role assignment: $id"
            }
            Write-Host "Deleted role assignment: $id"
        }
    }
}

function Remove-ResourceById {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return
    }

    $exists = (& az resource show --ids $ResourceId --query id -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($exists)) {
        return
    }

    if ($PSCmdlet.ShouldProcess($ResourceId, 'Delete Azure resource')) {
        & az resource delete --ids $ResourceId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete resource: $ResourceId"
        }
        Write-Host "Deleted resource: $ResourceId"
    }
}

function Try-DeleteServicePrincipal {
    param([string]$PrincipalId)

    if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
        return
    }

    $spExists = & az ad sp show --id $PrincipalId --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($spExists)) {
        return
    }

    if ($PSCmdlet.ShouldProcess($PrincipalId, 'Delete Entra service principal')) {
        & az ad sp delete --id $PrincipalId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not delete service principal $PrincipalId. Check Entra permissions."
        } else {
            Write-Host "Deleted service principal: $PrincipalId"
        }
    }
}

Assert-AzCliInstalled

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    & az account set --subscription $SubscriptionId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Azure subscription: $SubscriptionId"
    }
}

$resolvedWorkspaceId = Resolve-WorkspaceResourceId -ExplicitWorkspaceResourceId $WorkspaceResourceId -ExplicitWorkspaceName $WorkspaceName -ExplicitResourceGroupName $ResourceGroupName
$parsed = Parse-ResourceId -ResourceId $resolvedWorkspaceId
$resolvedSubscriptionId = $parsed.SubscriptionId
$resolvedResourceGroupName = $parsed.ResourceGroupName

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and $SubscriptionId -ne $resolvedSubscriptionId) {
    throw "Provided -SubscriptionId does not match workspace subscription. Workspace is in subscription: $resolvedSubscriptionId"
}

& az account set --subscription $resolvedSubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription to workspace subscription: $resolvedSubscriptionId"
}

Write-Host "Workspace scope: $resolvedWorkspaceId"
Write-Host "Resource group: $resolvedResourceGroupName"
Write-Host "Subscription: $resolvedSubscriptionId"

$logicAppIds = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '-g', $resolvedResourceGroupName,
        '--resource-type', 'Microsoft.Logic/workflows',
        '--query', "[?name=='$LogicAppName'].id",
        '-o', 'json'
    ))

$functionAppIds = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '-g', $resolvedResourceGroupName,
        '--resource-type', 'Microsoft.Web/sites',
        '--query', "[?contains(kind, 'functionapp') && starts_with(name, 'func-wl-parser-')].id",
        '-o', 'json'
    ))

$planIds = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '-g', $resolvedResourceGroupName,
        '--resource-type', 'Microsoft.Web/serverfarms',
        '--query', "[?starts_with(name, 'plan-wl-parser-')].id",
        '-o', 'json'
    ))

$appInsightsIds = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '-g', $resolvedResourceGroupName,
        '--resource-type', 'Microsoft.Insights/components',
        '--query', "[?starts_with(name, 'ai-wl-parser-')].id",
        '-o', 'json'
    ))

$storageIds = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '-g', $resolvedResourceGroupName,
        '--resource-type', 'Microsoft.Storage/storageAccounts',
        '--query', "[?starts_with(name, 'stwlparser')].id",
        '-o', 'json'
    ))

$workbookIds = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '--resource-type', 'Microsoft.Insights/workbooks',
        '--query', "[?properties.sourceId=='$resolvedWorkspaceId' && properties.displayName=='Sentinel Data Source Onboarding Assistant'].id",
        '-o', 'json'
    ))

$watchlistIds = @(
    "$resolvedWorkspaceId/providers/Microsoft.SecurityInsights/watchlists/Con",
    "$resolvedWorkspaceId/providers/Microsoft.SecurityInsights/watchlists/Con_Meta"
)

$principalIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($id in @($logicAppIds + $functionAppIds)) {
    $pid = (& az resource show --ids $id --query identity.principalId -o tsv 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($pid)) {
        [void]$principalIds.Add($pid.Trim())
    }
}

Write-Host "Discovered resources for cleanup:"
Write-Host " - Logic Apps: $($logicAppIds.Count)"
Write-Host " - Function Apps: $($functionAppIds.Count)"
Write-Host " - App Service Plans: $($planIds.Count)"
Write-Host " - Application Insights: $($appInsightsIds.Count)"
Write-Host " - Storage Accounts: $($storageIds.Count)"
Write-Host " - Workbooks: $($workbookIds.Count)"
Write-Host " - Watchlists to remove: $($watchlistIds.Count)"
Write-Host " - Managed identity principals discovered: $($principalIds.Count)"

if (-not $SkipSentinelContributorCleanup) {
    $sentinelAssignments = @(Invoke-AzJson -Arguments @(
            'role', 'assignment', 'list',
            '--scope', $resolvedWorkspaceId,
            '--query', "[?roleDefinitionName=='Microsoft Sentinel Contributor'].id",
            '-o', 'json'
        ))

    Write-Host " - Sentinel Contributor assignments to delete: $($sentinelAssignments.Count)"
    Remove-RoleAssignmentsByIds -AssignmentIds $sentinelAssignments
}

foreach ($id in $watchlistIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in $workbookIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in $logicAppIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in $functionAppIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in $planIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in $appInsightsIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in $storageIds) {
    Remove-ResourceById -ResourceId $id
}

if ($DeleteResourceGroup) {
    if ($PSCmdlet.ShouldProcess($resolvedResourceGroupName, 'Delete entire resource group')) {
        & az group delete --name $resolvedResourceGroupName --yes --no-wait | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete resource group: $resolvedResourceGroupName"
        }
        Write-Host "Triggered resource group deletion: $resolvedResourceGroupName"
    }
}

if (-not $SkipPrincipalDeletion) {
    foreach ($pid in $principalIds) {
        Try-DeleteServicePrincipal -PrincipalId $pid
    }
}

Write-Host ''
Write-Host 'Reset flow completed.' -ForegroundColor Green
Write-Host 'Tip: run with -WhatIf first to preview destructive operations.' -ForegroundColor Cyan
