# Sentinel Data Source Onboarding Assistant — Documentation

Version: 2.0
Last Updated: 2026-05-28
Workbook File: Onboarding Assistant.workbook

---

## 1. Purpose

The Sentinel Data Source Onboarding Assistant is an Azure Workbook that helps SOC analysts and engineers:

- Discover available Microsoft Sentinel data connectors
- Choose an onboarding method when no built-in connector exists
- Assess deployment maturity, health, freshness, and coverage gaps for installed connectors

The workbook has three tabs:

- Available Data Connectors
- Alternative Ingestion Methods
- Installed Connectors and Coverage

---

## 2. Architecture Overview

| Component | Type | Details |
|---|---|---|
| Workbook Format | Notebook/1.0 | Sentinel user workbook JSON definition |
| Connector Catalog | Sentinel Watchlist Con | Connector metadata used by Tab 1 and Tab 3 coverage analysis |
| Catalog Metadata | Sentinel Watchlist Con_Meta | Last refresh status and counts for Tab 1 status card |
| Health Source | SentinelHealth table | Last 7 days connector status/freshness telemetry |
| Catalog Origin | oshezaf/sentinelninja | Parsed from GitHub content by Azure Function |
| Automation | Logic App + Azure Function | Weekly refresh with atomic watchlist update |
| Fallback Resource | Log Analytics Workspace | log-sentinel-001 in rg-sentinel-001 |

---

## 3. Global Parameters

| Parameter | Type | Description |
|---|---|---|
| DefaultSubscription_Internal | Hidden | Auto-detects subscription containing a Log Analytics workspace |
| InternalWSs | Hidden | Resolves default workspace from SecurityIncident URL parsing |
| Subscription | Dropdown | Subscription picker using display names |
| Workspace | Resource Picker | Workspace picker scoped to SecurityInsights-enabled workspaces |
| WorkspaceID | Hidden | Workspace customerId lookup for selected workspace |
| WorkspaceSubscriptionId | Hidden | Resolved subscription ID for the selected workspace |
| WorkspaceResourceGroup | Hidden | Resolved resource group for the selected workspace |
| Help | Toggle | Shows and hides explanatory info panels |
| Tab | Hidden, Global | 1 = Available Data Connectors, 2 = Alternative Ingestion Methods, 3 = Installed Connectors and Coverage |
| SelectedConnector | Dropdown value | Connector chosen in Tab 1 |
| RefreshWorkflowOverride | Resource Picker | Optional Logic App workflow override for cross-resource-group manual refresh |
| SelectedSubdomain | Exported value | Subdomain selected from Tab 3 coverage table |
| StatusFilter | Dropdown | Tab 3 detail filter: All, Installed, Not installed |

---

## 4. Tab Structure

### 4.1 Tab 1 — Available Data Connectors

Purpose: Search and inspect connectors in watchlist Con.

Main behaviors:

- Dropdown connector selection writes directly to SelectedConnector
- Single-row details table and description card are filtered by exact connector name
- Copilot nudge appears only when a connector is selected
- Catalog refresh status card reads Con_Meta
- Default refresh button triggers Logic App recurrence endpoint via ARM action using workspace-derived subscription and resource group parameters
- Alternate refresh button supports explicit cross-resource-group target selection using a workflow override picker
- Publisher and method pie charts summarize active catalog state
- Full grid supports a status-based filter (All, First Party, Third Party, Deprecated)

### 4.2 Tab 2 — Alternative Ingestion Methods

Purpose: Guide users to the correct onboarding path with a cascading decision flow.

Decision flow:

- 1) Listed in Sentinel Content Hub?
- 2) Built-in connector available? (only if Q1 = Yes)
- 3) REST API available? (evaluation path)
- 4a) CCF suitable? (if Q3 = Yes)
- 4b) Preprocessing needed? (if Q3 = No)
- 4c) Arc-enabled Kubernetes available? (if Q4b = Yes)
- 5) Supports CEF? (if Q4b = No)
- 6) Supports Syslog? (if Q5 = No)
- 7) Exports files? (if Q6 = No)
- 8) Supports webhooks? (if Q7 = No)

Outcome panels:

- Use Built-in Connector
- Codeless Connector Framework (CCF)
- Logs Ingestion API
- Azure Monitor Pipeline
- Logstash with Sentinel Output Plugin
- CEF via AMA
- Syslog via AMA
- Custom Logs v2 via AMA
- Webhook to Function or Logic App to Logs Ingestion API
- Ad-hoc upload via Logs Ingestion API (last resort)

UX features:

- Decision Summary table with live answers and hybrid numbering (4a/4b/4c)
- Recommendation badges that appear as soon as a terminal path is reached
- Contextual helper text beneath each question
- Full ancestor-chain visibility on result and badge elements to avoid stale panels

### 4.3 Tab 3 — Installed Connectors and Coverage

Purpose: Assess deployment maturity and operational quality.

Major elements:

