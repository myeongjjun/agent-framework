# Constraint: One Agent Control Path

- **Category**: architecture
- **Severity**: High
- **Status**: Active
- **Scope**: All personas, every model (Codex, Claude, later ones), every use (solo, collab, committee)
- **Created**: 2026-11-23
- **Last Verified**: 2026-11-23

## Description

Agents on this machine are controlled in exactly one way. "Control" is the
whole loop around an agent: start it, see it, send it work, stop it, and
receive its report. The model (Codex or Claude) and the use (one worker,
a `/collab` pair, a committee) do not get their own way. They only differ
in what is sent through the one way.

Today the one way is `sib` on cmux panes: `sib spawn` (start),
`brief sessions` / `brief tree` (see), `brief send` (send work),
`sib kill` / `brief done` (stop), and `brief report` (report).
The rule outlives the tool: if cmux or `sib` is replaced, the replacement
becomes the one way, and the old way goes away with it.

- **R1** An agent MUST start another agent only through the one control path.
- **R2** The control path MUST give start, watch, message, stop and report for every agent it starts.
- **R3** The control path MUST NOT differ by model, vendor or use.
- **R4** An agent MUST NOT add a second control path beside the current one.
- **R5** When the control tool is replaced, all five control steps MUST move to the new tool together.
- **R6** When a task cannot use the control path, the agent MUST stop and ask the user.
- **R7** A tool-less one-shot model call MAY run outside the control path under the Exceptions conditions.
- **R8** A subagent inside a session MAY run when that session starts, shows and stops it.
- **R10** A sandboxed measurement session MAY run headless under the Exceptions conditions.

The user ruled R7, R8 and R10 as the only three exceptions (2026-11-23):
"3개 예외로해 그럼". The reasoning for each is in
[`docs/agent-control-one-path.md`](../../docs/agent-control-one-path.md) §4.

## Scope

- **Applies to**: every agent that starts, steers or stops another agent; every
  script, skill, hook, launchd job or tool that does so on the user's behalf
  (`bin/`, `cmux/`, `skills/`, `agents/`, L2/L3 scripts such as the guard loop).
- **Excludes**: a person typing a command by hand in a terminal; a non-agent
  process (store, daemon, renderer) that never runs a model.

## Rationale

The user's ruling (2026-11-23 21:20): "codex, claude 동일한 구조 1개로 제어하게 하는거 맞지?
collab 도 결국 두 에이전트를 어떻게 제어하냐의 차이지 제어방식에 대해서는 여러 방식을 둘
필요없어. 가장 좋은 방식 1가지를 유지해야 품질이 올라와. 방식 자체를 아예 다르게 하더라도,
cmux 를 대체하더라도 이 원칙을 유지해."

Each extra control path is a place the desk and the user cannot see. On
2026-11-23 a headless `codex exec` sat blocked on stdin for 10 minutes while
its session said Codex was working, and a Codex prompt overwrote a pane title
so the office showed an "agent outside cmux". Every fix to one path (delivery
checks, report rules, close guards) also had to be redone or was missing on
the others. One path means one place to fix and one place to look.

[ADR-008](../decisions/2026-11-23-codex-runs-in-cmux-panes-only.md) applies
this rule to Codex. This constraint is the general rule; ADR-008 is one case.

## Verification

```bash
# Headless agents started outside the control path (exceptions must match R7 or R10)
grep -rnIE 'codex exec|claude -p|claude --print' bin cmux skills agents scripts
# Live: every agent process should belong to a pane `brief sessions` lists
ps -axo pid,command | grep -E 'claude -p|codex exec' | grep -v grep
```

Manual review checklist:
- [ ] A new feature that starts an agent uses `sib spawn`, not its own launcher.
- [ ] A `claude -p` call has `--tools ""`, no session persistence, a timeout and an owned process tree.
- [ ] A Codex and a Claude member of the same group start the same way.

## Trace

