# Sentinel Data Source Onboarding Assistant — Project Board

## To Do

### 🔲 21 — Workbook Feedback Function for Incorrect Domain Mappings

  - tags: [workbook, domain-map, feedback, github, ux]
  - priority: low
    ```md
    Add a reporting/feedback function in the workbook so users can flag a connector whose Domain/Subdomain mapping is wrong, feeding curation of ParseConnectors/domain-map.json.

    GOAL:
    Close the loop between consumers (workbook users) and maintainers of the domain map. Today, miscategorized or `Other` connectors are only discovered by manually scanning the Con watchlist; this item lets users surface mapping issues directly from Tab 1 and file them as prefilled GitHub issues for triage.

    DEPENDS ON: #24 (Con_DomainMap watchlist) — the dependent Domain -> Subdomain dropdowns are sourced from it.

    CHOSEN ROUTING — GitHub Issues, prefilled issues/new deep link (decided 2026-06-25):
    No secrets/backend; the workbook renders a fully prefilled `issues/new` link the user submits with one click. Repo Warfion/Onboarding-Assistant is public, so any logged-in GitHub user can open the issue (the hint text notes "requires GitHub login"). The Logic-App/GitHub-API route stays a later upgrade (see #21 history / Option B below) only if abuse guardrails become necessary.

    PLACEMENT (decided):
    - Tab 1 connector detail card (group-AvailableConnectors): a feedback-process hint + a "Report incorrect mapping" link.
    - Tab 3: a feedback-process hint + a wayfinder link that sets the tab parameter Tab=1 (active cross-tab navigation; the link does NOT pre-select a connector — single-parameter limit, user re-selects on Tab 1).
    - The Tab 1 report link uses conditionalVisibility on SelectedConnector isNotEqualTo "" (only shown when a connector is selected); the Tab 3 wayfinder is always visible.

    CONTEXT CAPTURE (decided):
    - A hidden KQL query on Con for the selected connector surfaces Connector ID, Subdomain, and Source Version (not projected on the card today).

    SUGGESTED CORRECTION — two dependent dropdowns (decided):
    - Domain dropdown -> filtered Subdomain dropdown, both sourced from the canonical taxonomy via the new Con_DomainMap watchlist (#24), so only valid Domain/Subdomain pairs are selectable (no free-text typos).

    URL BUILD & ENCODING (decided):
    - Build the complete issues/new URL server-side in KQL using url_encode_component() and export it as a single parameter (e.g. FeedbackIssueUrl) bound to the LinkItem. Workbook {param} substitution does NOT URL-encode, so the encoding must happen in KQL.

    ISSUE PAYLOAD:
    - Title: "Domain mapping: <Connector Name> (<Connector ID>)"
    - Labels: domain-map, feedback (must be pre-created in the repo, else the deep link silently drops them).
    - Body: Connector Name, Connector ID, current Domain/Subdomain, Source Version, suggested Domain/Subdomain (from the dropdowns), free-text note.

    OPTION B — Fully automatic via Logic App (later upgrade, deferred):
    - Workbook ARM Action -> Logic App (HTTP request trigger) -> GitHub Issues API (POST /repos/Warfion/Onboarding-Assistant/issues).
    - Auth: GitHub App installation token (preferred) or PAT in Key Vault via Managed Identity; add abuse/rate-limit guardrails + payload validation.
    - More infra (Bicep) + maintenance; only pursue if the public deep-link route proves insufficient.

    PRE-WORK:
    - Create the `domain-map` and `feedback` labels in the GitHub repo before shipping.

    ACCEPTANCE:
    - User can open a prefilled GitHub issue for any selected connector from Tab 1; Tab 3 points users to the Tab 1 flow.
    - Suggested correction is chosen via dependent Domain/Subdomain dropdowns (valid values only).
    - Prefilled issue includes connector identity (Name + ID), current vs. suggested domain, and Source Version, correctly URL-encoded.
    - Routing + maintenance loop documented in docu.md and architecture.md (§6.4) once implemented.
    ```

