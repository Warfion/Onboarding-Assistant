[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$SubscriptionId,
    [string]$WorkspaceResourceId,
    [string]$WorkspaceName,
    [string]$ResourceGroupName,
    [string]$DeploymentResourceGroupName,
    [string]$LogicAppName = 'la-watchlist-refresh',
    [switch]$DeleteResourceGroup,
    [switch]$Force,
    [switch]$SkipSentinelContributorCleanup,
    [switch]$SkipPrincipalDeletion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SkipServicePrincipalDeletionDueToPermissions = $false

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

function Get-WorkspaceNameFromResourceId {
    param([Parameter(Mandatory = $true)][string]$WorkspaceResourceId)

    $parts = $WorkspaceResourceId -split '/'
    if ($parts.Length -lt 9) {
        throw "Invalid workspace resource ID format: $WorkspaceResourceId"
    }

    return $parts[8]
}

function Resolve-WorkspaceResourceId {
    param(
        [string]$ExplicitWorkspaceResourceId,
        [string]$ExplicitWorkspaceName,
        [string]$ExplicitResourceGroupName
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitWorkspaceResourceId)) {
        Write-Verbose "Using explicitly provided workspace resource ID."
        return $ExplicitWorkspaceResourceId
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitResourceGroupName)) {
        Write-Verbose "Resolving workspace from resource group '$ExplicitResourceGroupName'..."
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
        $currentSub = Invoke-AzJson -Arguments @('account', 'show', '--query', 'id', '-o', 'json')
        Write-Verbose "Searching for workspace '$ExplicitWorkspaceName' in current subscription: $currentSub"

        $workspaces = @(Invoke-AzJson -Arguments @(
                'resource', 'list',
                '--subscription', $currentSub,
                '--resource-type', 'Microsoft.OperationalInsights/workspaces',
                '--query', "[?name=='$ExplicitWorkspaceName'].id",
                '-o', 'json'
            ))

        if ($workspaces.Count -eq 0) {
            throw "No workspace named '$ExplicitWorkspaceName' found in subscription '$currentSub'. Switch subscription with 'az account set --subscription <id>' or use -SubscriptionId, or provide the full -WorkspaceResourceId."
        }

        if ($workspaces.Count -gt 1) {
            Write-Host "Multiple workspaces found with name '$ExplicitWorkspaceName'. Re-run with -WorkspaceResourceId:" -ForegroundColor Yellow
            $workspaces | ForEach-Object { Write-Host " - $_" }
            throw 'Workspace resolution is ambiguous.'
        }

        return $workspaces[0]
    }

    Write-Verbose "No workspace parameter provided. Auto-discovering Sentinel-enabled workspaces via Resource Graph..."
    Write-Verbose "Ensuring az resource-graph extension is available..."
    & az extension add --name resource-graph --upgrade --only-show-errors -y 2>$null | Out-Null

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
    Write-Verbose "Resource Graph query returned $(@($result.data).Count) row(s)."
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

function Resolve-DeploymentResourceGroups {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceId,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceName,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceSubscriptionId,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceResourceGroupName,
        [string]$ExplicitDeploymentResourceGroupName,
        [Parameter(Mandatory = $true)][string]$TargetLogicAppName
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitDeploymentResourceGroupName)) {
        $explicitGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$explicitGroups.Add($ExplicitDeploymentResourceGroupName)
        [void]$explicitGroups.Add($ResolvedWorkspaceResourceGroupName)
        return @($explicitGroups)
    }

    $candidateLogicApps = @(Invoke-AzJson -Arguments @(
            'resource', 'list',
            '--resource-type', 'Microsoft.Logic/workflows',
            '--query', "[?name=='$TargetLogicAppName'].id",
            '-o', 'json'
        ))

    $deploymentResourceGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($logicAppId in $candidateLogicApps) {
        if ([string]::IsNullOrWhiteSpace($logicAppId)) {
            continue
        }

        $logicAppWorkspaceName = (& az resource show --ids $logicAppId --query "properties.parameters.workspaceName.value" -o tsv 2>$null)
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $logicAppWorkspaceSub = (& az resource show --ids $logicAppId --query "properties.parameters.subscriptionId.value" -o tsv 2>$null)
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $logicAppWorkspaceRg = (& az resource show --ids $logicAppId --query "properties.parameters.resourceGroupName.value" -o tsv 2>$null)
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        if ($logicAppWorkspaceName -eq $ResolvedWorkspaceName -and
            $logicAppWorkspaceSub -eq $ResolvedWorkspaceSubscriptionId -and
            $logicAppWorkspaceRg -eq $ResolvedWorkspaceResourceGroupName) {
            $parsedLogicApp = Parse-ResourceId -ResourceId $logicAppId
            [void]$deploymentResourceGroups.Add($parsedLogicApp.ResourceGroupName)
        }
    }

    if ($deploymentResourceGroups.Count -eq 0) {
        [void]$deploymentResourceGroups.Add($ResolvedWorkspaceResourceGroupName)
    }

    return @($deploymentResourceGroups)
}

