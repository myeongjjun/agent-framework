# cmux session completion report (L1)

This rule reaches every Claude Code and Codex session, however it was
started: by `sib spawn`, by the user in a cmux pane, or with no task at all.

## When it applies

- It applies only inside cmux, when the environment has `CMUX_PANEL_ID` set.
  Check with `echo "${CMUX_PANEL_ID:-none}"` before you report; if it is
  `none`, ignore this rule.
- The desk itself (the `orch` agent) follows its own definition, not this rule.
- A `/collab` worker (git branch `sib/<slug>` in its own worktree) reports to
  the session that spawned it, not to the desk.

## What to do

- The session MUST report when its task is done or the user asks to finish.
- "Finish" includes plain phrases such as "끝내자", "마무리해", "여기까지",
  "닫아도 돼", "done", "wrap up". A session with no task reports what it did.
- Report once and stay open:
  1. Run `git status --short` and `git log -3 --oneline` in every directory
     you edited (skip this when you edited nothing).
  2. Send `brief report "done-report: ready|not-ready ..."` with one line each:
     did / artifacts (absolute paths, commits, links) / uncommitted · unpushed /
     running (background jobs, pending questions) / remaining (what is left of
     this task, or none).
  3. Use `not-ready` when anything the user asked for is left undone.
- `brief report` finds the desk at send time and keeps the report even when no
  desk is open. Only if the command is missing or errors, print the same report
  in this pane instead.
- A session MUST NOT close its own pane: the desk checks the report against
  reality and closes it.
- Findings outside the task are not fixed and not listed as remaining: register
  each with `brief note "<one line: what and where>"`.
