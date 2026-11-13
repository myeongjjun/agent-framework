# ADR-003: cmux session desk (orch) promoted to L1

- **Date**: 2026-11-13
- **Status**: Accepted
- **Deciders**: maintainer (with Claude)
- **Supersedes**: none
- **Amended by**: [ADR-004](./2026-11-13-session-cleanup-self-report.md)

## Context

The cmux session desk — the `orch` agent, the `brief` CLI, the
`brief-mod` plugin, the Sessions panel template, the `morning-brief.sh`
launcher and its automation rules — was built inside a persona's
machine-config repo. It depends only on cmux, Claude Code and git; it has
no persona infrastructure (no issue tracker, wiki, messenger or domain
service). Per-machine data is already kept outside the repo
(`~/.local/share/cmux/orch/`, `~/.config/cmux/local.env`).

Two things blocked a clean split:

1. cmux reads a **single** `~/.cmuxterm/automations.json`, but its rules
   come from several layers (the desk's rules, a persona's own launchers,
   a user's window preferences). Whoever symlinks the file owns it all.
2. The morning launcher also started a persona-only operator agent, so
   the launcher itself mixed L1 and L2 concerns.

## Decision

Promote the desk to L1, by the same in-scope reasoning as ADR-001
(dispatch/collab): it drives L1's own engine (cmux panes, sib) and needs
nothing persona-specific.

| Path | Deployed to |
|---|---|
| `agents/orch.md` | `~/.claude/agents/orch.md` (copy, like `approver`) |
| `cmux/brief`, `cmux/sidebars/` | `~/.local/bin/brief` (symlink; template resolved next to the script) |
| `cmux/{morning-brief.sh,morning-brief.md,brief-mod,sessions-toggle.sh}` | `~/.config/cmux/` (symlink) |
| `cmux/seeds/orch-*.md` | `~/.local/share/cmux/orch/` (copied once; local-only git), linked into `~/.config/cmux/` |
| `cmux/automations.json` | merged into `~/.cmuxterm/automations.json` |

- **`bin/cmux-automations-merge`**: every layer ships a rule fragment and
  merges it **by rule id** — same id replaced, new id appended, other
  rules untouched, re-run is a no-op. A legacy symlinked file is replaced
  by a regular file. No layer owns the whole file any more.
- **Extension point**: after starting the desk, `morning-brief.sh` runs
  `~/.config/cmux/morning-brief.d/*.sh` (with `TODAY`). Personas add
  morning launchers there instead of editing the L1 script.
- **Opt-out**: on by default on every machine; `MORNING_BRIEF=0` in
  `~/.config/cmux/local.env` disables it per machine (`--force` still runs).
- Persona-specific operator agents stay in their persona's L2 and hook in
  via `morning-brief.d/`.

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| Keep the desk in the persona repo | No move | Every persona/machine re-copies it; contradicts the L1 in-scope rule |
| L1 owns the whole `automations.json` | Simple deploy | Users and personas lose any place for their own rules |
| One automations file per layer | Clear ownership | cmux reads only one file |
| Opt-in per machine | No surprise launch on new machines | The desk is meant to be common; opt-out keeps the default useful |

## Consequences

### Positive
- Installing L1 alone yields a working session desk on any machine.
- Each layer manages only its own automation rules.
- Personas extend the morning start without forking L1.

### Negative
- L1 install now writes outside `~/.claude` (`~/.config/cmux`,
  `~/.cmuxterm`, `~/.local/share/cmux`).
- The desk starts on every machine where L1 `install.sh` runs, unless
  opted out. Today that is a manual `git pull` + `install.sh` per machine;
  `scripts/check-update.sh` would pull and install automatically only on
  a machine that registers it (cron is documented but not registered on
  the machines checked as of 2026-11-13). A machine that pulls a persona
  repo which dropped its desk copy, without updating L1, loses the desk
  until L1 is installed.
- Removing a rule from `cmux/automations.json` does not delete it from
  deployed files; use `cmux-automations-merge --remove <id>`.

## References

- ADR-001 — dispatch/collab promotion (same in-scope reasoning)
- `cmux/`, `agents/orch.md`, `bin/cmux-automations-merge`
- `scripts/install.sh` §3b, `scripts/verify.sh`