function Remove-RoleAssignmentsByIds {
    param([string[]]$AssignmentIds)

    $ids = @($AssignmentIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique)

    if ($ids.Count -eq 0) {
        return
    }

    # Batch deletes to reduce Azure CLI process startup overhead on larger cleanups.
    $chunkSize = 20
    for ($i = 0; $i -lt $ids.Count; $i += $chunkSize) {
        $end = [Math]::Min($i + $chunkSize - 1, $ids.Count - 1)
        $chunk = @($ids[$i..$end])
        $target = if ($chunk.Count -eq 1) { $chunk[0] } else { "$($chunk.Count) role assignments" }

        if ($Force -or $PSCmdlet.ShouldProcess($target, 'Delete role assignment(s)')) {
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            Write-Host "Deleting role assignment chunk ($($chunk.Count))..."
            $bulkOutput = & az role assignment delete --ids @chunk -o none 2>&1
            $exitCode = $LASTEXITCODE
            $timer.Stop()

            if ($exitCode -eq 0) {
                if ($chunk.Count -eq 1) {
                    Write-Host "Deleted role assignment: $($chunk[0]) in $([Math]::Round($timer.Elapsed.TotalSeconds, 1))s"
                } else {
                    Write-Host "Deleted role assignments: $($chunk.Count) in $([Math]::Round($timer.Elapsed.TotalSeconds, 1))s"
                }
                continue
            }

            $bulkDetails = ($bulkOutput | Out-String).Trim()
            if ($bulkDetails -match 'InteractionRequired|Timeout waiting for token|token expired|AADSTS|claims challenge') {
                Write-Warning "Role-assignment deletion failed due to authentication issue. Run 'az login' to re-authenticate, then retry."
                Write-Warning "Alternatively, use -SkipSentinelContributorCleanup to bypass this step."
                return
            }

            # Fall back to per-item deletion so one failing assignment does not hide which ID failed.
            Write-Warning "Bulk role-assignment deletion failed; retrying one-by-one for diagnostics."
            foreach ($id in $chunk) {
                $singleTimer = [System.Diagnostics.Stopwatch]::StartNew()
                Write-Host "Deleting role assignment: $id"
                $singleOutput = & az role assignment delete --ids $id -o none 2>&1
                $singleExitCode = $LASTEXITCODE
                $singleTimer.Stop()
                if ($singleExitCode -ne 0) {
                    $singleDetails = ($singleOutput | Out-String).Trim()
                    if ($singleDetails -match 'InteractionRequired|Timeout waiting for token|token expired|AADSTS|claims challenge') {
                        Write-Warning "Role-assignment deletion failed due to authentication issue. Run 'az login' to re-authenticate, then retry."
                        Write-Warning "Alternatively, use -SkipSentinelContributorCleanup to bypass this step."
                        return
                    }
                    throw "Failed to delete role assignment: $id"
                }
                Write-Host "Deleted role assignment: $id in $([Math]::Round($singleTimer.Elapsed.TotalSeconds, 1))s"
            }
        }
    }
}

function Remove-ResourceById {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return
    }

    # Skip the slow az-resource-show existence check — resources were already
    # discovered via Resource Graph, so we trust the list.  If the resource
    # was deleted between discovery and now, --no-wait will simply return a
    # 404 which we handle below.

    if ($Force -or $PSCmdlet.ShouldProcess($ResourceId, 'Delete Azure resource')) {
        Write-Host "Deleting resource (async): $ResourceId"
        $deleteOutput = & az resource delete --ids $ResourceId --no-wait -o none 2>&1
        if ($LASTEXITCODE -ne 0) {
            $details = ($deleteOutput | Out-String).Trim()
            if ($details -match 'InteractionRequired|Timeout waiting for token|token expired|AADSTS|claims challenge') {
                Write-Warning "Resource deletion failed due to authentication issue: $ResourceId"
                Write-Warning "Run 'az login' to re-authenticate, then retry."
                return
            }
            # Treat not-found and any other non-auth error as non-fatal — the
            # resource may already be gone or the provider may return an
            # unexpected error shape.  Log details so the user can investigate.
            Write-Warning "Could not delete resource (continuing): $ResourceId"
            if ($details) { Write-Verbose "Delete error details: $details" }
            return
        }
        Write-Host "Delete queued: $ResourceId"
    }
}

