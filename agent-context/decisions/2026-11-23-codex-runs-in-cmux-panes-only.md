# ADR-008: Codex runs only in cmux panes — no headless `codex exec`

- **Date**: 2026-11-23
- **Status**: Accepted
- **Deciders**: user (ruling 2026-11-23 21:17, relayed by the desk), recorded by Claude
- **Supersedes**: none in L1. For L1 it replaces the "`codex exec` fallback" that older L2 decisions kept.

## Context

The `codex` skill had two modes: Mode A spawned Codex in a cmux pane
(`sib spawn --codex`); Mode B ran `codex exec` headless when no pane was
available, and agents also used it for one-shot jobs.

A headless run has no pane. The desk and the user cannot see it, answer
it or stop it. On 2026-11-23 a session started `codex exec` in the
background without closing stdin; it sat blocked on
`Reading additional input from stdin...` for 10 minutes while the session
told the user Codex was working.

The user ruled: "codex exec 방식으로 하는거 없애. 이제는 무조건 cmux 위에서 동작하게 해 —
불필요하게 codex agent 제어를 하게 해서 제어 불능 상태를 막기 위함."

## Decision

- Codex MUST run in a cmux pane, started with `sib spawn --codex`.
- An agent MUST NOT start `codex exec` or any other headless Codex run.
- Outside cmux, the agent MUST stop and ask the user to run the task in cmux.
- A one-shot job also gets a pane: the whole brief goes in the prompt, the agent reads the pane, then closes it with `sib kill`.
- `skills/codex/SKILL.md` 4.0.0 removes Mode B and states this rule.
- `hooks/general/guard-codex-exec.sh` (PreToolUse, matcher `Bash`, for Claude Code and Codex) blocks `codex exec`, `codex e` and `codex review` with exit 2 and points to `sib spawn --codex`. No opt-out. `tests/guard-codex-exec.bats` checks what it blocks and what it lets through.
- The one script that ran Codex headless, dotfiles `bin/xreview`, now saves the diff to a file and spawns a Codex pane with `sib spawn --codex`.

Observation is not affected: `brief tree` still shows a headless run that
something else started, so a stray one is visible.

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| Keep `codex exec`, but require `< /dev/null` and a timeout | Fixes the one stdin hang | Still invisible and unsteerable; the user asked for control, not a patch |
| Keep `codex exec` only outside cmux (CI, scripts) | Works headless | Agents drift back to it inside cmux; no current headless use case in L1 |
| Pane only (chosen) | Every Codex run is visible, answerable and killable by the desk and the user | Needs cmux; a one-shot job costs a pane and a `sib kill` |

## Consequences

### Positive
- Every Codex run shows up as a pane the desk patrols and the user can type into.
- A blocked or runaway Codex is seen and stopped, not discovered later.

### Negative
- Codex cannot be used where cmux is not running.
- One-shot jobs leave a pane to close after the result is read.

### Neutral
- Reasoning effort comes from `~/.codex/config.toml`; a pane run cannot override it per call.
- L2 repositories that still describe `codex exec` as a fallback need their own follow-up.

## References

- `skills/codex/SKILL.md` (4.0.0)
- `hooks/general/guard-codex-exec.sh`, `tests/guard-codex-exec.bats`
- [ADR-001](./2026-06-17-sib-workspace-targeting-and-dispatch-collab-l1-promotion.md) — sib placement used by `sib spawn --codex`