### 🔲 24 — Provide Con_DomainMap Watchlist (Function + Logic App + Bicep)

  - tags: [function, logic-app, infra, watchlist, domain-map]
  - priority: low
    ```md
    Publish the canonical domain taxonomy (ParseConnectors/domain-map.json) as a Sentinel watchlist Con_DomainMap so the workbook can drive valid Domain -> Subdomain dropdowns from a single source of truth. Prerequisite for #21.

    GOAL:
    Make the domain/subdomain taxonomy queryable inside the workbook without drift. domain-map.json lives only in the Function today; surfacing it as a watchlist lets #21's dependent dropdowns offer exactly the valid Domain/Subdomain pairs (errors excluded by construction).

    WHY A WATCHLIST (not Con-distinct):
    Con-distinct only contains Domain/Subdomain pairs currently used by at least one connector, so valid-but-unused subdomains would be missing from the dropdowns. The canonical map is complete; keeping one source (domain-map.json) avoids divergence.

    SCOPE:
    - Function (ParseConnectors/run.ps1): extend the output contract from { csv, stats } to { csv, stats, domainMapCsv }. domainMapCsv = distinct Domain,Subdomain derived from the domain-map.json keys (Get-DomainMap already splits "Domain / Subdomain" on the last " / "). Key column e.g. DomainSubdomainKey.
    - Logic App (infra/logic-app-definition.json): add a second atomic PUT writing domainMapCsv to the Con_DomainMap watchlist (same fail-closed pattern as the existing Con PUT).
    - Infra (infra/workspace-resources.bicep): add the Con_DomainMap watchlist resource (search key on the Domain/Subdomain key column).
    - Tests (func-watchlist-parser/Tests/ParseConnectors.Tests.ps1): cover the new domainMapCsv field (shape, distinct pairs, header).

    ACCEPTANCE:
    - A refresh run populates Con_DomainMap with every canonical Domain/Subdomain pair from domain-map.json.
    - _GetWatchlist('Con_DomainMap') returns the taxonomy for workbook dropdowns.
    - Function output contract and new watchlist documented in docu.md + architecture.md (§6.4); file inventory in docu.md §10 updated.
    ```

## In Progress

## Done

### ✅ 23 — Export All Connectors as CSV

  - tags: [workbook, export, csv, ux]
  - priority: low
    ```md
    Delivered the one-click connector export (Option A — native grid Export to Excel) with Domain/Subdomain visible per connector.

    DELIVERED:
    ✅ Extended the Tab 1 "List of all available Connectors" grid (query-AllConnectorsGrid) to project the full export column set: Connector Name, Vendor, Method, Solution, Domain, Subdomain, Status, Source Version, Connector ID.
    ✅ Sorted by Domain, Subdomain, Connector Name so mis-bucketed / `Other` connectors cluster for QA.
    ✅ Domain and Subdomain are now visible per connector directly in the grid.
    ✅ Export = the grid's native "Export to Excel" toolbar action (.xlsx); the section header points users to it. No new grid, tab, or infra.
    ✅ Documented in architecture.md §6.4 and docu.md §4.1; doc versions bumped to 2.7.

    SCOPE NOTE:
    - Implemented as one export button on the existing grid (per user request), not a separate full-catalog section/tab.
    - The existing status filter (All/First/Third/Deprecated) still applies, so the export follows the current filter; default All exports the whole catalog.
    - True .csv via the Function output stays deferred (Option B) until demand is proven.

    INVENTORY DELTA:
    - Added: none
    - Removed: none
    ```

### ✅ 22 — Document Installed-Connector Detection and Key Normalization

  - tags: [documentation, workbook, coverage, sync-docs]
  - priority: low
    ```md
    Made Tab 3 installed-connector detection traceable by documenting the exact SentinelHealth logic.

    DELIVERED:
    ✅ Added doc/architecture.md section 5.4 with the 7-day SentinelHealth detection query, three-key normalization (exact, -suffix stripped, "connector" stripped), Con join, and maturity thresholds.
    ✅ Expanded doc/docu.md section 4.3 data semantics with the install definition, health-monitoring prerequisite, key-expansion detail, and maturity tier thresholds.
    ✅ Bumped doc versions (architecture 2.6, docu 2.6) and added a status row in docu.md.

    INVENTORY DELTA:
    - Added: none
    - Removed: none
    ```

### ✅ 20 — Sync-Docs Audit: File Inventory Alignment

  - tags: [documentation, sync-docs, audit]
  - priority: low
    ```md
    Ran a full sync-docs audit (Mode B) after the parsing/categorization documentation change and corrected file inventory drift.

    DELIVERED:
    ✅ Validated doc/docu.md §10 File Inventory against tracked workspace files (git ls-files).
    ✅ Confirmed schema consistency (docu.md §5, architecture.md §9.1, run.ps1) and that scripts/context7/* are intentionally gitignored and correctly excluded from inventory.
    ✅ Added the previously missing .gitignore entry to doc/docu.md §10.

    INVENTORY DELTA:
    - Added: .gitignore (to doc/docu.md §10 File Inventory)
    - Removed: none
    ```

