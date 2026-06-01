// ============================================================
// Sentinel Onboarding Assistant — Infrastructure
// Deploys: Function App + Logic App + RBAC + Con_Meta watchlist
// ============================================================

@description('Name of the Log Analytics workspace with Sentinel')
param workspaceName string

@description('Subscription that contains the Log Analytics workspace')
param workspaceSubscriptionId string = subscription().subscriptionId

@description('Resource group that contains the Log Analytics workspace')
param workspaceResourceGroupName string = resourceGroup().name

@description('Resource group location')
param location string = resourceGroup().location

@description('Unique suffix for resource names')
param uniqueSuffix string = uniqueString(resourceGroup().id)

@description('Optional Teams/webhook URL for failure alerts (leave empty to disable)')
param alertWebhookUrl string = ''

@description('Public URL of the Function App zip package used by WEBSITE_RUN_FROM_PACKAGE')
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
var refreshSharedSecret = guid(resourceGroup().id, functionAppName, 'refresh-shared-secret')

// --- Existing workspace reference ---
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
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
          value: functionPackageUri
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'REFRESH_SHARED_SECRET'
          value: refreshSharedSecret
        }
      ]
    }
  }
}

// --- Logic App (Consumption) ---
resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
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
      refreshSharedSecret: {
        value: refreshSharedSecret
      }
      subscriptionId: {
        value: workspaceSubscriptionId
      }
      resourceGroupName: {
        value: workspaceResourceGroupName
      }
      workspaceName: {
        value: workspaceName
      }
      logicAppName: {
        value: logicAppName
      }
      alertWebhookUrl: {
        value: alertWebhookUrl
      }
    }
  }
}

module workspaceResources './workspace-resources.bicep' = {
  name: 'workspaceResources'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  params: {
    workspaceName: workspaceName
    logicAppPrincipalId: logicApp.identity.principalId
    logicAppResourceId: logicApp.id
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
