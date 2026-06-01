BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:ResetScriptPath = Join-Path $repoRoot 'scripts/Reset-OnboardingAssistantDeployment.ps1'

    function Get-MockedAzOutput {
        param([Parameter(Mandatory = $true)][string]$Command)

        switch ($global:AzScenario) {
            'Reset-WorkspaceName-Success' {
                if ($Command -match 'account list') { return '["sub-1"]' }
                if ($Command -match 'resource list --subscription sub-1 --resource-type Microsoft\.OperationalInsights/workspaces') {
                    return '["/subscriptions/sub-1/resourceGroups/rg-sentinel-001/providers/Microsoft.OperationalInsights/workspaces/log-sentinel-001"]'
                }
                if ($Command -match 'account set --subscription sub-1') { return '' }
                if ($Command -match 'resource list -g rg-sentinel-001 --resource-type Microsoft\.Logic/workflows') { return '[]' }
                if ($Command -match 'resource list -g rg-sentinel-001 --resource-type Microsoft\.Web/sites') { return '[]' }
                if ($Command -match 'resource list -g rg-sentinel-001 --resource-type Microsoft\.Web/serverfarms') { return '[]' }
                if ($Command -match 'resource list -g rg-sentinel-001 --resource-type Microsoft\.Insights/components') { return '[]' }
                if ($Command -match 'resource list -g rg-sentinel-001 --resource-type Microsoft\.Storage/storageAccounts') { return '[]' }
                if ($Command -match 'resource list --resource-type Microsoft\.Insights/workbooks') { return '[]' }
                if ($Command -match 'role assignment list --scope /subscriptions/sub-1/resourceGroups/rg-sentinel-001/providers/Microsoft\.OperationalInsights/workspaces/log-sentinel-001') {
                    return '["/subscriptions/sub-1/resourceGroups/rg-sentinel-001/providers/Microsoft.OperationalInsights/workspaces/log-sentinel-001/providers/Microsoft.Authorization/roleAssignments/ra-1"]'
                }
                if ($Command -match 'resource show --ids .*/watchlists/Con\s+--query id -o tsv') {
                    return '/subscriptions/sub-1/resourceGroups/rg-sentinel-001/providers/Microsoft.OperationalInsights/workspaces/log-sentinel-001/providers/Microsoft.SecurityInsights/watchlists/Con'
                }
                if ($Command -match 'resource show --ids .*/watchlists/Con_Meta\s+--query id -o tsv') {
                    return '/subscriptions/sub-1/resourceGroups/rg-sentinel-001/providers/Microsoft.OperationalInsights/workspaces/log-sentinel-001/providers/Microsoft.SecurityInsights/watchlists/Con_Meta'
                }
                return '[]'
            }

            'Reset-WorkspaceName-Ambiguous' {
                if ($Command -match 'account list') { return '["sub-1"]' }
                if ($Command -match 'resource list --subscription sub-1 --resource-type Microsoft\.OperationalInsights/workspaces') {
                    return '["/subscriptions/sub-1/resourceGroups/rg-a/providers/Microsoft.OperationalInsights/workspaces/shared-name","/subscriptions/sub-1/resourceGroups/rg-b/providers/Microsoft.OperationalInsights/workspaces/shared-name"]'
                }
                return '[]'
            }
            default {
                return '[]'
            }
        }
    }
}

Describe 'Reset-OnboardingAssistantDeployment script' {
    BeforeEach {
        $global:AzCalls = [System.Collections.Generic.List[string]]::new()
        Remove-Item function:global:az -ErrorAction SilentlyContinue

        function global:az {
            $cmd = ($args -join ' ')
            $global:AzCalls.Add($cmd)
            $global:LASTEXITCODE = 0
            return Get-MockedAzOutput -Command $cmd
        }
    }

    It 'resolves a workspace by -WorkspaceName and completes in WhatIf mode' {
        $global:AzScenario = 'Reset-WorkspaceName-Success'

        { & $script:ResetScriptPath -WorkspaceName 'log-sentinel-001' -WhatIf } | Should -Not -Throw
        ($global:AzCalls -join "`n") | Should -Match 'account list'
        ($global:AzCalls -join "`n") | Should -Match 'resource list --subscription sub-1 --resource-type Microsoft\.OperationalInsights/workspaces'
    }

    It 'throws an ambiguity error when -WorkspaceName matches multiple workspaces' {
        $global:AzScenario = 'Reset-WorkspaceName-Ambiguous'

        { & $script:ResetScriptPath -WorkspaceName 'shared-name' -WhatIf } | Should -Throw '*Workspace resolution is ambiguous*'
    }
}