### ✅ 19 — Document Parsing and Domain Categorization + Maintenance Guide

  - tags: [documentation, parser, domain-map, sync-docs]
  - priority: medium
    ```md
    Made the connector parsing logic and domain categorization traceable, and added a maintenance guide for the domain map.

    DELIVERED:
    ✅ Documented the parsing pipeline (line-by-line state machine, row normalization, badge/flag handling) in doc/architecture.md section 6.2.
    ✅ Documented data-driven domain categorization, substring matching, _multiDomain, and the Other fallback in doc/architecture.md section 6.3.
    ✅ Added a domain map maintenance guide (curation checklist + rules) in doc/architecture.md section 6.4, README.md, and doc/docu.md sections 5.1/5.2.
    ✅ Bumped doc versions (architecture 2.5, docu 2.5) and added a status row in docu.md.

    INVENTORY DELTA:
    - Added: none
    - Removed: none
    ```

### ✅ 18 — Workbook Metadata Fail-Safe and Reset Script PID Fix

  - tags: [workbook, scripts, reliability, sync-docs]
  - priority: high
    ```md
    Hardened workbook parameter behavior for not-ready workspaces and fixed reset script execution reliability.

    DELIVERED:
    ✅ Made `RefreshWorkflowIdFromMeta` query fault-tolerant when Con_Meta does not exist, preventing query-failed parameter exposure in workspace-not-ready state.
    ✅ Fixed PowerShell variable-name collision in reset script (`$pid` vs `$PID`) that caused read-only variable overwrite errors.
    ✅ Verified reset dry-run execution with `-WorkspaceName`, `-Verbose`, and `-WhatIf` after fix.
    ✅ Confirmed split-RG cleanup enumeration still works after the PID fix.

    INVENTORY DELTA:
    - Added: none
    - Removed: none
    ```

### ✅ 17 — Reset Flow Consolidation and Split-RG Cleanup Targeting

  - tags: [deployment, scripts, tests, sync-docs]
  - priority: high
    ```md
    Consolidated cleanup operations into a single reset flow and added deterministic support for split resource group deployments.

    DELIVERED:
    ✅ Removed standalone stale-assignment cleanup script and consolidated cleanup behavior into scripts/Reset-OnboardingAssistantDeployment.ps1.
    ✅ Added WorkspaceName-based workspace resolution support for reset operations.
    ✅ Added explicit DeploymentResourceGroupName targeting so stack resources can be cleaned when hosted outside the workspace resource group.
    ✅ Added/updated script-level Pester tests for reset-flow resolution, ambiguity handling, and safe dry-run behavior.
    ✅ Updated doc/docu.md and doc/architecture.md to reflect the consolidated reset model and split-RG cleanup guidance.

    INVENTORY DELTA:
    - Added: func-watchlist-parser/Tests/DeploymentScripts.Tests.ps1
    - Removed: scripts/Cleanup-StaleSentinelContributorAssignments.ps1
    ```

### ✅ 16 — Workbook Discoverability Scope Alignment

  - tags: [deployment, workbook, sync-docs]
  - priority: high
    ```md
    Aligned workbook deployment scope with Microsoft Sentinel discoverability requirements.

    DELIVERED:
    ✅ Moved workbook resource deployment into infra/workspace-resources.bicep so it is created in the Sentinel workspace resource group.
    ✅ Removed workbook deployment from infra/main.bicep stack resource group scope.
    ✅ Rebuilt infra/main.json from infra/main.bicep.
    ✅ Updated README.md, doc/docu.md, and doc/architecture.md to reflect workspace-scoped workbook placement.
    ✅ Added doc/decision-tree.drawio manual-update flag for topology parity (workbook now originates from workspace-scoped module).

    INVENTORY DELTA:
    - Added: none
    - Removed: none
    ```

### ✅ 15 — Cross-Resource-Group Workspace Deployment Support

  - tags: [deployment, infrastructure, workbook, sync-docs]
  - priority: high
    ```md
    Enabled deployments where the Sentinel workspace lives in a different subscription or resource group than the deployment stack.

    DELIVERED:
    ✅ Added required workspaceSubscriptionId and workspaceResourceGroupName deployment parameters in infra/main.bicep.✅ Scoped the existing Log Analytics workspace reference to the selected workspace subscription and resource group.
    ✅ Passed the actual workspace subscription/resource group into the Logic App refresh workflow parameters.
    ✅ Updated README.md, doc/docu.md, and doc/architecture.md to document the cross-resource-group deployment path.
    ✅ Rebuilt the deployment template so the Deploy to Azure button targets the workspace correctly.

    INVENTORY DELTA:
    - Added: infra/workspace-resources.bicep
    - Removed: none
    ```

