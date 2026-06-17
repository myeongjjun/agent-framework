# ADR-001: sib workspace targeting + dispatch/collab promotion to L1

- **Date**: 2026-06-17
- **Status**: Accepted
- **Deciders**: maintainer (with Claude)
- **Supersedes**: none

## Context

Two problems surfaced while using `/dispatch` in practice:

1. **sib placed siblings in the wrong place.** `sib spawn` always started
   the agent in the caller's cwd and split the caller's current cmux
   workspace. Dispatching work for repo B from a session sitting in repo A
   dropped the sibling into A's directory and A's workspace pane — even when
   a workspace already rooted at B existed.

2. **The dispatch/collab skills had no L1 home.** During the earlier L1
   reorg, `skills/{dispatch,collab,...}` were removed from `agent-framework`
   as "workspace-specific". Investigation showed this was wrong for two of
   them: dispatch and collab carry **no persona-specific dependency** (no
   Jira/Wiki/OBSERV/domain tooling) — they use only `sib` + `cmux` + `git`,
   exactly like the `sib` and `codex` assets that *are* L1. Their canonical
   source had drifted to the `agent-workspace` (L2) repo, and a deployed
   orphan copy lived under `~/.claude/skills/` and `~/.codex/skills/` with no
   tracked source. By the L1 in-scope rule ("active in every persona, not
   dependent on persona infrastructure"), both belong in L1 next to the
   engine they drive.

A full L2 re-audit confirmed the split: only dispatch + collab are
persona-free. The remaining L2 skills (agit, daily, weekly, research,
ticket, postmortem, wiki-edit, ch-ops, quick-dashboard, observe, improve,
inbox) depend on Jira/Wiki/Agit/OBSERV/ClickHouse or the `.agent/` layout
and correctly stay in L2.

The reliable way to read a cmux workspace's working directory is
`cmux sidebar-state --workspace <ref>` (`cwd=` field). `cmux tree` does not
report cwd; tty→lsof and OSC-title parsing are unreliable (ttys are reused).

## Decision

**1. sib gains placement flags** (`bin/sib`):
- `--workdir <path>` (alias `--cwd`): start the sibling in an arbitrary
  directory. Precedence: `--worktree` (managed checkout) > `--workdir` >
  caller PWD. `--worktree` + `--workdir` together is rejected.
- `--workspace <id|ref>`: split an already-open workspace instead of the
  caller's.
- `--new-workspace`: create a dedicated cmux workspace rooted at the
  resolved workdir (`cmux new-workspace --cwd`). `sib kill` closes the whole
  workspace for these (a one-surface workspace can't have its last surface
  closed). State records `workdir=` and `workspace_managed=`.

**2. dispatch + collab promoted to L1** (`agent-framework/skills/`):
- dispatch v0.6.0 adds workspace targeting: resolve the task's workdir,
  enumerate workspaces via `cmux list-workspaces`, match each one's cwd via
  `cmux sidebar-state`, then reuse / caller-split / create-dedicated as
  appropriate. Never split an unrelated workspace without warning.
- collab v4.0.0: same content as v3.0.0, rehomed to L1, merge references
  point at the now-L1 `agent-promote.sh`.

**3. collab's merge dependency promoted to L1**:
- `agent-promote.sh` moved into `bin/` (symlinked to `~/.local/bin/` like
  sib — it is a runtime tool, not an install script).
- Supporting hooks `guard-cherry-pick.sh` (PreToolUse/Bash) and
  `turn-end-wip-commit.sh` (Stop) promoted to `hooks/general/`.
  `turn-end-wip-commit.sh` was extended to recognize sib's `sib/<slug>`
  branches and `.local/share/sib/worktrees/` paths (it previously only
  matched the retired orchestrator's `dispatch/<slug>-…` naming).

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| Keep dispatch/collab in L2; edit there | No reorg churn | Engine (sib) in L1 but its core workflows in L2 — installing L1 alone leaves nothing usable; contradicts L1 in-scope rule |
| Rewrite collab to drop agent-promote (pure `git merge`) | Smaller L1 footprint | Loses risk-scan + wip-squash; reimplements a working tool; agent-promote is itself persona-free |
| Use `cmux tree` / tty→lsof for workspace cwd | No new command | cmux tree omits cwd; ttys are reused → wrong identity. `sidebar-state` is the supported source |
| Add cwd to `cmux tree` output | Cleaner long-term | Requires a change in the separate cmux repo; out of scope. `sidebar-state` suffices now |

## Consequences

### Positive
- Installing L1 alone yields a working dispatch/collab flow (engine + driver
  + merge tool all present).
- Siblings land in the correct workspace/directory; base session is no longer
  polluted with unrelated work.
- One canonical source for dispatch/collab; the untracked deployed orphans
  get replaced by install.sh symlinks.
- `turn-end-wip-commit` now actually fires inside sib worktrees.

### Negative
- Reverses part of the earlier reorg's "workspace-specific" classification
  for these two skills + agent-promote (documented here as the correction).
- agent-promote's risk-scan/merge logic is now L1 surface to maintain.

### Neutral
- Registering the new Stop / Bash hooks in `~/.claude/settings.json` is a
  separate, maintainer-gated step (the `no-permission-bypass` constraint
  forbids the agent from auto-editing settings.json). install.sh only copies
  hook *sources*.
- The deployed orphan dirs require `install.sh --force` to overwrite (the
  installer refuses to clobber non-symlink deployed copies without consent).

## Implementation Notes

- Regression tests: `tests/sib-spawn.bats` (11 cases) cover `--workdir`/
  `--cwd`, `--workspace`, `--new-workspace`, the worktree/workdir precedence
  guard, mutual exclusivity, and kill-time workspace-vs-surface teardown.
  cmux is stubbed via `tests/helpers/cmux-stub`, injected through the new
  `SIB_EXTRA_PATH` seam.
- The agent-workspace (L2) copies of dispatch/collab/agent-promote and the
  two hooks are removed in the same change set; L2 inherits them from L1.

## References

- `docs/sib-dispatch-improvement.md` — originating spec
- `bin/sib`, `bin/agent-promote.sh`, `skills/dispatch/`, `skills/collab/`
- `hooks/general/{guard-cherry-pick,turn-end-wip-commit}.sh`, `hooks/HOOKS.md`
