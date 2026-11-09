# ADR-002: acp-init relies on native AGENTS.md loading — no CLAUDE.md symlink

- **Date**: 2026-11-09
- **Status**: Accepted
- **Deciders**: maintainer (with Claude)
- **Supersedes**: none

## Context

`acp-init` (≤ v1.4.0) created a `CLAUDE.md → AGENTS.md` symlink so Claude
Code would load the ACP guide. Since Claude Code v2.1.277, Claude Code reads
`AGENTS.md` natively when no `CLAUDE.md`, `.claude/CLAUDE.md`, or
`CLAUDE.local.md` exists in the working directory or above; if one exists it
replaces `AGENTS.md` unless it imports `@AGENTS.md`. The symlink is now a
redundant workaround.

But a repo cannot enforce a minimum Claude Code version:
`requiredMinimumVersion` is managed-settings only, and the project
`minimumVersion` only gates auto-updates — it does not block startup. In a
team-shared repo, teammates on an older Claude Code would silently lose the
project instructions if the shim disappeared.

## Decision

`acp-init` v1.5.0 asks the user which case applies:

1. **Personal / single-owner repo** — no `CLAUDE.md`. Init never creates the
   symlink. Upgrade mode offers to remove an existing symlink that points at
   `AGENTS.md`.
2. **Team-shared repo** — keep a `CLAUDE.md` containing just `@AGENTS.md`
   (import: works on every version, Windows-safe, never double-loaded),
   unless the org enforces `requiredMinimumVersion` >= 2.1.281 via managed
   settings, in which case treat it as case 1. Upgrade mode offers to replace
   an existing symlink with the import file.
3. A real (non-symlink) `CLAUDE.md` is never modified or deleted; acp-init
   only warns if it lacks `@AGENTS.md`.

The AGENTS.md template's Agent Notes line becomes: "Reads AGENTS.md natively
(v2.1.277+). A project CLAUDE.md / CLAUDE.local.md replaces it unless it
imports @AGENTS.md".

## Alternatives Considered

| Alternative | Pros | Cons |
|---|---|---|
| Keep the symlink | No change; works on old versions | Redundant; symlinks are fragile on Windows; keeps an outdated rationale |
| Always a `@AGENTS.md` import file | Works everywhere | Extra file in personal repos that need none |
| Always remove (no CLAUDE.md) | One file everywhere | Teammates on Claude Code < v2.1.277 lose project instructions |
| Ask per repo (chosen) | Minimal files where safe; safe default where not | One extra question during init/upgrade |

## Consequences

### Positive
- Personal repos have a single instruction file (`AGENTS.md`).
- Team repos stay correct on every Claude Code version without a symlink.

### Negative
- acp-init now asks a question it used to answer itself.
- Existing repos keep their symlink until someone re-runs acp-init upgrade
  (harmless — native loading reads the content once).

## References

- [Claude Code docs — AGENTS.md](https://code.claude.com/docs/en/memory#agents-md)
- [Remove an earlier AGENTS.md workaround](https://code.claude.com/docs/en/memory#remove-an-earlier-agents-md-workaround)
- agent-workspace ADR-050 (`2026-11-09-native-agents-md-drop-claude-md-symlink.md`)
- `skills/acp-init/SKILL.md` v1.5.0
