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

The deployment supports workspaces in a different subscription or resource group from the deployment stack when you provide explicit workspace scope parameters.

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
- `workspaceSubscriptionId`: Subscription containing the Sentinel workspace. Required.
- `workspaceResourceGroupName`: Resource group containing the Sentinel workspace. Required.
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
- Shared workbook resource from [Onboarding Assistant.workbook](Onboarding%20Assistant.workbook), saved in the Sentinel workspace resource group so it appears in Microsoft Sentinel

## Deployment Steps

1. Select the Deploy to Azure button.
2. Choose the subscription and resource group where the stack resources will live (Function App, Logic App, Storage, etc.).
3. **Enter the Sentinel workspace details** — these are **required**:
   - `workspaceName`: The name of your existing Sentinel workspace
   - `workspaceSubscriptionId`: The subscription containing that workspace (may differ from the stack subscription)
   - `workspaceResourceGroupName`: The resource group containing that workspace (may differ from the stack resource group)
4. Enter the optional alert webhook URL.
5. Review the role assignment impact and start the deployment.
6. Wait for the infrastructure deployment to complete.

## Post-Deployment Configuration

After the ARM deployment completes, run these validation steps:

1. Verify that the Logic App can invoke the Function App successfully.
2. Confirm the workbook was created in the Sentinel workspace resource group and opens in Microsoft Sentinel Workbooks.
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

#### How parsing and categorization work

The Azure Function in [func-watchlist-parser/ParseConnectors/run.ps1](func-watchlist-parser/ParseConnectors/run.ps1) parses the upstream connector index markdown into the 12-column CSV contract:

1. A line-by-line state machine reads each connector table row (tracking the `🚫 Deprecated` section and protecting escaped pipes inside cells).
2. Each row is normalized — markdown links and emoji badges are stripped, badges become Flags, and Status/Vendor/Method/Table Count/Solution are derived.
3. The connector name is matched against the patterns in `domain-map.json` to assign Domain and Subdomain.

Domain assignment is a case-insensitive substring match: the first pattern whose text appears in the connector name wins. A connector that matches no pattern is categorized as `Domain = Other` (it is never dropped). This is also how new connectors are categorized "dynamically": a single vendor pattern (for example `CrowdStrike`) automatically covers new connectors from that vendor, while a genuinely new vendor lands in `Other` until a pattern is added.

For the full technical reference, see [doc/architecture.md](doc/architecture.md) section 6.

#### Maintaining the domain map

When new connectors appear (they surface as `Domain = Other` after a refresh) or the upstream taxonomy changes:

1. Filter the `Con` watchlist (or workbook Tab 1) for `Domain = Other` to find what needs curation.
2. Open [func-watchlist-parser/ParseConnectors/domain-map.json](func-watchlist-parser/ParseConnectors/domain-map.json) and pick the right `"Domain / Subdomain"` key (reuse an existing one where possible).
3. Add the most specific stable fragment of the connector/vendor name to that key's array. Patterns are case-insensitive substrings, so prefer a distinctive token (for example `"Cyera DSPM"`) over a generic word.
4. For connectors that belong to multiple domains, add the pattern under the `_multiDomain` block with comma-separated `"Domain / Subdomain"` pairs.
5. Avoid broad fragments (for example a bare `"Cisco"`) that could shadow connectors in other subdomains — the first matching pattern wins.
6. Run the parser tests in [func-watchlist-parser/Tests/ParseConnectors.Tests.ps1](func-watchlist-parser/Tests/ParseConnectors.Tests.ps1) and update them if behavior changes.
7. Trigger the Logic App refresh and confirm the connector now resolves to the intended Domain/Subdomain.

All domain logic stays in `domain-map.json` — never add domain conditionals to `run.ps1`.

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
    |-- workspace-resources.bicep
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
