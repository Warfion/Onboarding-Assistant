targetScope = 'resourceGroup'

@description('Name of the Log Analytics workspace with Sentinel')
param workspaceName string

@description('Principal ID of the Logic App managed identity')
param logicAppPrincipalId string

@description('Resource ID of the Logic App workflow')
param logicAppResourceId string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// --- RBAC: Logic App MI → Microsoft Sentinel Contributor on workspace ---
// Role ID: ab8e14d6-4a74-4a29-9ba8-549422addade (Microsoft Sentinel Contributor)
resource sentinelContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, logicAppResourceId, 'ab8e14d6-4a74-4a29-9ba8-549422addade', 'v2')
  scope: workspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ab8e14d6-4a74-4a29-9ba8-549422addade')
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// --- Con_Meta watchlist (refresh status tracking) ---
resource conMetaWatchlist 'Microsoft.SecurityInsights/watchlists@2024-03-01' = {
  name: 'Con_Meta'
  scope: workspace
  properties: {
    displayName: 'Connector Catalog Metadata'
    description: 'Tracks refresh status of the Con watchlist (1 row, upserted each run)'
    provider: 'Onboarding Assistant'
    source: 'watchlist'
    itemsSearchKey: 'RunId'
    contentType: 'Text/Csv'
    rawContent: 'RunId,Timestamp,Result,SourceVersion,ActiveCount,DeprecatedCount,TotalCount,FailureStage,ErrorSummary,LogicAppResourceId\ninitial,2026-01-01T00:00:00Z,Pending,,0,0,0,,,${logicAppResourceId}'
  }
}
