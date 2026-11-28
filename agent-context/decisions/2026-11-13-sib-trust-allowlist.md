# ADR-006: sib pre-trusts allowlisted start dirs for claude siblings

- **Date**: 2026-11-13
- **Status**: Accepted
- **Deciders**: user (approved option 1 of 2), with Claude
- **Supersedes**: none
- **Amended by**: [ADR-009](2026-11-25-sib-pretrust-codex-and-committee-panes.md)

## Context

The session desk (orch, ADR-003) starts sessions with
`sib spawn <slug> --workdir <dir> --new-workspace`. When `<dir>` has never
been opened in Claude Code, the new pane stops at the "Yes, I trust this
folder" dialog. Nobody is at that pane, and the desk must not answer
another session's prompt, so the user had to walk to the pane every time.

## Decision

Before launching a **claude** sibling, `sib` marks the start dir trusted —
`.projects[<dir>].hasTrustDialogAccepted = true` in
`${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` — **only** when the dir matches
a user-owned allowlist:

- File: `${XDG_CONFIG_HOME:-~/.config}/sib/trusted-dirs`
  (override: `SIB_TRUST_FILE`).
- One pattern per line; `~/` expands to `$HOME`; `#` comments;
  `*` matches within **one** path segment.
- Only dirs under `$HOME` are eligible. The dir is resolved to its
  physical path first (Claude keys trust by physical cwd).
- The rewrite is atomic (jq → temp file → `mv`, mode 600) and keeps every
  other field.
- Codex siblings are not touched.

A dir not on the list keeps the dialog. `sib` detects the dialog (checked
before the ready marker, since the dialog's `❯` option list can look like
the input box), sends no prompt, and exits **6** so the caller can tell
the user instead of reporting the session ready. `/pane-msg` likewise
classifies the dialog as an approval prompt and refuses to type into it
(its preselected option is "No, exit").

## Alternatives Considered

- **Auto-answer the dialog** with `cmux send-key` — rejected: it defeats a
  safety gate, which `no-permission-bypass` forbids.
- **Trust every dir under `$HOME`** — rejected: too broad. A trusted dir
  loads its project `.claude/` settings, hooks and MCP config without a
  prompt.
- **Do nothing** — rejected by the user: every new dir needs a manual
  confirmation at the pane.

## Consequences

### Positive

- Desk-started sessions in listed dirs come up ready to take work
  (verified live 2026-11-13 with a desk-spawned session in a persona repo).
- A pane blocked by the dialog is reported (exit 6), never claimed ready.

### Negative

- Each allowlist entry is a standing permission grant. Agents add entries
  **only on the user's explicit say-so**. The user creates and edits the
  file; auto mode denied the agent's own write to it.
- A running Claude process that rewrites `~/.claude.json` from stale
  memory could drop the entry. If that happens, the dialog reappears and
  sib reports it (exit 6); nothing is silently lost.

### Neutral

- The allowlist is per machine and lives outside this repo; typical
  entries are the user's persona repo and the desk's data dirs
  (e.g. `~/.local/share/cmux/*`).

## References

- Commit `6497d86` — `bin/sib` (`trust_allowlisted`, `trust_dialog_up`)
- Commit `00278f1` — `/pane-msg` trust-dialog refusal
- Tests: `tests/sib-spawn.bats` (folder-trust section)
- Constraint: `agent-context/constraints/no-permission-bypass.md`
