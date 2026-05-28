// ============================================================
// Sentinel Onboarding Assistant — Infrastructure
// Deploys: Function App + Logic App + RBAC + Con_Meta watchlist
// ============================================================

@description('Name of the Log Analytics workspace with Sentinel')
param workspaceName string

@description('Resource group location')
param location string = resourceGroup().location

@description('Unique suffix for resource names')
param uniqueSuffix string = uniqueString(resourceGroup().id)

@description('Optional Teams/webhook URL for failure alerts (leave empty to disable)')
param alertWebhookUrl string = ''

@description('Public URL of the Function App zip package used by ZipDeploy')
param functionPackageUri string = 'https://raw.githubusercontent.com/Warfion/Onboarding-Assistant/main/infra/function-package.zip'

@description('Deploy the Sentinel workbook resource from the checked-in workbook JSON')
param deployWorkbook bool = true

// --- Variables ---
var functionAppName = 'func-wl-parser-${uniqueSuffix}'
var storageName = 'stwlparser${uniqueSuffix}'
var hostingPlanName = 'plan-wl-parser-${uniqueSuffix}'
var logicAppName = 'la-watchlist-refresh'
var appInsightsName = 'ai-wl-parser-${uniqueSuffix}'
var workbookName = guid(workspace.id, 'onboarding-assistant-workbook')

// --- Existing workspace reference ---
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// --- Storage Account (for Function App) ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// --- App Insights ---
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

// --- Consumption App Service Plan ---
resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: false
  }
}

// --- Function App ---
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
      ]
    }
  }
}

// Deploy function code package in one-click deployments.
resource functionZipDeploy 'Microsoft.Web/sites/extensions@2024-04-01' = {
  name: 'ZipDeploy'
  parent: functionApp
  properties: {
    packageUri: functionPackageUri
  }
}

// --- Logic App (Consumption) ---
resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  dependsOn: [
    functionZipDeploy
  ]
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('logic-app-definition.json')
    parameters: {
      functionAppHost: {
        value: functionApp.properties.defaultHostName
      }
      functionKey: {
        value: listKeys('${functionApp.id}/host/default', '2023-12-01').masterKey
      }
      subscriptionId: {
        value: subscription().subscriptionId
      }
      resourceGroupName: {
        value: resourceGroup().name
      }
      workspaceName: {
        value: workspaceName
      }
      alertWebhookUrl: {
        value: alertWebhookUrl
      }
    }
  }
}

// --- RBAC: Logic App MI → Microsoft Sentinel Contributor on workspace ---
// Role ID: ab8e14d6-4a74-4a29-9ba8-549422addade (Microsoft Sentinel Contributor)
resource sentinelContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, logicApp.id, 'ab8e14d6-4a74-4a29-9ba8-549422addade')
  scope: workspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ab8e14d6-4a74-4a29-9ba8-549422addade')
    principalId: logicApp.identity.principalId
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
    rawContent: 'RunId,Timestamp,Result,SourceVersion,ActiveCount,DeprecatedCount,TotalCount,FailureStage,ErrorSummary\ninitial,2026-01-01T00:00:00Z,Pending,,0,0,0,,'
  }
}

resource onboardingWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = if (deployWorkbook) {
  name: workbookName
  location: location
  kind: 'shared'
  properties: {
    category: 'sentinel'
    displayName: 'Sentinel Data Source Onboarding Assistant'
    description: 'Workbook for connector discovery, ingestion decision guidance, and connector health.'
    sourceId: workspace.id
    version: 'Notebook/1.0'
    serializedData: loadTextContent('../Onboarding Assistant.workbook')
  }
}

// --- Outputs ---
output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output logicAppName string = logicApp.name
output logicAppPrincipalId string = logicApp.identity.principalId
output workbookResourceId string = deployWorkbook ? onboardingWorkbook.id : ''