### ✅ 7 — GitHub Repo + README with Deploy to Azure Button

  - tags: [deployment, github, documentation]
  - priority: medium
   ```md
   Published and validated the one-click deployment experience for the Sentinel Data Source Onboarding Assistant.

   DELIVERED:
   ✅ Public GitHub repo and Deploy to Azure button are live.
   ✅ README includes deployment and configuration guidance.
   ✅ ARM template in infra/main.json is generated from infra/main.bicep.
   ✅ One-click deployment includes workbook deployment and Function package mounting.
   ✅ End-to-end deployment validation succeeded (deployment + Logic App run + workbook + watchlists).

   INVENTORY DELTA:
   - Added: none
   - Removed: none
   ```

### ✅ 14 — Workspace Eligibility Guard and Tab Gating

  - tags: [workbook, guardrails, ux, sync-docs]
  - priority: high
   ```md
   Implemented strict workspace eligibility behavior for safer first-run experience.

   DELIVERED:
   ✅ Scoped workspace picker to SecurityInsights-enabled workspaces in the selected subscription.
   ✅ Added single-option auto-select behavior when exactly one eligible workspace is available.
   ✅ Added hidden WorkspaceEligible parameter to enforce Con_Meta readiness on selected workspace.
   ✅ Added blocking eligibility message when workspace readiness conditions are not met.
   ✅ Gated all three tab content groups behind WorkspaceEligible=Yes to prevent invalid execution paths.
   ✅ Updated doc/docu.md and doc/architecture.md to document eligibility and first-run initialization behavior.

   INVENTORY DELTA:
   - Added: none
   - Removed: none
   ```

### ✅ 13 — Workbook Refresh Targeting and Status Sync

  - tags: [workbook, tab1, reliability, sync-docs]
  - priority: high
   ```md
   Synchronized workbook refresh behavior and status rendering with recent runtime fixes.

   DELIVERED:
   ✅ Added deterministic default refresh targeting via workspace-derived subscription and resource group resolution.
   ✅ Added optional cross-resource-group refresh path via workflow override picker.
   ✅ Added workbook note clarifying default versus override behavior for operators.
   ✅ Set workbook default tab to Available Data Connectors.
   ✅ Updated catalog status behavior to render from latest Con_Meta row with explicit Success/Pending/Failed semantics.
   ✅ Synchronized documentation in doc/docu.md and doc/architecture.md to reflect the implemented behavior.

   INVENTORY DELTA:
   - Added: none
   - Removed: none
   ```

### ✅ 12 — Inventory Sync for Deploy Workflow Artifact

  - tags: [documentation, governance, inventory]
  - priority: high
   ```md
   Synchronized documentation inventory after CI/workflow maintenance changes.

   DELIVERED:
   ✅ Updated doc/docu.md §10 File Inventory with the missing deployment artifact.
   ✅ Updated doc/architecture.md §8 Deployment Topology to reference the Function package artifact.

   INVENTORY DELTA:
   - Added: infra/function-package.zip
   - Removed: none
   ```

### ✅ 11 — Documentation Sync Audit + Apply

  - tags: [documentation, governance, sync-docs]
  - priority: high
   ```md
   Synchronized governing documentation with current workbook and workspace state.

   DELIVERED:
   ✅ Updated doc/docu.md to match current workbook tab names and Tab 3 behavior
     (deployment maturity, recommendations, connector health details,
     domain/subdomain drilldown).
   ✅ Updated doc/architecture.md decision flow to current Q1-Q8 logic including
     4a/4b/4c branching and preprocessing-first path for Q3=No.
   ✅ Aligned watchlist schema references to the 12-column contract
     (including Subdomain and Connector ID).
   ✅ Refreshed file inventory in doc/docu.md to actual workspace files.
     Included README.md, LICENSE, and CI workflow inventory entries;
     removed stale deploy.zip and doc/AllConnectors.csv entries.
   ✅ Flagged doc/decision-tree.drawio for manual visual parity updates only.
   ```

