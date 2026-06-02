ALWAYS use #context7 MCP Server to read relevant documentation. Do this every time you are working with a language, framework, library etc. Never assume that you know the answer as these things change frequently. Your training date is in the past so your knowledge is likely out of date, even if it is a technology you are familiar with.

## Mandatory Coding Principles

### Structure
- Use a consistent, predictable project layout.
- Group code by feature/screen; keep shared utilities minimal.
- Create simple, obvious entry points.
- Before scaffolding multiple files, identify shared structure first. Use framework-native composition patterns (layouts, base templates, providers, shared components) for elements that appear across pages. Duplication that requires the same fix in multiple places is a code smell, not a pattern to preserve.

### Architecture
- Prefer flat, explicit code over abstractions or deep hierarchies.
- Avoid clever patterns, metaprogramming, and unnecessary indirection.
- Minimize coupling so files can be safely regenerated.

### Functions and Modules
- Keep control flow linear and simple.
- Use small-to-medium functions; avoid deeply nested logic.
- Pass state explicitly; avoid globals.

### Naming and Comments
- Use descriptive-but-simple names.
- Comment only to note invariants, assumptions, or external requirements.

### Logging and Errors
- Emit detailed, structured logs at key boundaries.
- Make errors explicit and informative.

### Regenerability
- Write code so any file/module can be rewritten from scratch without breaking the system.
- Prefer clear, declarative configuration (JSON/YAML/etc.).

### Platform Use
- Use platform conventions directly and simply (e.g., WinUI/WPF) without over-abstracting.

### Modifications
- When extending/refactoring, follow existing patterns.
- Prefer full-file rewrites over micro-edits unless told otherwise.

### Quality
- Favor deterministic, testable behavior.
- Keep tests simple and focused on verifying observable behavior.

## Project-Specific Conventions

### Azure Function (ParseConnectors)
- Domain mapping lives in `domain-map.json` — never hardcode domain lookups.
- Function output contract is `{ csv, stats }` — not raw JSON arrays.
- CSV schema includes 12 columns: Connector Name, Connector Description, Vendor, Method, Table Count, Solution, Status, Flags, Source Version, Domain, Subdomain, Connector ID.
- Tests live in `func-watchlist-parser/Tests/` alongside the function code.
- Use `Write-Trace` for structured logging (outputs JSON via Write-Information → App Insights).
- Wrap single-item pipeline results in `@()` to prevent PowerShell unwrapping.

### Infrastructure
- Logic App workflow definition is in `infra/logic-app-definition.json`, loaded by `main.bicep` via `loadJsonContent()`.
- Logic App uses Sentinel Contributor role (not Responder).
- Watchlist updates are atomic PUT operations (fail-closed), not per-item upserts.

### Documentation
- Governing docs live in `doc/` — keep `docu.md`, `architecture.md`, `kanban.md` in sync via the sync-docs skill.
- File inventory in `docu.md` §10 must reflect actual workspace contents.

### Context7 Reliability Policy
- Before Context7-dependent work, run a preflight check (`scripts/context7/Test-Context7Setup.ps1`).
- On `401` auth failures, show a clear warning immediately: token expired/invalid.
- Retry only transient failures (network/timeouts) with short backoff; do not retry `401`.
- If retries fail for non-auth reasons, proceed with a clear warning and use fallback official documentation sources.
