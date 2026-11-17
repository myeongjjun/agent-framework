# ADR-005: One session, one task — contract by default, direct done-requests, `brief note`

- **Date**: 2026-11-17
- **Status**: Accepted
- **Deciders**: maintainer (with Claude)
- **Supersedes**: none
- **Amends**: [ADR-004](./2026-11-13-session-cleanup-self-report.md)

## Context

Four days after ADR-004 (2026-11-13 → 11-17), no session had been closed
and open sessions had grown from 23 to 24. There were three causes:

1. **The contract was opt-in.** `--report` was added only by the
   `/dispatch` skill. The desk and other sessions mostly ran `sib spawn`
   directly, so almost no sibling received the completion contract.
2. **Done-requests never arrived.** `brief done` sent them as
   `cmux agent message`. That queue drains only when the recipient's turn
   ends, so an idle session never receives the request. All four requests
   the desk sent on 11-16 stayed `queued`, while `brief done` reported
   them as sent (desk proposal P3).
3. **Sessions absorbed side work.** A session listed unrelated findings
   under "remaining", and that list became its next instructions. One
   session ran from its original task into Obsidian cleanup, a research
   reorganisation and an INDEX repair. The user does not want one session
   doing many tasks, and wants each session's memory to cover one thing
   (desk proposal P5).

## Decision

1. **Contract by default.** `sib spawn` appends the completion contract
   unless `--no-report` is passed. A `--worktree` (/collab worker) spawn
   never gets it. `--report` is kept as a no-op for older callers.
2. **Done-requests are typed into the pane.** `brief done` delivers the
   request through `pane-deliver.sh` (the verified input path `sib send`
   uses), which starts a turn even in an idle session. When delivery
   fails, `brief done` says so immediately: the pane is busy, shows an
   approval prompt, is gone, or the submit was not confirmed. The desk
   then checks the screen and the directories itself. If nothing is left,
   it may close with `--verified "no report; …"`. Busy sessions are tried
   again on a later patrol.
3. **One session, one task.**
   - The contract states the session's scope. Findings outside the task
     are neither fixed nor listed as remaining; each is registered with
     `brief note "<one line>"`.
   - `brief note` appends to a file queue (`~/.cache/cmux/brief-notes.jsonl`),
     not to the message queue. It triggers patrol, and `brief patrol --read`
     returns each note as an `ev: note` row.
   - The desk lists each note under `결정 필요` with a recommendation.
     Once approved, the note goes to its own session, never back to the
     session that found it.
   - `/dispatch` adds a `Done when: <observable end point>` line to every
     task.
   - The desk places new work in an existing session only when the work
     is part of that session's current task, not merely the same topic.

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| Keep `--report` opt-in and tighten the orch/local-profile wording | No sib behaviour change | It already failed: agents skip skill text and call sib directly |
| Keep messages and wake the recipient with `cmux agent-hibernation wake` | Uses cmux's own channel | Only applies to hibernated agents; delivery state is still unverified |
| Let sessions fix small findings in place | Fewer sessions | The failure P5 describes: unbounded sessions with mixed memory |

## Consequences

### Positive
- Every sib sibling except /collab workers reports and closes, however it was started.
- A done-request either starts a turn or fails right away, with the reason.
- Side work becomes visible desk items, with one session per item.

### Negative
- Done-requests and the contract arrive as typed input, so they appear
  in the session's own transcript.
- A busy session cannot receive a done-request until a later patrol.
- More, shorter sessions.

### Neutral
- The running desk uses the new definition from its next start.

## Implementation Notes

- `bin/sib` (`report=1` default, `--no-report`, `--worktree` ⇒ off), `tests/sib-spawn.bats` (28 tests).
- `cmux/brief`: `request_close` → `pane-deliver.sh`; `note`; patrol `ev: note`.
- `agents/orch.md`: Placing work, Patrol, completion review fallback.
- `skills/dispatch/SKILL.md` 0.10.0 (`Done when:`), `skills/collab/SKILL.md` 4.1.1.

## References

- [ADR-004](./2026-11-13-session-cleanup-self-report.md)
- Desk proposals P3, P5 (`~/.config/cmux/orch-lessons.md`, local only)