| ID | Check |
|---|---|
| R1 | manual: grep above; inventory in `docs/agent-control-one-path.md` |
| R2 | manual: each path row in the inventory names its start/watch/message/stop/report |
| R3 | manual: same-group members (committee, `/collab`) start through the same command |
| R4 | manual: review of any new launcher, skill or script that runs a model |
| R5 | manual: migration plan when the control tool changes |
| R6 | manual: `hooks/general/guard-codex-exec.sh` blocks the Codex case; other cases manual |
| R7 | manual: each `claude -p` site meets the Exceptions conditions |
| R8 | manual: subagents are visible in the parent pane and stopped with it |
| R9 | manual: committee and `/collab` members start through the same command |
| R10 | manual: each measurement site runs in the OS sandbox with stub CLIs and a temp workdir |
| R11 | manual: the table in "Review of the exceptions" has a row for every exception |
| R12 | manual: weekly measure (plan step 1a) reports a fired trigger as a `brief note` |
| R13 | manual: decision log in `docs/agent-control-one-path.md` §7 shows the pause and the ruling |

## Exceptions

- **One-shot model call (R7)**: allowed only when all hold — no tools
  (`--tools ""`), stdin closed, no session persistence, a timeout, the caller
  owns and reaps the process tree, and the result is data the caller checks.
  Such a call is a function call, not an agent. Any call with tools, an
  edit permission or more than one turn is an agent and follows R1.
- **In-session subagent (R8)**: Claude Code subagents and workflows started by
  a session live inside that session's pane; the session sees, stops and
  reports them.
- **R9** A group of agents MUST NOT start one model as a subagent and another through `sib`.
- **Measurement session (R10)**: a headless session whose purpose is to be
  measured, not to do work (today only a lower layer's classifier probe, which probes
  the auto mode classifier). Allowed only when all hold — OS sandbox with
  writes limited to a temp dir and no network, every remote-capable CLI
  replaced by an echo stub, only candidate settings loaded, a timeout, and the
  caller reaps the process tree. A pane would mix in the user's settings and
  hooks and spoil the measurement.
- **Never**: any other headless agent with tools, a second orchestrator (for
  example Orca workers, removed 2026-11-23) or a per-model launcher.

## Review of the exceptions

The three exceptions are a decision, not a fixed truth. Like earlier
decisions in this area, they can change when they cause trouble. Each one is
measured and judged on a date (user, 2026-11-23: "이 결정 역시 예전처럼 문제가
되면 바뀔 수 있고 측정하고 평가해야 함").

- **R11** Each exception MUST have a measure, a revoke trigger and a review date.
- **R12** When a revoke trigger fires, the agent MUST report it with `brief note`.
- **R13** When a revoke trigger fires, that exception MUST stop until the user rules again.

| Exception | Measure (per week) | Revoke trigger |
|---|---|---|
| R7 one-shot call | calls, timeouts, failures; model processes left alive after the caller exits; call sites that miss a condition | 1 process left alive or 1 hang past its timeout; or 1 site found with tools |
| R8 subagent | times the user or desk had to stop a session because of its subagents; subagent work the desk missed when it judged or closed a session | 2 such cases in 7 days; or 1 mixed-model group (R9) |
| R10 measurement | probe runs; writes outside the temp dir; network attempts; verdicts that differ on a re-run of the same input | 1 write outside the temp dir or 1 network attempt |

Review date: 2026-11-30, together with the area A trial. Then every 4 weeks.
At review: no trigger and no reversal → keep; a trigger fired → the user
chooses between fixing the conditions and removing the exception.
Each review adds one line to the decision log in `docs/agent-control-one-path.md` §7.

## Examples

### Allowed

```bash
sib spawn review-codex --codex -- "<brief>"     # a Codex worker
sib spawn review-claude -- "<brief>"            # a Claude worker, same path
claude -p --tools "" --no-session-persistence --model opus < prompt.md  # R7 one-shot call, with timeout
```

### Not Allowed

```bash
codex exec "<brief>"                              # headless Codex
claude -p --agent scout-volume "<brief>"          # headless agent with tools
claude -p --permission-mode acceptEdits "<brief>" # headless agent that edits files
orca ... dispatch worker                          # second orchestrator
```