function Try-DeleteServicePrincipal {
    param([string]$PrincipalId)

    if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
        return
    }

    if ($script:SkipServicePrincipalDeletionDueToPermissions) {
        return
    }

    $spExists = & az ad sp show --id $PrincipalId --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($spExists)) {
        return
    }

    if ($Force -or $PSCmdlet.ShouldProcess($PrincipalId, 'Delete Entra service principal')) {
        Write-Host "Deleting service principal: $PrincipalId"
        $deleteOutput = & az ad sp delete --id $PrincipalId -o none 2>&1
        if ($LASTEXITCODE -ne 0) {
            $details = ($deleteOutput | Out-String).Trim()
            if ($details -match 'Insufficient privileges to complete the operation') {
                $script:SkipServicePrincipalDeletionDueToPermissions = $true
                Write-Warning "Insufficient Entra privileges to delete service principals. Skipping remaining principal deletions."
                return
            }

            if ([string]::IsNullOrWhiteSpace($details)) {
                Write-Warning "Could not delete service principal $PrincipalId. Check Entra permissions."
            } else {
                Write-Warning "Could not delete service principal $PrincipalId. $details"
            }
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

Write-Host "Starting Reset-OnboardingAssistantDeployment..." -ForegroundColor Cyan
Write-Verbose "Parameters: WorkspaceName='$WorkspaceName' WorkspaceResourceId='$WorkspaceResourceId' ResourceGroupName='$ResourceGroupName' DeploymentResourceGroupName='$DeploymentResourceGroupName'"
Write-Verbose "Resolving workspace..."

$resolvedWorkspaceId = Resolve-WorkspaceResourceId -ExplicitWorkspaceResourceId $WorkspaceResourceId -ExplicitWorkspaceName $WorkspaceName -ExplicitResourceGroupName $ResourceGroupName
$parsed = Parse-ResourceId -ResourceId $resolvedWorkspaceId
$resolvedSubscriptionId = $parsed.SubscriptionId
$resolvedResourceGroupName = $parsed.ResourceGroupName
$resolvedWorkspaceName = Get-WorkspaceNameFromResourceId -WorkspaceResourceId $resolvedWorkspaceId

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

$deploymentResourceGroups = Resolve-DeploymentResourceGroups `
    -ResolvedWorkspaceId $resolvedWorkspaceId `
    -ResolvedWorkspaceName $resolvedWorkspaceName `
    -ResolvedWorkspaceSubscriptionId $resolvedSubscriptionId `
    -ResolvedWorkspaceResourceGroupName $resolvedResourceGroupName `
    -ExplicitDeploymentResourceGroupName $DeploymentResourceGroupName `
    -TargetLogicAppName $LogicAppName

Write-Host "Deployment resource groups scanned: $($deploymentResourceGroups -join ', ')"

$logicAppIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$functionAppIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$planIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$appInsightsIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$storageIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($rg in $deploymentResourceGroups) {
    $rgLogicApps = @(Invoke-AzJson -Arguments @(
            'resource', 'list',
            '-g', $rg,
            '--resource-type', 'Microsoft.Logic/workflows',
            '--query', "[?name=='$LogicAppName'].id",
            '-o', 'json'
        ))
    foreach ($id in $rgLogicApps) { if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$logicAppIds.Add($id) } }

    $rgFunctionApps = @(Invoke-AzJson -Arguments @(
            'resource', 'list',
            '-g', $rg,
            '--resource-type', 'Microsoft.Web/sites',
            '--query', "[?contains(kind, 'functionapp') && starts_with(name, 'func-wl-parser-')].id",
            '-o', 'json'
        ))
    foreach ($id in $rgFunctionApps) { if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$functionAppIds.Add($id) } }

    $rgPlans = @(Invoke-AzJson -Arguments @(
            'resource', 'list',
            '-g', $rg,
            '--resource-type', 'Microsoft.Web/serverfarms',
            '--query', "[?starts_with(name, 'plan-wl-parser-')].id",
            '-o', 'json'
        ))
    foreach ($id in $rgPlans) { if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$planIds.Add($id) } }

    $rgAppInsights = @(Invoke-AzJson -Arguments @(
            'resource', 'list',
            '-g', $rg,
            '--resource-type', 'Microsoft.Insights/components',
            '--query', "[?starts_with(name, 'ai-wl-parser-')].id",
            '-o', 'json'
        ))
    foreach ($id in $rgAppInsights) { if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$appInsightsIds.Add($id) } }

    $rgStorage = @(Invoke-AzJson -Arguments @(
            'resource', 'list',
            '-g', $rg,
            '--resource-type', 'Microsoft.Storage/storageAccounts',
            '--query', "[?starts_with(name, 'stwlparser')].id",
            '-o', 'json'
        ))
    foreach ($id in $rgStorage) { if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$storageIds.Add($id) } }
}

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
foreach ($id in @(@($logicAppIds) + @($functionAppIds))) {
    $resolvedPrincipalId = (& az resource show --ids $id --query identity.principalId -o tsv 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolvedPrincipalId)) {
        [void]$principalIds.Add($resolvedPrincipalId.Trim())
    }
}

