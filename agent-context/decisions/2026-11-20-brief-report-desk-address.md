# ADR-007: Sessions reach the desk with `brief report`, not a panel id

- **Date**: 2026-11-20
- **Status**: Accepted
- **Deciders**: maintainer (with Claude)
- **Supersedes**: none
- **Amends**: [ADR-004](./2026-11-13-session-cleanup-self-report.md)

## Context

The desk (orch) starts as a new session every morning, so its panel id
changes daily (11-16 `DADA1F7D`, 11-17 `15488AEE`, 11-18 `393AE128`).
ADR-004 had sessions send their `done-report:` to the desk's panel id:

- `brief done` typed a done-request whose reply address was the desk
  panel id, written into the text. One request typed on 11-16 was
  still in a pane's input box on 11-18, pointing at a desk that had
  closed. Sending to it fails with `not_found`. The session then prints
  the report in its own pane, where nobody reads it.
- The sib contract resolved the address at send time
  (`cmux agent message "$(brief desk)"`). But when no desk was open,
  `brief desk` exited 1 and the report was lost the same way.
- `cmux agent message --from` defaults to the sending workspace's title.
  Several sib sessions share one workspace, so their reports all showed
  that workspace's name (e.g. `sib-agent-framework-standby`, or another
  task's title) instead of the session's own.

## Decision

1. **`brief report <text|->`** is how a session reports to the desk. It
   looks up the desk when it sends. It names the sender with the
   session's title (`--from`) and ends the message with
   `— from: <title> (panel <id>)`.
2. **Reports are kept until the desk has read them.** Each report is
   appended to `~/.cache/cmux/brief-reports.jsonl` before anything else.
   `brief patrol --read` then:
   - drops a report once the desk has read its message;
   - holds a report whose message is still queued for the current desk;
   - emits every other report as an `ev: report` row. These are reports
     sent when no desk was open, reports whose send was refused, and
     reports sent to a desk that closed before reading them.

   The morning brief runs `brief patrol --read` first, so the next desk
   picks up whatever the previous one missed. Unsent reports also count
   toward the `patrol <n>` wake signal.
3. **No panel id in the text.** The done-request and sib's completion
   contract both say ``brief report "<reply>"``.
4. **The desk identifies a reporter by the panel id in the trailer**,
   not by the sender name.

`brief desk` stays for compatibility.

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| A. Write `"$(brief desk)"` into the done-request instead of the id | One-line change | Fixes only the stale id; reports with no desk open are still lost; sender name still wrong |
| B. Address the desk by workspace title prefix (`"☀ Desk"`) | cmux resolves it; works today | Ambiguous if two desk workspaces exist or other panes share the desk workspace; reports with no desk open still lost; sender name still wrong |
| C. File mailbox only, desk reads it on patrol | Survives any desk change | No immediate wake; reports wait until the next patrol |

## Consequences

### Positive
- The desk can change every day without anything changing in the
  sessions or in text already typed into their panes.
- A report is not lost when no desk is open or the desk closes before
  reading it.
- Reports show the session's own title and panel.

### Negative
- One more state file (`brief-reports.jsonl`).
- A report whose message is older than the last 200 inbox entries
  cannot be matched to its message, so it is emitted once more (it may
  reach the desk twice).

### Neutral
- A desk that is already running follows the new `agents/orch.md` only
  after it restarts (next morning brief).

## Implementation Notes

- `cmux/brief`: `report`, `patrol_lock`, `load_reports`, `me_session`,
  `report` rows in `patrol --read`, done-request wording.
- `bin/sib`: completion contract.
- `agents/orch.md`: `report` row; identify the reporter by panel.
- `tests/brief-report.bats`.

## References

- [ADR-004](./2026-11-13-session-cleanup-self-report.md)
- [ADR-005](./2026-11-17-one-session-one-task.md)
