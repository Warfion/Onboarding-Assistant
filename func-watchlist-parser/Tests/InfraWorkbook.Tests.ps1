BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

    $script:mainBicepPath = Join-Path $repoRoot 'infra/main.bicep'
    $script:logicAppDefinitionPath = Join-Path $repoRoot 'infra/logic-app-definition.json'
    $script:workbookPath = Join-Path $repoRoot 'Onboarding Assistant.workbook'

    $script:mainBicepRaw = Get-Content -Path $script:mainBicepPath -Raw
    $script:logicAppDefinition = Get-Content -Path $script:logicAppDefinitionPath -Raw | ConvertFrom-Json
    $script:workbookRaw = Get-Content -Path $script:workbookPath -Raw
    $script:workbook = $script:workbookRaw | ConvertFrom-Json
}

Describe 'Con_Meta seed metadata in Bicep' {
    It 'Includes LogicAppResourceId in the seeded Con_Meta CSV header' {
        $script:mainBicepRaw | Should -Match 'RunId,Timestamp,Result,SourceVersion,ActiveCount,DeprecatedCount,TotalCount,FailureStage,ErrorSummary,LogicAppResourceId'
    }

    It 'Seeds the initial LogicAppResourceId value from logicApp.id' {
        $script:mainBicepRaw | Should -Match 'initial,2026-01-01T00:00:00Z,Pending,,0,0,0,,,\$\{logicApp\.id\}'
    }
}

Describe 'Con_Meta updates in Logic App definition' {
    It 'Defines logicAppName as an input parameter' {
        $script:logicAppDefinition.parameters.PSObject.Properties.Name | Should -Contain 'logicAppName'
    }

    It 'Writes LogicAppResourceId on success updates' {
        $successRawContent = $script:logicAppDefinition.actions.Update_Meta_Success.inputs.body.properties.rawContent
        $successRawContent | Should -Match 'LogicAppResourceId'
        $successRawContent | Should -Match "parameters\('logicAppName'\)"
        $successRawContent | Should -Match "concat\('/subscriptions/'"
    }

    It 'Writes LogicAppResourceId on failure updates' {
        $failureRawContent = $script:logicAppDefinition.actions.Update_Meta_Failure.inputs.body.properties.rawContent
        $failureRawContent | Should -Match 'LogicAppResourceId'
        $failureRawContent | Should -Match "parameters\('logicAppName'\)"
        $failureRawContent | Should -Match "concat\('/subscriptions/'"
    }
}

Describe 'Workbook metadata-driven refresh wiring' {
    It 'Contains hidden parameters for metadata target resolution' {
        $globalParams = ($script:workbook.items | Where-Object { $_.name -eq 'params-Global' } | Select-Object -First 1).content.parameters
        $parameterNames = $globalParams | ForEach-Object { $_.name }

        $parameterNames | Should -Contain 'RefreshWorkflowIdFromMeta'
        $parameterNames | Should -Contain 'RefreshWorkflowResourceId'
    }

    It 'Uses RefreshWorkflowResourceId in the main refresh action path' {
        $script:workbookRaw | Should -Match '"name":\s*"link-RefreshCatalog"'
        $script:workbookRaw | Should -Match '"path":\s*"\{RefreshWorkflowResourceId\}/triggers/Recurrence/run\?api-version=2016-06-01"'
    }

    It 'Does not contain removed alternative refresh controls' {
        $script:workbookRaw | Should -Not -Match '"name":\s*"text-RefreshBehaviorNote"'
        $script:workbookRaw | Should -Not -Match '"name":\s*"param-RefreshWorkflowOverride"'
        $script:workbookRaw | Should -Not -Match '"name":\s*"link-RefreshCatalogAlternative"'
    }
}