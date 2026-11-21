---
name: acp-init
version: 1.5.1
description: >
  Initialize or upgrade Agent Context Pack (ACP) structure in the current project.
  Creates AGENTS.md (pure ACP guide), decisions/, constraints/ directories.
  Supports Init mode (new) and Upgrade mode (existing AGENTS.md).
trigger_phrases:
  - "init acp"
  - "setup acp"
  - "initialize agent context"
  - "ACP 초기화"
  - "에이전트 컨텍스트 설정"
  - "acp 설정"
---

# ACP Init — Initialize Agent Context Pack

## Purpose

Set up the ACP directory structure in a project so any agent can share context through standard files.

**Core principles:**
- AGENTS.md is a pure ACP guide, with no project information.
- `agent-context/` is READ-ONLY; only the ACP skills change it.
- The `<!-- ACP:TEMPLATE_END -->` marker divides the template part from the custom part.

## What Gets Created

```
project/
├── AGENTS.md                   # ACP guide for agents (source of truth)
├── CLAUDE.md                   # Team-shared repos only: contains just `@AGENTS.md`
├── agent-context/
│   ├── decisions/              # Architecture Decision Records
│   │   ├── README.md           # ADR format guide
│   │   └── INDEX.md            # Decision index
│   └── constraints/            # Immutable constraints
│       ├── README.md           # Constraint format guide
│       └── INDEX.md            # Constraint index
└── .gitignore                  # Updated to exclude .agent/
```

## Claude Code Loading (CLAUDE.md policy)

Claude Code v2.1.277+ reads `AGENTS.md` natively when no `CLAUDE.md`,
`.claude/CLAUDE.md`, or `CLAUDE.local.md` exists in the working directory or
above. If any of those exists, it replaces `AGENTS.md` unless it imports
`@AGENTS.md`. See https://code.claude.com/docs/en/memory#agents-md.

A repo cannot enforce a minimum Claude Code version: `requiredMinimumVersion`
is managed-settings only, and project `minimumVersion` only gates auto-updates
(it does not block startup). So ask the user which case applies:

| Repo type | CLAUDE.md |
|---|---|
| **Personal / single-owner** | None. Do not create one; `AGENTS.md` loads natively. |
| **Team-shared** (others can run older Claude Code) | A `CLAUDE.md` containing just `@AGENTS.md` — works on every version, Windows-safe, never double-loaded. |
| **Team-shared, org enforces `requiredMinimumVersion` >= 2.1.281 via managed settings** | None (same as personal). |

Never create a `CLAUDE.md → AGENTS.md` symlink.
Never modify or delete a real (non-symlink) `CLAUDE.md` file.

## Modes

### Init Mode (default)

- **Condition**: AGENTS.md does not exist.
- **Action**: Create it from the template, with the marker.

### Upgrade Mode

- **Condition**: AGENTS.md exists.
- **Action**:
  1. Find the `<!-- ACP:TEMPLATE_END -->` marker.
  2. Extract the content after the marker (the project custom part).
  3. Generate the latest template, up to the marker.
  4. Append the extracted custom content.

**Boundary**: the `<!-- ACP:TEMPLATE_END -->` marker.

**Fallback** (old version without the marker):
- Find the `## Project-Specific Sections` header.
- If there is none, find the first `---` divider.
- If there is neither, replace the whole file and warn the user.

## Actions

### Init Mode

1. **Check if already initialized** - if AGENTS.md exists, switch to Upgrade Mode
2. **Create directories** - `mkdir -p agent-context/decisions agent-context/constraints`
3. **Create AGENTS.md** - Use template from [templates.md](templates.md)
4. **Apply CLAUDE.md policy** - Ask the user: personal/single-owner or team-shared (and, if team-shared, whether the org enforces `requiredMinimumVersion` >= 2.1.281). See [CLAUDE.md policy](#claude-code-loading-claudemd-policy).
   - Personal, or team-shared with enforced minimum version: create nothing.
   - Team-shared otherwise: write `CLAUDE.md` with the single line `@AGENTS.md`.
   - If `CLAUDE.md` already exists, do not overwrite it; if it lacks `@AGENTS.md`, warn that it hides `AGENTS.md` from Claude Code.
5. **Create agent-context/decisions/README.md** - ADR format guide
6. **Create agent-context/decisions/INDEX.md** - Empty index
7. **Create agent-context/constraints/README.md** - Constraint format guide
8. **Create agent-context/constraints/INDEX.md** - Empty index
9. **Update .gitignore** - Add `.agent/` if not present
10. **Report completion** - Show created files and next steps

### Upgrade Mode

1. **Read existing AGENTS.md**
2. **Find marker** - find `<!-- ACP:TEMPLATE_END -->`
3. **Extract custom content** - keep the content after the marker
4. **Generate new template** - the latest template, up to the marker
5. **Append custom content** - append the kept content
6. **Review CLAUDE.md** - Ask which repo type applies (see [CLAUDE.md policy](#claude-code-loading-claudemd-policy)), then:
   - `CLAUDE.md` is a symlink to `AGENTS.md`: offer to replace it — remove it (personal / enforced minimum version) or replace it with a file containing `@AGENTS.md` (team-shared). Change nothing without the user's yes.
   - `CLAUDE.md` is a real file: never modify or delete it. If it lacks `@AGENTS.md`, warn that `AGENTS.md` is not loaded by Claude Code.
   - No `CLAUDE.md` and team-shared without enforced minimum version: offer to create one containing `@AGENTS.md`.
7. **Update other ACP files if needed** - check the `decisions/` and `constraints/` directories
8. **Report changes** - report the completed update

## Templates

For detailed templates, see [templates.md](templates.md).

## Notes

- AGENTS.md has no project information; that lives in README.md or package.json.
- The agent MUST NOT edit `agent-context/` directly; it uses the ACP skills.
- A project MAY add its own content after the marker.