### ✅ 10 — Deployment Maturity Assessment (Coverage Summary Rework)

  - tags: [workbook, tab3, posture]
  - priority: medium
    ```md
    Replaced misleading Coverage Summary ("X / 600 = Y%") with a
    maturity-based assessment on Tab 3.

    PROBLEM:
    - Coverage % computed as installed/available was misleading — 20
      connectors out of 600 showed ~3% coverage, suggesting poor posture
      when it's actually a productive deployment.
    - No enterprise uses all 600+ connectors. The metric created a false
      sense of inadequacy.

    DELIVERED:
    ✅ `query-CoverageSummary` rewritten with 3 cards:
       - Installed count (from SentinelHealth)
       - Maturity tier (⚪ Initial / 🟡 Early / 🔵 Productive /
         🟢 Mature SOC / 🟣 Enterprise) based on installed count
       - Domains Covered (X / 11 security domains with ≥1 installed
         connector, excluding Other)
    ✅ Dropped Available count and Coverage % fields
    ✅ Title changed from "Coverage Summary" to "Deployment Maturity"
    ✅ New `text-MaturityLegend` element (Help-toggled) explaining
       5 maturity tiers with count ranges and deployment profiles
    ✅ Includes advisory: "More connectors ≠ better security"

    MATURITY TIERS:
    - ⚪ Initial (<5): Pilot or POC phase
    - 🟡 Early (5–15): Core Microsoft signals
    - 🔵 Productive (15–40): Microsoft + network + identity + SaaS
    - 🟢 Mature SOC (40–80): Multi-vendor, custom connectors, TI feeds
    - 🟣 Enterprise (80+): MSSP, multi-cloud, OT/IoT, full spectrum

    KQL uses same SentinelHealth→watchlist InstalledKey join pattern
    from query-DomainCoverageHeatmap for domain counting.
    ```

### ✅ 9 — Workbook Search UX: Dropdown Replacement

  - tags: [workbook, ux, tab1]
  - priority: medium
    ```md
    Replaced free-text search box with a watchlist-sourced dropdown.

    PROBLEM:
    - Free-text param (type 1, name="search") rendered as a non-interactive
      input in the Sentinel Workbooks view — users couldn't type a value.
    - Two-step UX: type → click row to export SelectedConnector.
    - SearchResults query used `contains` → multiple rows could leak into
      the description card visualization (which expects a single cell).

    DELIVERED:
    ✅ `param-ConnectorSearch` is now a Drop down (type 2) sourced from
       `_GetWatchlist('Con') | project ["Connector Name"] | order by ... asc`.
    ✅ Selection writes directly to `SelectedConnector` — single click.
    ✅ `query-SearchResults` no longer exports — it filters by
       `where ["Connector Name"] == connector` and shows a details row.
    ✅ `query-ConnectorDescription` switched to `==` + `take 1` — card visual
       is guaranteed a single cell even when names share substrings.
    ✅ `search` parameter retired — `SelectedConnector` is the single source
       of truth for selection state across the tab.
    ```

### ✅ 8 — Parser Robustness: Nested Brackets + Escaped Pipes

  - tags: [function, parser, bugfix]
  - priority: high
    ```md
    Two parser bugs in `ParseConnectors/run.ps1` that produced malformed
    watchlist rows for ~30 connectors.

    BUG 1 — Nested-bracket inline links:
    Names like `[[Recommended] Infoblox ... AMA](url)` and
    `[[Deprecated] AI Analyst Darktrace via AMA](url)` were rendered as
    raw markdown because the inline-link regex `\[([^\]]+)\]\([^\)]+\)`
    stopped at the first inner `]` and failed to match.

    BUG 2 — Escaped pipes in Method cells:
    Methods like `[CCF\|Azure Function](url)` caused row splitting on `\|`,
    producing `Method=[CCF\` and shifting Tables/Solution columns by one.
    Affected: 1Password Serverless, Atlassian Jira Audit, CyberArk Audit,
    Illumio Saas, MISP2Sentinel, Oracle Cloud Infrastructure variants, etc.

    DELIVERED:
    ✅ New regex `\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^\)]*\)` allows one
       level of `[...]` nesting in link text. Applied to Name, Vendor,
       Method, Solution strippers.
    ✅ Final bare-bracket unwrap `^\[name\]$` for `[DNS]` style names.
    ✅ Pre-protect `\|` → `<<ESCPIPE>>` token before `-split '|'`,
       restore after. Use `[1..(Count-2)]` positional slice instead of
       empty-cell filter to preserve column indices.
    ✅ 3 new Pester tests (nested `[Recommended]`, bare `[DNS]`,
       escaped pipe in Method). Suite: 30 → 33 tests, all passing.
    ✅ Deployed to `func-wl-parser-35kc7fgs7pkkw` and validated end-to-end
       via Logic App `la-watchlist-refresh` run — Succeeded.
    ```

