---
name: agent-scout
description: "Find the agents this machine needs from its work history, or judge agents the user made, then define and install them. Find: a committee of members (each with its own model and method) proposes candidates and a quorum decides. Judge: the user makes the drafts and the committee reviews each one (hire, revise, reject). Either way the result is an agent definition with a role card, instructions, tools, model and done-when. Use for /agent-scout, \"에이전트 발굴\", \"필요한 에이전트 찾아줘\", \"인사 점검\", \"에이전트 만들어줘\", \"에이전트 평가\", \"위원회 평가\"."
disable-model-invocation: true
---

# /agent-scout

pstack's `/automate-me` mines transcripts into one `-mode` skill. This skill mines the same
history into **agents**, and no single miner decides: the agent scouting committee
does. Its members differ in model (Claude and Codex, and models inside Claude) and in approach
(pstack, jobs-to-be-done, portfolio gap, replay, red team, reader test). A judge outside the
committee grades every proposal and every review blind, and members are reviewed and benched from
the records.

The committee works in two directions. **Find** (`convene`, Flow below): members mine the history
and propose. **Judge** (`evaluate`, "Make, then evaluate" below): the user makes the agents and the
committee reviews them. When the user asks for agents for a named area of work, use Judge. The engine is `agent-scout`
(`bin/agent-scout`); this skill is the flow around it. Procedure and verdicts:
`docs/agent-hr-design.md`.

| Piece | Where |
|---|---|
| Members, quorum, judge, review rule, schedule | `~/.config/cmux/agent-committee.md` (seed `cmux/seeds/agent-committee.md`) |
| Member agents | `agents/scout-*.md` (one approach each) |
| Run records | `~/.local/share/cmux/hr/quorum-<date>.{json,md}` (local only) |
| Drafts (source of installed agents) | `~/.local/share/cmux/hr/agents/<role>.md` |
| Roster | `~/.config/cmux/orch-roster.md` |

## Flow

### 0. Read what exists

Run `agent-scout roster` and read the panel config. When the user names a role that was
retired, read its `retire` line before you propose it again.

### 1. Convene the committee

Run `agent-scout convene` inside cmux (window and rule from the config; `--days N` overrides
the window). It builds the evidence packs, starts every enabled member on its own cmux pane
with `sib spawn` (the same control path for Claude and Codex), sends kinds one backer short to
the other members for a vote, has the judge grade every proposal blind, and saves the run. It
takes several minutes; run it in the background and wait for the exit. A member pane that does
not answer stays open for the desk.

A passed kind whose mean judge fit is below `hold_below` is `hold`: the user decides. When the
user lifts it, `agent-scout new ... --user-approved` records the lift in the roster.

You MUST NOT change the quorum result by hand.
When a member errors, report the error and keep the result of the others.

### 2. Show the candidates and let the user pick

Show passed and watch candidates with their backers, then ask with `AskUserQuestion`
(one question, the passed candidates as options). Output example:

```
발굴 위원회 11-23 (3명 중 2명 이상 통과)
 1. [통과] scope-checker  지지 3 (pstack, jobs, portfolio)
 2. [통과] widgetdb-plan-reviewer  지지 2 (pstack, jobs +portfolio 표결)
 3. [관찰] chart-pr-reviewer  지지 1 (portfolio)
```

If the user already named a candidate, skip the question.

### 3. Choose the form

Follow the `/correct` order: a script, lint or test first. When the scouts say `tool` or
`skill`, say so and stop unless the user still wants an agent. An agent is for judgment at a
known moment with narrow tools.

### 4. Draft the definition

Run `agent-scout new <role> --from <n> --area <area>`. It writes the draft with the role
card, the scouts' evidence and quotes, and `TODO` marks. Then fill every `TODO`:

- Read the evidence lines (`agent-scout show <n>`, the transcripts they point to) before you
  write. Each rule in the instructions MUST trace to an evidence line or a user statement.
- `description`: what it does, when to call it, what it never does.
- `tools`: the narrowest set. Advise-only agents get `Read, Grep, Glob`.
- `model`: the matching line of `~/.claude/rules/pstack-models.md` when one fits.
- `done_when`: something the desk can check after the fact, not a self-report.
- Keep company names, hosts and session paths in the draft (local); never in this repo.

### 5. Check and install

Run `agent-scout check <role>` until it says `ready`. Then run `agent-scout report <role>` and show
the report to the user: role, metrics, keep/remove rule, evidence (user rule 11-24). Ask with
`AskUserQuestion`, one role per option. Install refuses without `--user-approved` (exit 3), in every area.
You MUST pass `--user-approved` only for a role the user said yes to after reading its report.

