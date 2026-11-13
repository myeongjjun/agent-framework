# ADR-004: Finished sessions report themselves and the desk closes them

- **Date**: 2026-11-13
- **Status**: Accepted
- **Deciders**: maintainer (with Claude)
- **Supersedes**: none
- **Amends**: [ADR-003](./2026-11-13-cmux-session-desk-l1.md)

## Context

Sessions kept piling up. On 2026-11-13, 21 of 23 open agent sessions
were idle, 12 of them for more than a day, and `~/.local/share/sib/state/`
held 44 files, 34 of them for panes that no longer existed. The cause
was structural, not one bug:

- Nothing ever said "this task is finished". A sibling's turn ending
  was not a signal, and ADR-003's desk could start the completion review
  only after the user called a task done (`/done`), so a session closed
  only when the user remembered to close it.
- The Sessions panel's "Collab" group linked any two sessions that had
  exchanged a `cmux agent message` in the last 48 h, so finished
  hand-offs looked like a live collaboration for two days.
- `/collab` tore its workers down only in Phase 5; a run that stopped
  earlier left both panes, worktrees and branches open.
- `sib` removed state only on `sib kill`; panes closed any other way
  (`brief done`, by hand) left their state behind, and a dead slug
  blocked re-spawning under the same name.

## Decision

1. **Self-report closes.** The desk (orch) runs the completion review on
   every `done-report:`. When a session reported `ready` and the review
   passes, the desk finishes and closes it without the user calling it
   done. Closing a session that neither reported `ready` nor was called
   done by the user stays an Ask-first action. Skipping the review
   (`--now`) stays the user's only.
2. **Completion contract.** `sib spawn --report` appends a contract to
   the task: when finished, the sibling sends `done-report:` to the desk
   (`brief desk` gives its panel id) and stays open. `/dispatch` always
   passes `--report`. `/collab` workers do not: the caller owns them.
3. **Cleanup candidates.** Sessions idle for 6 h or more, with no TODO
   item, nothing waiting for the user, and not a `/collab` worker. The
   Sessions panel groups them as `정리 후보`; the desk sends each a
   done-request (`brief done <panel>`) at the morning brief and on
   patrol, at most once a day per session.
4. **`/collab` always tears down.** The caller runs `sib kill` on both
   workers on every exit, including an early stop. Re-dispatch reuses
   the workers via `sib send` rather than spawning new ones.
5. **Collab grouping.** A group is either a `sib spawn --worktree`
   Claude + Codex pair, or sessions with an unread message between them
   in the last 48 h. Messages that have been read no longer link sessions.
6. **sib state hygiene.** `sib list` and `sib spawn <slug>` drop the
   state of a sibling whose pane is gone, only when cmux itself answers.
   State with a sib-managed worktree is kept for `sib kill`. Slugs must
   not start with `-`.

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| Keep "user calls done" as the only trigger, desk only lists candidates | No session closed without the user | The status quo that produced the pile-up |
| Auto-close on idle timeout without a report | Simplest | Closes sessions with unfinished work; no record of what was done |
| Put the contract in the /dispatch skill text only | No sib change | The agent may forget it; not testable |

## Consequences

### Positive
- Finished siblings close within one patrol of reporting.
- Every close is still backed by a cross-checked report in `brief closed`,
  with a resume command.
- The Collab group and `sib list` show only live relationships.

### Negative
- A session can be closed while the user meant to come back to it. It is
  reopened with the resume command from `brief closed`.
- Idle interactive sessions get a done-request after 6 h, which adds a
  message to their history.

### Neutral
- The running desk keeps the old definition until it restarts (next
  morning brief).

## Implementation Notes

- `bin/sib` (`--report`, `prune_if_dead`, slug check), `tests/sib-spawn.bats`.
- `cmux/brief` (`desk`, `teams()` filter, done-request wording).
- `cmux/sidebars/sessions.js` (`STALE_AFTER` = 6 h, matches `agents/orch.md`).
- `agents/orch.md`, `skills/dispatch/SKILL.md` (0.8.0),
  `skills/collab/SKILL.md` (4.1.0).

## References

- [ADR-003](./2026-11-13-cmux-session-desk-l1.md)