### ✅ 6 — Tab 3 Security Coverage Gaps (Hero Section)

  - tags: [workbook, tab3, posture]
  - priority: medium
    ```md
    Domain-based security coverage heatmap with interactive drill-down.

    DELIVERED:
    ✅ Domain coverage heatmap (query-DomainCoverageHeatmap) — binary coverage (✅ Covered / ❌ Not covered)
    ✅ Fuzzy matching via 3-key strategy (exact, strip-last-segment, strip-connector-suffix)
    ✅ Compound domain split via mv-expand for multi-domain connectors
    ✅ Click-to-filter detail table (query-DomainDetail) — shows connectors in selected domain
    ✅ Status filter toggle (param-StatusFilter) — All / Installed / Not installed
    ✅ Connector ID column added to Azure Function output for reliable matching
    ✅ Pester tests updated — 28 tests passing (was 23)
    ✅ Design changed from percentage-based (🔴/🟠/🟢) to binary coverage (simpler, more actionable)
    ✅ Gap callouts not implemented — binary coverage + detail table replaces the need
    ```

### ✅ 5 — Watchlist Auto-Update via Logic App

  - tags: [data, watchlist, automation]
  - priority: high
    ```md
    Azure Function (ParseConnectors) parses sentinelninja GitHub connector catalog
    into a Sentinel watchlist, orchestrated by a weekly Logic App.

    DELIVERED:
    ✅ Azure Function — 9 helper functions, structured logging, CSV output (601 connectors)
    ✅ Domain mapping externalized to domain-map.json (~90 patterns, 6 domains)
    ✅ Pester test suite — 28 tests passing
    ✅ Infrastructure deployed via Bicep (Function App + Logic App + Storage + App Insights + RBAC)
    ✅ Logic App workflow: Recurrence → GET index + commit → ParseConnectors → DELETE + PUT watchlist → Update Con_Meta
    ✅ Failure alerting via optional Teams webhook
    ✅ Delete-before-PUT to prevent row accumulation (2026-05-15)
    ✅ End-to-end test passed — 601 connectors, exact count verified (2026-05-15)
    ✅ Workbook queries updated for new schema (Vendor→Supported by, added Domain) (2026-05-15)
    ```

### UX — Decision Tree Guided Conversation

  - tags: [workbook, ux, decision-tree]
    ```md
    Added 20 new elements to Tab 2 for a SOC-friendly guided experience:

    DECISION SUMMARY PANEL (text-DecisionSummary):
    - Markdown table tracking all Q1–Q8 answers via parameter references
    - Appears after Q1 is answered (vis: Q1≠"")
    - Shows empty cells for unanswered questions as visual progress
    - Includes instruction: "To change an answer, scroll to that question"

    RECOMMENDATION BADGES (text-RecBuiltIn through text-RecAdHoc):
    - 10 one-line badges with 🎯 prefix, one per outcome
    - Each uses same visibility as its result panel
    - "success" style for normal outcomes, "warning" for ad-hoc
    - Appear at top of tree alongside summary for at-a-glance result

    HELPER TEXTS (text-HelpQ1 through text-HelpQ8):
    - 10 italic 💡 prompts explaining why each question matters
    - Placed directly below each param-Q* dropdown
    - Same visibility conditions as their parent question
    - Examples: "REST APIs let Sentinel pull data programmatically",
      "CEF is widely used by firewalls, IDS/IPS"
    ```

### Explainability — Result Panel Reasoning

  - tags: [workbook, ux, decision-tree]
    ```md
    Added three explainability sections to all 10 result panels:

    1. "Why this recommendation" — dynamic text using parameter references
       ({Q3}, {Q4b}, etc.) to echo back the user's actual answers and explain
       why this specific method was chosen.

    2. "Why not the alternatives" — static reasoning per tree position,
       explaining what was ruled out at each branch point above.

    3. "Known constraints" — practical limitations per method:
       - CCF: only OAuth2/API key, needs pagination + JSON
       - Pipeline: K8s required, Syslog/CEF/OTLP only
       - Logstash: Elastic licensing, self-managed
       - CEF via AMA: dedicated Linux forwarder VM
       - Ad-hoc: suggests revisiting preprocessing path

    No new elements — expanded existing text-Result* markdown content.
    ```

### Visibility Fix — Full Ancestor Chain

  - tags: [workbook, bugfix, decision-tree]
    ```md
    PROBLEM: Azure Workbooks retain parameter values even when hidden.
    Switching an upstream answer (e.g., Q3 from Yes to No) left stale
    downstream result panels visible (e.g., CCF panel still showing
    because Q4a retained its value).

    FIX: Every result panel and recommendation badge now checks the
    COMPLETE ancestor chain in conditionalVisibilities — not just its
    direct parent parameter.

    BEFORE: text-ResultSyslog: Q6=Yes (1 condition)
    AFTER:  text-ResultSyslog: Q3=No AND Q4b=No AND Q5=No AND Q6=Yes (4 conditions)

    Fixed 20 elements total (10 text-Rec* + 10 text-Result*).
    Deepest chain has 5 conditions (CustomLogs, Webhook, AdHoc).
    ```