Write-Host "Discovered resources for cleanup:"
Write-Host " - Logic Apps: $(@($logicAppIds).Count)"
Write-Host " - Function Apps: $(@($functionAppIds).Count)"
Write-Host " - App Service Plans: $(@($planIds).Count)"
Write-Host " - Application Insights: $(@($appInsightsIds).Count)"
Write-Host " - Storage Accounts: $(@($storageIds).Count)"
Write-Host " - Workbooks: $($workbookIds.Count)"
Write-Host " - Watchlists to check: $($watchlistIds.Count)"
Write-Host " - Managed identity principals discovered: $($principalIds.Count)"

if (-not $SkipSentinelContributorCleanup) {
    try {
        $sentinelAssignments = @(Invoke-AzJson -Arguments @(
                'role', 'assignment', 'list',
                '--scope', $resolvedWorkspaceId,
                '--query', "[?roleDefinitionName=='Microsoft Sentinel Contributor'].id",
                '-o', 'json'
            ))

        Write-Host " - Sentinel Contributor assignments to delete: $($sentinelAssignments.Count)"
        Remove-RoleAssignmentsByIds -AssignmentIds $sentinelAssignments
    } catch {
        if ($_.Exception.Message -match 'Timeout waiting for token|token expired|AADSTS') {
            Write-Warning "Skipping role-assignment cleanup: Azure CLI token expired. Run 'az login' to re-authenticate, then retry."
            Write-Warning "Alternatively, use -SkipSentinelContributorCleanup to bypass this step."
        } else {
            throw
        }
    }
}

foreach ($id in $watchlistIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in $workbookIds) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in @($logicAppIds)) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in @($functionAppIds)) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in @($planIds)) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in @($appInsightsIds)) {
    Remove-ResourceById -ResourceId $id
}

foreach ($id in @($storageIds)) {
    Remove-ResourceById -ResourceId $id
}

if ($DeleteResourceGroup) {
    $resourceGroupToDelete = if (-not [string]::IsNullOrWhiteSpace($DeploymentResourceGroupName)) { $DeploymentResourceGroupName } else { $resolvedResourceGroupName }
    if ($Force -or $PSCmdlet.ShouldProcess($resourceGroupToDelete, 'Delete entire resource group')) {
        Write-Host "Triggering resource group deletion: $resourceGroupToDelete"
        & az group delete --name $resourceGroupToDelete --yes --no-wait | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete resource group: $resourceGroupToDelete"
        }
        Write-Host "Triggered resource group deletion: $resourceGroupToDelete"
    }
}

if (-not $SkipPrincipalDeletion) {
    foreach ($principalId in $principalIds) {
        Try-DeleteServicePrincipal -PrincipalId $principalId
    }
}

Write-Host ''
Write-Host 'Reset flow completed. Resource deletions are async — verify in the Azure portal.' -ForegroundColor Green
Write-Host 'Tip: run with -WhatIf first to preview destructive operations.' -ForegroundColor Cyan
