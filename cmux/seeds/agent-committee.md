# Agent scouting committee (에이전트 발굴 위원회)

Read by `agent-scout convene` and `agent-scout evaluate`. The committee works in two directions:
it **finds** the agents this machine needs from the work history (convene), and it **judges** agent
drafts the user made (evaluate). It is config, not code: add, drop or switch off a member, change a
member's model, approach, evidence or rounds, the quorum, the evaluate rule, the judge, the review
rule or the schedule — all here.

Members differ on purpose, in **model** (vendor, and model inside a vendor) and in **approach**.
Every member and the judge run on a **top-tier** model only (user rule 11-24): Claude `fable` or
`opus`, Codex `astra`. No lower tier (sonnet, haiku, Codex sol/terra/luna or `default`).
Write the model as a family name, never a version, so a new model version reaches the committee with
no edit: Claude resolves `opus`/`fable` itself, and `agent-scout` runs Codex `astra` as the newest
`gpt-*-astra` listed in `~/.codex/models_cache.json`. When a new top-tier family appears, change
this table, the seed and the roster's `## Committee` line together.
The top tier has three models and the judge holds one of them alone, so members share the other
two and differ mainly by approach.
A member is an agent definition; a new member is a new agent file (make it with `/agent-scout`)
plus one row. Every member and the judge run the same way, whatever the model: a cmux pane started
by `sib spawn` (`--codex` for runner `codex`, `--model` from the row) that reads a task file and
writes its answer to a file. There is no headless path (`claude -p`, `codex exec`).

## Members
| member | runner | agent | model | approach | evidence | status | rounds |
|---|---|---|---|---|---|---|---|
| pstack | claude | scout-pstack | opus | pstack: /automate-me slices, /correct order, /reflect filter | corrections,sessions | on | propose,evaluate |
| jobs | codex | scout-jobs | astra | jobs-to-be-done: what the user hands off and what comes back | decisions,briefs | on | propose,evaluate |
| portfolio | claude | scout-portfolio | opus | portfolio gap: where the hours go vs the roles that exist | sessions,briefs | on | propose,evaluate |
| replay | codex | scout-replay | astra | replay: walk past sessions turn by turn; would the agent have avoided the correction | corrections,sessions | on | evaluate |
| redteam | codex | scout-redteam | astra | red team: overreach, user decisions taken, wrong confidence, rule conflicts | decisions,corrections | on | evaluate |
| craft | claude | scout-craft | opus | reader test: read the definition literally; can a session call it and follow it as written, with no gap filled from outside | briefs | on | evaluate |

Evidence packs (`agent-scout scan`): `sessions` (volume of each kind of work), `briefs` (tasks
handed to new sessions), `corrections` (short user turns that push back), `decisions` (desk
`결정 필요`, area decision logs, asked questions). `status`: `on` or `off`. `rounds`: the meetings
a member sits in — `propose` (convene) and/or `evaluate`; empty means both.

## Quorum
- pass: 2       # distinct members that must back the same kind of work
- vote: on      # a kind one backer short goes to the other members for a yes/no vote from their own evidence
- watch: 1      # support at or above this but below pass: watch list, looked at again at the next meeting
- days: 21      # history window
- slices: 3     # time slices in the sessions pack
- hold_below: 1 # a passed kind with mean judge fit (0-2) below this is held for the user (0 = off)
- exclude: /tmp/|/private/var/   # sessions whose cwd (or path below the history root) matches are left out

## Evaluate
`agent-scout evaluate <draft>...`: every member with `evaluate` in its rounds reviews the drafts with its
own approach and evidence (narrowed to the drafts' kinds) and says hire, revise or reject. The judge
grades each review's grounding blind; a review under `ground_min` is kept in the record but not counted.
`install` refuses a made draft (`new --by-user`) without an `approve`, and any draft whose latest
evaluation is not `approve`. Every install, in every area, waits for the user: `agent-scout report <role>`
shows role, metrics, keep/remove rule and evidence, and `--user-approved` follows the user's yes (rule 11-24).
- approve: 4     # counted `hire` reviews for approve
- reject: 2      # counted `reject` reviews for reject (checked first); anything else is revise
- ground_min: 1  # judge's grounding grade (0-2) a review needs to count

## Judge
- judge: claude:fable   # runner:model outside the committee (a member's runner:model is refused); grades blind
The judge is under contract too (`agent-scout measure judge`): its only record is the holds the user
lifted (`committee | lifted` roster lines). Nothing yet measures whether its grades were right; that is
stated, not guessed. Two lifted holds in 14 days put a judge swap in front of the user.

## Review
Members are judged by `agent-scout review` from the records (never from their own report): pass rate
(proposals the quorum passed), the judge's blind score, hires, probation results, and reversals
(candidates the user turned down with `agent-scout reject`, `corrected` uses and failed probations of
roles they backed, and roles the member said `reject` to that the user put in anyway). `agent-scout
measure <member>` prints the same numbers with their sources. Nobody votes on their own seat: a draft
that would replace a member is evaluated with `evaluate --replacing <member>`, which leaves that member out.
- min_runs: 2          # no verdict before this many meetings
- pass_rate_min: 0.2
- judge_min: 0.5       # mean of the judge's grades: (evidence + fit) / 4 per proposal, grounded / 2 per review
                       # pass_rate applies only to members that sat min_runs propose meetings
- reversed_max: 2
- on_fail: bench       # bench: status → off and a replacement is asked for · warn: roster line only

## Schedule
- every: 14     # days between meetings. The desk runs `agent-scout due` each morning; when due, it places
                # one session in the agent-tooling area that runs `/agent-scout` (meeting, then `agent-scout review`).

## Panes
- root: /private/tmp/agent-scout   # member panes work in folders under here; pick a parent Claude and Codex already trust
Each meeting opens its own cmux workspace for the member panes, so they do not squeeze the caller's
workspace. A pane is closed once its answer is read; a pane that does not answer stays open.

## Layers
Where an installed agent's source goes. The committee itself is L1; the agents it makes belong to
the layer of their work: L1 for company-free roles (public repo), L2 for the persona, L3 for a
domain (the project's `.claude/agents`, active only in that project). `install` refuses L1 when the
card carries ask-first context or matches `private`.
- L1: ~/personal/agent-framework/agents
- L2:              # the persona repo's agents folder, set in the local copy
- private:         # regex of company words that must not reach L1, set in the local copy

## Kinds
One line per kind: `- <kind id>: `<regex>`` on `<cwd> <first prompt>`; first match wins. Unmatched
sessions fall back to `proj:<last folder of cwd>`. Keep company names in the local copy only.

- agent-tooling: `agent-framework|/\.claude|/\.codex|cmux`
- research: `/research\b`