### Decision Tree Reorder + Azure Monitor Pipeline

  - tags: [workbook, decision-tree, architecture]
    ```md
    RESTRUCTURED Q3=No branch to ask preprocessing BEFORE CEF/Syslog:
    Old: Q3=No → Q4b(CEF) → Q5(Syslog) → Q6(Preprocessing) → Q7 → Q8
    New: Q3=No → Q4b(Preprocessing) → Q4c(K8s?) → Q5(CEF) → Q6(Syslog) → Q7 → Q8

    RATIONALE: Logstash and Azure Monitor Pipeline handle CEF, Syslog, and
    custom formats with preprocessing. Asking about preprocessing first avoids
    sending users down the simple AMA path when they actually need transformation.

    NEW QUESTION Q4c: "Arc-enabled Kubernetes cluster available?"
    - Visible when Q4b (Preprocessing) = Yes
    - Yes → Azure Monitor Pipeline (Microsoft-native, containerized)
    - No  → Logstash with Sentinel Output Plugin (fallback)

    NEW OUTCOME: Azure Monitor Pipeline (text-ResultPipeline)
    - Runs on Arc-enabled K8s, receives Syslog/CEF/OTLP
    - Auto-schematizes to Syslog and CommonSecurityLog tables
    - Persistent local storage, built-in TLS/mTLS
    - No third-party software to license or maintain
    - Link: https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-overview

    PARAMETER REUSE: Q4b/Q5/Q6 keep same param names but changed questions.
    Visibility chain downstream (Q7/Q8) unchanged since param names are stable.
    Updated: drawio, docu.md (v1.4), architecture.md (v1.5)
    ```

### Fix #8 — Installed Data Connectors Tab

  - tags: [workbook, tab]
    ```md
    Added Tab 3 "Installed Data Connectors" with 7 elements:
    - text-InstalledHeader: tab description
    - query-ConnectorHealth: main table — installed connectors with
      health icons, kind, last event timestamp, data freshness bucket
    - query-HealthPieChart: pie chart — Success/Warning/Failure breakdown (50%)
    - query-FreshnessPieChart: pie chart — data freshness buckets (50%)
    - query-CoverageSummary: tiles — installed vs available count + coverage %
      (cross-references watchlist 'Con' for available connector count)
    - query-FailuresWarnings: table — recent failures/warnings with descriptions
    - text-HealthPrerequisites: info panel — auditing/health monitoring prereqs
    All queries use SentinelHealth table with 7-day lookback.
    Tab switcher updated to 3 tabs. Intro text updated to mention 3 tabs.

    NOTE (2026-05-19): Superseded by later Tab 3 expansion.
    Current Tab 3 also includes deployment maturity tiers, recommendations,
    expandable connector health details, and domain/subdomain coverage drilldown.
    ```

### Fix #4 — UX Quick Wins

  - tags: [workbook, ux]
    ```md
    a) Removed hardcoded "cisco" from search box → default is now empty
    b) Subscription dropdown now queries resourcecontainers for display names
       instead of showing raw subscription GUIDs
    c) Introduction text updated: "three tabs" → "two tabs",
       removed reference to non-existent "Installed Data Connectors" tab

     NOTE (2026-05-19): Superseded by later Tab 3 implementation.
     Introduction now correctly references all three tabs.
    ```

### Fix #3 — Data Quality (AllConnectors.csv)

  - tags: [data, watchlist]
    ```md
    - Normalized vendor: "Microsoft" (3x) → "Microsoft Corporation" (now 130 total)
    - Deduplicated: Mimecast Secure Email Gateway, Mimecast Targeted Threat Protection
    - Rows: 267 → 265
    - Zero duplicates, zero vendor inconsistencies remaining
    ```

### Fix #1+#2+#6+#7+#9 — Decision Tree Complete Rewrite

  - tags: [workbook, decision-tree, bugfix, architecture]
    ```md
    Rewrote the entire Tab 2 decision tree (23 items):
    - Consolidated Q41/Q42/Q43 into single Q3 (REST API)
    - Consolidated 6x "Evaluate capabilities" into 1 header + 2 context prompts
    - Visibility: Q1 → Q2 → Q3 → Q4a(CCF)/Q4b(CEF) → Q5 → Q6 → Q7 → Q8
      Each question cascades from the previous answer
    - CCF branch now reachable (Q3=Yes → Q4a=Yes)
    - Added outcome guidance panels for all 8 leaf nodes:
      Built-in, CCF, Logs Ingestion API, CEF via AMA, Syslog via AMA,
      Logstash, Custom Logs v2, Webhook, Ad-hoc Upload
    - Each panel includes prerequisites + Microsoft Learn link
    - Renamed all elements: param-Q3-RestAPI, text-ResultCEF, etc.
    - Removed: "Under Development" unconditional text
    - Removed: stale design documentation markdown (was hidden via
      Tab!=2 but cluttered the JSON)
    - No default selections on dropdowns — user must choose
    ```

