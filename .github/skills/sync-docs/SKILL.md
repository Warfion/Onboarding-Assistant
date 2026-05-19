---
name: sync-docs
description: 'Synchronize project documentation after a workflow change. Detects drift between doc/docu.md, doc/kanban.md, .github/copilot-instructions.md, doc/architecture.md, and doc/decision-tree.drawio — then proposes aligned edits. USE WHEN: sync docs, update all docs, align documentation, propagate change, new rule added, workflow changed, improvement implemented, keep docs in sync, doc drift, audit docs.'
argument-hint: 'Describe the change to propagate, or say "audit" to scan for drift'
---

# Documentation Sync — Sentinel Onboarding Assistant

Keep the five governing documents of this workspace aligned after any workflow change.

## Governing Documents

| File | Role | Editable | Contains |
|------|------|----------|----------|
| `doc/docu.md` | Master specification | Yes | Workbook spec, schema, integrations, naming conventions, status & gaps (§1–§10) |
| `doc/kanban.md` | Task tracker | Yes | To Do / In Progress / Done — numbered items (#N) with priority, tags, design specs |
| `.github/copilot-instructions.md` | Agent rules | Yes | Always-on coding principles, Context7 mandate, quality standards |
| `doc/architecture.md` | Architecture reference | Yes | System diagrams, data pipeline, deployment topology, element naming (§1–§10) |
| `doc/decision-tree.drawio` | Visual diagrams | Flag only | Decision tree (Tab 2: Q1–Q8) and architecture topology diagrams |

### Sync Relationships

```
copilot-instructions.md  ←→  doc/architecture.md
        ↕                          ↕
  doc/docu.md            ←→   doc/kanban.md
        ↕                          
  doc/decision-tree.drawio  ←→  doc/architecture.md
```

- **Coding principles** in `copilot-instructions.md` must be consistent with **patterns described** in `architecture.md`
- **Status & Known Gaps** in `docu.md` §9 must have matching **kanban items** in `kanban.md`
- **Done kanban items** must be reflected in `docu.md` (§9 status, §10 file inventory) and `architecture.md` (diagrams, topology)
- **New infrastructure or code files** must appear in `docu.md` §10 (File Inventory) and `architecture.md` §8 (Deployment Topology)
- **Schema changes** (watchlist columns, workbook elements) must be consistent across `docu.md` §5, `architecture.md` §9, and actual code
- **Decision tree changes** (Q1–Q8 questions, outcomes, visibility logic) in the workbook or `architecture.md` §4–§5 must flag `decision-tree.drawio` for manual update
- **Topology changes** (new resources, changed data flow) in `architecture.md` §1/§6/§8 must flag `decision-tree.drawio` for manual update

## Procedure

### Mode A: Propagate a specific change

When the user describes a change (e.g. "I added Pester tests and refactored run.ps1"):

1. **Identify the source** — which file or code was already updated?
2. **Read all 4 editable governing documents** to understand current state
3. **Determine required updates** for each remaining file:
   - `doc/docu.md`: Update §9 (Status & Known Gaps), §10 (File Inventory), or relevant schema sections
   - `doc/kanban.md`: Move item to Done, or add new item if the change introduces follow-up work
   - `.github/copilot-instructions.md`: Add/update rule if the change establishes a new coding convention
   - `doc/architecture.md`: Update diagrams, topology, or element naming if structure changed
   - `doc/decision-tree.drawio`: **Flag for manual update** if decision tree logic or system topology changed — describe exactly what needs to be redrawn
4. **Present a diff summary** showing what will change in each file — wait for user confirmation
5. **Apply edits** after confirmation

### Mode B: Full audit (argument = "audit")

1. **Read all 4 editable governing documents**
2. **Cross-reference** for drift:
   - Gaps listed in `docu.md` §9 without a kanban item
   - Done kanban items whose changes aren't reflected in `docu.md` or `architecture.md`
   - Files in the workspace not listed in `docu.md` §10 (File Inventory)
   - Architecture diagrams in `architecture.md` that don't match current code structure
   - Coding rules in `copilot-instructions.md` not followed by actual code patterns
   - Schema mismatches between `docu.md` §5 and actual watchlist/workbook definitions
   - Decision tree logic in `architecture.md` §4–§5 that differs from the workbook implementation
   - Topology in `architecture.md` §8 that doesn't match deployed infrastructure
3. **Report findings** as a numbered list with proposed fixes
4. For `decision-tree.drawio` drift: describe what diagrams need manual updating
5. **Wait for user** to select which fixes to apply
6. **Apply selected fixes**

### Mode C: New improvement proposal

When the user describes a new improvement idea:

1. **Draft the kanban item** for `doc/kanban.md` (To Do section, with tags/priority and design spec in fenced code block)
2. **Draft the docu.md update** — add to §9 (Known Gaps) or relevant section
3. **Present both drafts** — wait for confirmation
4. **Apply edits** — do NOT touch `copilot-instructions.md` or `architecture.md` until the improvement is implemented

## Rules

- **Language:** All documents are in English.
- **Never delete content** without user confirmation — append, update, or move to Done.
- **Kanban structure:** To Do / In Progress / Done. Each item has a number (#N), priority, tags, and a design spec in a fenced markdown code block.
- **Kanban numbering:** Items are numbered sequentially (#1, #2, ... #N). Don't renumber existing items. New items get the next available number.
- **Doc sections:** `docu.md` and `architecture.md` both use §1–§10. Don't renumber. Add subsections if needed.
- **Show before writing:** Always present proposed changes and wait for confirmation before editing files.
- **File Inventory:** If a new file is added to the project, update `docu.md` §10 (File Inventory) and `architecture.md` §8 (Deployment Topology) if it's an infrastructure or deployment file.
- **Schema consistency:** When watchlist columns or workbook elements change, ensure `docu.md` §5, `architecture.md` §9, and actual code all agree.
- **Draw.io is read-only to the agent:** Never attempt to edit `decision-tree.drawio` directly. Only flag it for manual update and describe what needs to change.