### 6. Call it once

Call the new agent on one real past task from its evidence:
`claude -p --agent <role> --no-session-persistence '<task>'`. Show the answer, then record
the use with `agent-scout log <role> ok|miss|corrected --ref <task>`.
On a verdict day, run `agent-scout measure <role> --judge --write` once per role. It prints uses, ok,
corrected, repeat and asked with their sources and adds the verdict line (docs/agent-hr-design.md 5.3-5.5).
A wrong roster line MUST be cancelled with a `void` line, never edited.
The desk, the area lead and the judge have contracts too: `agent-scout measure desk|lead:A|judge`
prints their numbers (docs/agent-hr-design.md 12). Their verdict line is the user's to write.
- You MUST NOT pass `--by user` unless the user said the verdict in this pane.
- When a draft would replace a member, you MUST run `agent-scout evaluate <draft> --replacing <member>`.

### 7. Review the members

Run `agent-scout review`. It judges each member from the records, never from the member's
report, and benches a member under the line by the config rule. When the user turns down a
passed candidate, record it first with `agent-scout reject <n> --why '<words>'`. When a member
is benched, propose a replacement member (another approach or model) as a candidate.

### 8. Report

Report what each member proposed, what the quorum passed, the judge's grades, the review
verdicts, and what was drafted, installed and called. Output example:

```
위원별 제안: pstack(claude:opus) 3 · jobs(codex:astra) 2 · portfolio(claude:opus) 2
쿼럼 통과: doc-scope-checker(3), widgetdb-plan-reviewer(2)
설치: doc-scope-checker → ~/.claude/agents/ (수습 7일, 판정 11-30)
초안만: widgetdb-plan-reviewer (먼저 묻는 영역)
```

## Make, then evaluate

Use this flow when the user asks for agents (by area or by name) instead of a meeting.

1. **Mine the user's own work first.** Read the area's sessions, corrections and briefs
   (`agent-scout scan`, the transcripts) and list the jobs the user did by hand. Each draft
   MUST serve one job the user did 2 or more times.
2. **Ask before drafting in an ask-first area.** Show the role list with one line of evidence
   each, then ask with `AskUserQuestion`. Draft only the roles the user picks.
3. **Draft.** Run `agent-scout new <role> --by-user --title '<one line>' --kind <kind> --area <A>`
   (add `--layer`/`--home`), then fill every `TODO` from the evidence as in step 4 of the
   find flow. Each rule MUST trace to an evidence line or a user statement.
4. **Evaluate.** Run `agent-scout evaluate <role>...` inside cmux, all drafts in one call. Every
   member with `evaluate` in its rounds reviews every draft; the judge grades each review's
   grounding blind. Run it in the background and wait for the exit.
5. **Revise.** For `revise`, apply the fixes the members agree on, then evaluate again. For
   `reject`, show the reasons and drop the draft unless the user keeps it.
6. **Show and ask.** Show each verdict with the members' one-line reasons, and the
   `agent-scout report <role>` of each draft you propose to install. Ask before every install,
   even after `approve`.
7. **Install** as in step 5 of the find flow. `install` refuses a made draft with no `approve`.
   You MUST pass `--user-approved` only after the user's own answer.

Output example:

```
위원회 평가 eval-11-24-1 (위원 6명, 승인 hire 4)
 widgetdb-claim-checker approve  hire 5 · revise 1   — replay: 3개 중 2개 세션에서 교정을 막음
 widgetdb-values-rev   revise   hire 2 · revise 3   — redteam: 도구가 넓음, craft: 호출 시점이 모호
```

## Changing the committee

The committee is config, not code. To add a member, make its agent (this flow can make it) and
add a row; to drop one, set `status` to `off`. Keep members different in model and approach.
The `rounds` column says which meetings a member sits in (`propose`, `evaluate`, or both).
Members are roles too: every meeting adds a `scan` line per member to the roster, and
`agent-scout review` applies the review rule.

## Watching a meeting

`agent-scout board` prints the meeting running now (members, panes, answers, judge), the
latest quorum and evaluation results, and the drafts waiting for the user, in Korean.
`--watch` refreshes it; `--toggle` opens it in a split beside the caller and closes it on the next call.
The board is read-only: it never starts, kills or answers anything.

## When the committee meets

The desk runs `agent-scout due` each morning. When it exits 0, the desk places one session in
the agent-tooling area that runs this skill (schedule `every` in the config, 14 days by default).

## Guardrails

- A candidate seen by one scout only is a watch item, not a role.
- An agent MUST NOT get tools wider than its area's permission table allows.
- Push, PR, tickets and messages to other people stay with the user, whatever the card says.
