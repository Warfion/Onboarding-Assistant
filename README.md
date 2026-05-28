# Sentinel Data Source Onboarding Assistant

Deploy Microsoft Sentinel onboarding assets with a workbook-driven discovery experience, a watchlist refresh pipeline, and operational visibility for installed connectors.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FWarfion%2FOnboarding-Assistant%2Fmain%2Finfra%2Fmain.json)

## Overview

The Sentinel Data Source Onboarding Assistant helps SOC teams answer three practical questions:

1. Which Microsoft Sentinel connectors are available for a given domain or use case?
2. What is the best alternative ingestion path when no built-in connector exists?
3. How healthy and complete is the current connector deployment in the workspace?

The solution is organized around three workbook tabs:

- Tab 1: Search and explore available connectors from the refreshed catalog watchlist.
- Tab 2: Walk through a decision tree for alternative ingestion methods.
- Tab 3: Review installed connector health, freshness, maturity, and coverage gaps.

Under the hood, a Logic App calls an Azure Function that parses the connector source catalog, emits a 12-column CSV payload, and updates Sentinel watchlists atomically.

## Screenshots

Add the final screenshots here once the workbook UX is frozen.

### Tab 1: Available Connectors

TODO: Insert workbook screenshot for the search and connector details experience.

### Tab 2: Alternative Ingestion Decision Tree

TODO: Insert workbook screenshot for the guided decision flow and recommendation output.

### Tab 3: Installed Connectors and Coverage

TODO: Insert workbook screenshot for health cards, coverage drilldown, and recommendations.

## Prerequisites

Before deployment, make sure you have:

- An existing Log Analytics workspace with Microsoft Sentinel enabled.
- Permission to deploy Azure resources in the target resource group.
- Permission to assign RBAC on the Sentinel workspace.
- Network and policy allowance for a Logic App and a PowerShell-based Azure Function.
- Optional: a Teams or webhook endpoint for failure notifications.

## Architecture

The solution has four runtime planes:

- Workbook plane: interactive UI and KQL in the workbook.
- Data plane: `Con` and `Con_Meta` watchlists plus `SentinelHealth` telemetry.
- Automation plane: Logic App orchestration and Azure Function parsing pipeline.
- Source plane: upstream connector catalog and markdown details.

See the full architecture write-up in [doc/architecture.md](doc/architecture.md) and keep the decision flow aligned with [doc/decision-tree.drawio](doc/decision-tree.drawio).

## Deploy to Azure

The button above deploys the Azure infrastructure from [infra/main.bicep](infra/main.bicep) via the checked-in ARM template at [infra/main.json](infra/main.json).

### Parameters exposed

- `workspaceName`: Existing Log Analytics workspace name with Sentinel enabled.
- `location`: Azure region for the deployed resources.
- `uniqueSuffix`: Optional unique naming suffix derived from the resource group by default.
- `alertWebhookUrl`: Optional webhook endpoint for failure notifications.
- `functionPackageUri`: Public zip URL used by Function App `WEBSITE_RUN_FROM_PACKAGE`.
- `deployWorkbook`: Set to `true` to deploy the workbook resource automatically.

### Resources deployed

- Function App for the `ParseConnectors` workload
- Storage account for the Function runtime
- Consumption hosting plan
- Application Insights instance
- Logic App workflow for scheduled refresh
- System-assigned managed identity for the Logic App and Function App
- Sentinel Contributor role assignment for the Logic App on the target workspace
- `Con_Meta` watchlist for refresh tracking
- Function App package mount via `WEBSITE_RUN_FROM_PACKAGE` from `infra/function-package.zip`
- Shared workbook resource from [Onboarding Assistant.workbook](Onboarding%20Assistant.workbook)

## Deployment Steps

1. Select the Deploy to Azure button.
2. Choose the subscription, resource group, and deployment location.
3. Enter the Sentinel workspace name and optional alert webhook URL.
4. Review the role assignment impact and start the deployment.
5. Wait for the infrastructure deployment to complete.

## Post-Deployment Configuration

After the ARM deployment completes, run these validation steps:

1. Verify that the Logic App can invoke the Function App successfully.
2. Confirm the workbook was created and opens in Microsoft Sentinel Workbooks.
3. Run the Logic App once to populate or refresh the connector watchlists.
4. Confirm that `Con_Meta` reflects a successful refresh and that the workbook renders expected results.

## Configuration

### Watchlist Refresh

- The Logic App is the orchestration layer for weekly and on-demand refresh.
- The Azure Function returns `{ csv, stats }`, which is used to replace watchlist content atomically.
- Failure notifications can be sent through the optional webhook parameter.

### Domain Mapping

- Domain and subdomain mapping is maintained in [func-watchlist-parser/ParseConnectors/domain-map.json](func-watchlist-parser/ParseConnectors/domain-map.json).
- Do not hardcode domain lookups in the parser.
- Update mappings when connector taxonomy changes upstream.

## Repository Layout

The current repository layout is:

```text
.
|-- README.md
|-- Onboarding Assistant.workbook
|-- doc/
|   |-- architecture.md
|   |-- decision-tree.drawio
|   |-- docu.md
|   `-- kanban.md
|-- func-watchlist-parser/
|   |-- host.json
|   |-- local.settings.json
|   |-- profile.ps1
|   |-- requirements.psd1
|   |-- ParseConnectors/
|   |   |-- domain-map.json
|   |   |-- function.json
|   |   `-- run.ps1
|   `-- Tests/
|       `-- ParseConnectors.Tests.ps1
`-- infra/
    |-- function-package.zip
    |-- logic-app-definition.json
    |-- main.bicep
    `-- main.json
```

## Contributing

Contributions should preserve the current contracts and conventions:

- Keep the parser output contract as `{ csv, stats }`.
- Preserve the 12-column CSV schema expected by the watchlist flow.
- Keep domain mapping externalized in `domain-map.json`.
- Update tests in [func-watchlist-parser/Tests/ParseConnectors.Tests.ps1](func-watchlist-parser/Tests/ParseConnectors.Tests.ps1) when parser behavior changes.
- Sync documentation in `doc/` when architecture, workflow, or deployment behavior changes.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
