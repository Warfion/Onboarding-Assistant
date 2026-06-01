[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$SubscriptionId,
    [string]$WorkspaceResourceId,
    [string]$LogicAppResourceId,
    [string]$LogicAppName = 'la-watchlist-refresh',
    [switch]$ListOnly
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

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $joined = $Arguments -join ' '
        throw "Azure CLI command failed: az $joined`n$output"
    }

    if ([string]::IsNullOrWhiteSpace(($output | Out-String))) {
        return $null
    }

    return ($output | Out-String) | ConvertFrom-Json
}

function Get-SubscriptionIdFromResourceId {
    param([Parameter(Mandatory = $true)][string]$ResourceId)

    $parts = $ResourceId -split '/'
    if ($parts.Length -lt 3) {
        throw "Invalid resource ID format: $ResourceId"
    }

    return $parts[2]
}

function Resolve-WorkspaceResourceId {
    param([string]$ExplicitWorkspaceResourceId)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitWorkspaceResourceId)) {
        return $ExplicitWorkspaceResourceId
    }

    $query = @"
resources
| where type =~ 'microsoft.operationsmanagement/solutions'
| where name startswith 'SecurityInsights('
| extend workspaceResourceId = tostring(properties.workspaceResourceId)
| project workspaceResourceId
| where isnotempty(workspaceResourceId)
| distinct workspaceResourceId
"@

    $result = Invoke-AzJson -Arguments @('graph', 'query', '-q', $query, '--first', '1000', '-o', 'json')
    $workspaces = @($result.data)

    if ($workspaces.Count -eq 0) {
        throw 'No Sentinel-enabled workspace could be discovered. Provide -WorkspaceResourceId explicitly.'
    }

    if ($workspaces.Count -gt 1) {
        Write-Host 'Multiple Sentinel-enabled workspaces were found. Re-run with -WorkspaceResourceId using one of these values:' -ForegroundColor Yellow
        $workspaces | ForEach-Object { Write-Host " - $($_.workspaceResourceId)" }
        throw 'Workspace resolution is ambiguous.'
    }

    return $workspaces[0].workspaceResourceId
}

function Resolve-LogicAppResourceId {
    param(
        [string]$ExplicitLogicAppResourceId,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceResourceId,
        [Parameter(Mandatory = $true)][string]$ResolvedSubscriptionId,
        [Parameter(Mandatory = $true)][string]$DefaultLogicAppName
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitLogicAppResourceId)) {
        return $ExplicitLogicAppResourceId
    }

    $workspaceParts = $ResolvedWorkspaceResourceId -split '/'
    if ($workspaceParts.Length -lt 9) {
        throw "Invalid workspace resource ID format: $ResolvedWorkspaceResourceId"
    }

    $resourceGroup = $workspaceParts[4]
    $defaultId = "/subscriptions/$ResolvedSubscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/$DefaultLogicAppName"

    $defaultExists = & az resource show --ids $defaultId --query id -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($defaultExists)) {
        return $defaultId
    }

    $query = "resources | where type =~ 'microsoft.logic/workflows' | where resourceGroup =~ '$resourceGroup' | project id"
    $result = Invoke-AzJson -Arguments @('graph', 'query', '-q', $query, '--first', '100', '-o', 'json')
    $workflows = @($result.data)

    if ($workflows.Count -eq 1) {
        return $workflows[0].id
    }

    if ($workflows.Count -gt 1) {
        Write-Host "Multiple Logic Apps found in resource group '$resourceGroup'. Re-run with -LogicAppResourceId:" -ForegroundColor Yellow
        $workflows | ForEach-Object { Write-Host " - $($_.id)" }
        throw 'Logic App resolution is ambiguous.'
    }

    throw "No Logic App workflow found in resource group '$resourceGroup'. Provide -LogicAppResourceId explicitly."
}

Assert-AzCliInstalled

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    & az account set --subscription $SubscriptionId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Azure subscription: $SubscriptionId"
    }
}

$resolvedWorkspaceResourceId = Resolve-WorkspaceResourceId -ExplicitWorkspaceResourceId $WorkspaceResourceId
$resolvedSubscriptionId = Get-SubscriptionIdFromResourceId -ResourceId $resolvedWorkspaceResourceId
$resolvedLogicAppResourceId = Resolve-LogicAppResourceId `
    -ExplicitLogicAppResourceId $LogicAppResourceId `
    -ResolvedWorkspaceResourceId $resolvedWorkspaceResourceId `
    -ResolvedSubscriptionId $resolvedSubscriptionId `
    -DefaultLogicAppName $LogicAppName

$currentPrincipalId = (& az resource show --ids $resolvedLogicAppResourceId --query identity.principalId -o tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentPrincipalId)) {
    throw "Could not resolve system-assigned identity principalId for Logic App: $resolvedLogicAppResourceId"
}

$assignmentQuery = "[?roleDefinitionName=='Microsoft Sentinel Contributor'].{assignmentId:id,principalId:principalId}"
$assignments = @(Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--scope', $resolvedWorkspaceResourceId, '--query', $assignmentQuery, '-o', 'json'))
$staleAssignments = @($assignments | Where-Object { $_.principalId -ne $currentPrincipalId })

Write-Host "Workspace scope: $resolvedWorkspaceResourceId"
Write-Host "Logic App: $resolvedLogicAppResourceId"
Write-Host "Current Logic App principalId: $currentPrincipalId"
Write-Host "Sentinel Contributor assignments found: $($assignments.Count)"
Write-Host "Stale assignments found: $($staleAssignments.Count)"

if ($assignments.Count -gt 0) {
    Write-Host ''
    Write-Host 'Current assignments:'
    $assignments | Format-Table assignmentId, principalId -AutoSize
}

if ($ListOnly) {
    Write-Host ''
    Write-Host 'ListOnly mode enabled. No changes were made.' -ForegroundColor Cyan
    return
}

foreach ($assignment in $staleAssignments) {
    $assignmentId = $assignment.assignmentId
    if ($PSCmdlet.ShouldProcess($assignmentId, 'Delete stale Microsoft Sentinel Contributor role assignment')) {
        & az role assignment delete --ids $assignmentId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete role assignment: $assignmentId"
        }
        Write-Host "Deleted stale assignment: $assignmentId"
    }
}

$remaining = @(Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--scope', $resolvedWorkspaceResourceId, '--query', $assignmentQuery, '-o', 'json'))

Write-Host ''
Write-Host 'Remaining assignments:'
if ($remaining.Count -gt 0) {
    $remaining | Format-Table assignmentId, principalId -AutoSize
} else {
    Write-Host 'No Microsoft Sentinel Contributor assignments remain.'
}

if (@($remaining | Where-Object { $_.principalId -eq $currentPrincipalId }).Count -ge 1) {
    Write-Host ''
    Write-Host 'Cleanup complete. Current Logic App identity is present on the workspace scope.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Cleanup completed, but no assignment exists for the current Logic App identity. Redeploy may recreate the assignment.' -ForegroundColor Yellow
}