### Element Naming Convention Cleanup

  - tags: [workbook, maintainability]
    ```md
    Renamed all 39 workbook elements from auto-generated names to
    descriptive prefix-Purpose convention:
    - text-2 → text-WorkbookTitle
    - parameters-4 → params-Global
    - query-2 → query-SearchResults
    - links-8 → link-CopilotNudge
    - etc.
    Convention: text-, param-, query-, link-, group- prefixes
    ```

### File Cleanup (~430 MB removed)

  - tags: [project, cleanup]
    ```md
    Deleted 16 files:
    - Connectors.csv (2-row test leftover)
    - SentinelDataConnectors.html (replaced by workbook)
    - 3x azure-sentinel OneDrive conflict PDFs
    - 4x decision-tree_v2 PDFs (superseded by v3)
    - 3x decision-tree_v3 OneDrive conflict PDFs
    - decision-tree.png, decision-tree_v3.drawio.png
    - Decisiontrees.pptx
    - Mermaid Chart export artifact
    Workspace: 8 files → 8 files (from ~22 original)
    ```

### Workbook Scaffolding & Global Parameters

  - tags: [workbook, infra]
    ```md
    - Workbook created (Notebook/1.0 format, Sentinel User Workbook)
    - Global parameters: Subscription, Workspace, WorkspaceID, Help toggle, Tab switcher
    - Auto-detection of default subscription and workspace via Resource Graph
    - Workspace picker filtered to SecurityInsights-enabled workspaces
    ```

### Tab 1 — Available Data Connectors (Search & Catalog)

  - tags: [workbook, tab]
    ```md
    - Search box filters the 'Con' watchlist by connector name
    - Results table: Connector Name, Tables, DCR Support, Supported By
    - Row selection exports SelectedConnector parameter
    - Card visualization shows connector description on selection
    - 70/30 split layout (search/list left, next steps right)
    ```

### Tab 1 — Connectors by Vendor Pie Chart

  - tags: [workbook, visualization]
    ```md
    - Pie chart: _GetWatchlist('Con') | summarize count() by ["Supported by"]
    - Shows distribution of connectors across Microsoft and third-party vendors
    ```

### Tab 1 — Full Connector List Grid

  - tags: [workbook, visualization]
    ```md
    - Grid showing all connectors (name + vendor), up to 500 rows
    ```

### Tab 1 — Copilot in Azure Integration

  - tags: [workbook, copilot]
    ```md
    - "Ask Copilot in Azure for more Information" button (CopilotNudge)
    - Structured prompt: Overview, Prerequisites, Enablement Steps, Data Schema, References
    - Button only visible when a connector is selected
    ```

### Tab 1 — Content Hub Deep-Link

  - tags: [workbook, navigation]
    ```md
    - "Open Content Hub" button opens the Sentinel Content Hub blade
    - Pre-filled with selected workspace subscription, resource group, and name
    - Next Steps panel with link to Microsoft Learn connector reference
    ```

### Tab 1 — Help / Introduction Panel

  - tags: [workbook, ux]
    ```md
    - Conditional info panel (visible when Help = Yes)
    - Describes workbook purpose and required data sources
    - Links to "Turn on auditing and health monitoring" documentation
    ```

### Tab 2 — Decision Tree Structure (Q1–Q8)

  - tags: [workbook, decision-tree]
    ```md
    - Full decision tree documented in markdown within the workbook
    - Interactive Yes/No parameter dropdowns for Q1 through Q8
    - Q1: Listed in Content Hub? → Q2: Built-in connector?
    - Q3: REST API? → Q4: CEF? / CCF suitable?
    - Q5: Syslog? → Q6: Preprocessing? → Q7: Logstash / File export?
    - Q8: Webhooks?
    - "Use Built-in Connector" success panel with link back to Tab 1
    - "Evaluate capabilities" transition panels for all non-connector paths
    ```

### Watchlist Data Source (Con)

  - tags: [data, watchlist]
    ```md
    - Sentinel Watchlist 'Con' created and populated
    - Columns: Connector Name, Description, Tables, DCR Support, Supported By
    - CSV source files: AllConnectors.csv (full catalog), Connectors.csv (curated)
    ```

### Decision Tree Diagram

  - tags: [documentation]
    ```md
    - decision-tree_v3.drawio: Draw.io diagram of the ingestion decision tree (v3)
    ```