- Deployment Maturity cards
  - Installed connectors (7d)
  - Maturity tier (Initial, Early, Productive, Mature SOC, Enterprise)
  - Domains covered (X / 11)
- Health Summary pie chart
- Data Freshness pie chart
- Recommendations table
  - Coverage Gap
  - Minimal Coverage
  - Connector Failure
  - Connector Warning
  - Stale Data
- Collapsible Connector Health Details group
  - Connector Health Status table
  - Recent Failures and Warnings table
- Security Coverage by Domain and Subdomain table
  - Click row exports SelectedSubdomain
- Domain detail table filtered by StatusFilter
- Help-gated legends for maturity tiers, recommendations, domain taxonomy, and heatmap

Data semantics:

- Coverage analysis joins SentinelHealth connector names to Con Connector ID using normalized key expansion
- Domain and Subdomain fields support multi-value splits for aggregation and drilldown

---

## 5. Watchlist Schema

The parser and workbook contract uses the following 12 columns:

| Column |
|---|
| Connector Name |
| Connector Description |
| Vendor |
| Method |
| Table Count |
| Solution |
| Status |
| Flags |
| Source Version |
| Domain |
| Subdomain |
| Connector ID |

Notes:

- Domain and Subdomain can contain comma-separated values
- Connector ID is used for deterministic matching in coverage queries
- Watchlist updates are atomic PUT operations (fail-closed behavior)

---

## 6. Integrations

| Integration | Usage |
|---|---|
| Azure Resource Graph | Subscription and workspace discovery |
| Microsoft Sentinel Watchlists | Catalog and metadata storage (Con, Con_Meta) |
| SentinelHealth | Connector health/freshness telemetry |
| Copilot in Azure | On-demand connector research prompt |
| Content Hub Blade | Deep link for built-in connector onboarding |
| Microsoft Learn | Guidance links in tab help and outcome panels |
| Logic App | Scheduled catalog refresh orchestration |
| Azure Function ParseConnectors | Parses sentinelninja markdown into CSV contract |

---

## 7. Element Naming Convention

Workbook elements follow prefix-purpose naming:

- text-
- param- and params-
- query-
- link- and links-
- group-

This keeps workbook JSON maintainable and traceable during future edits.

---

## 8. Current Status

| Area | Status |
|---|---|
| Tab 1 search and details flow | Complete |
| Tab 2 decision tree and guidance panels | Complete |
| Tab 2 visibility chain hardening | Complete |
| Tab 3 maturity and recommendations model | Complete |
| Tab 3 domain-subdomain drilldown | Complete |
| Tab 1 refresh targeting and override flow | Complete |
| Tab 1 catalog status rendering from latest Con_Meta row | Complete |
| Watchlist refresh automation | Complete |
| Parser robustness (nested brackets and escaped pipes) | Complete |
| Function test suite | 33 passing |
| Public GitHub packaging and one-click deploy documentation | Planned |

---

## 9. Known Gaps

| Gap | Impact | Tracking |
|---|---|---|
| Public GitHub packaging and one-click deploy documentation is not finalized | Slows reproducible onboarding for external teams | Kanban item #7 |

---

## 10. File Inventory

Current workspace files:

| File | Purpose |
|---|---|
| LICENSE | Project license |
| Onboarding Assistant.workbook | Workbook definition |
| README.md | Project overview and deployment guidance |
| .github/copilot-instructions.md | Project coding and sync rules |
| .github/skills/sync-docs/SKILL.md | Documentation sync workflow |
| .github/workflows/verify-bicep-artifact-sync.yml | CI check for Bicep/ARM artifact sync |
| .vscode/extensions.json | Recommended extensions |
| .vscode/launch.json | Debug configuration |
| .vscode/mcp.json | MCP configuration |
| .vscode/settings.json | Workspace settings |
| .vscode/tasks.json | Task definitions |
| doc/architecture.md | Architecture and flow documentation |
| doc/decision-tree.drawio | Visual decision tree diagram |
| doc/docu.md | Documentation reference |
| doc/kanban.md | Project board |
| func-watchlist-parser/host.json | Function host settings |
| func-watchlist-parser/local.settings.json | Local function settings |
| func-watchlist-parser/profile.ps1 | Function startup profile |
| func-watchlist-parser/requirements.psd1 | PowerShell dependencies |
| func-watchlist-parser/ParseConnectors/domain-map.json | Domain and subdomain mapping rules |
| func-watchlist-parser/ParseConnectors/function.json | Function trigger bindings |
| func-watchlist-parser/ParseConnectors/run.ps1 | Parser implementation |
| func-watchlist-parser/Tests/ParseConnectors.Tests.ps1 | Parser test suite |
| infra/function-package.zip | Function package artifact used by WEBSITE_RUN_FROM_PACKAGE |
| infra/logic-app-definition.json | Logic App workflow definition |
| infra/main.bicep | Infrastructure as code source |
| infra/main.json | Compiled ARM template |
