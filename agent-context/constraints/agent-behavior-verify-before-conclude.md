# Constraint: Verify Before Conclude

- **Category**: agent-behavior
- **Severity**: high
- **Created**: 2026-04-02
- **Last Verified**: 2026-04-02

## Description

When performing analysis, comparison, or decision-making tasks, the agent must present both quantitative evidence and qualitative reasoning before stating a conclusion. Do not skip verification steps or jump to conclusions without supporting data.

## Scope

- **Applies to**: All analysis, comparison, evaluation, and architectural decision tasks
- **Excludes**: Simple command execution (file creation, git operations, deployments), direct user instructions ("do X"), single-step tool calls

## Rationale

`/observe` analysis on 2026-04-02 found a 10.5% correction rate, with the primary pattern being "premature conclusion without evidence." Users had to request re-analysis with proper quantitative/qualitative backing. This constraint codifies the expectation that analysis tasks require supporting evidence before conclusions.

Evidence from traces:
- "아니 좀더 정량적, 정성적 2개 기반으로 자세히 해야지 너무 빠른 의사결정이야"
- "다시 정량적, 정성적인 분석해보자"

## Verification

Before presenting a conclusion in analysis tasks, check:
- [ ] Quantitative evidence provided (metrics, counts, comparisons, measurements)
- [ ] Qualitative reasoning provided (trade-offs, context, implications)
- [ ] Alternatives considered (at least briefly, when choosing between options)
- [ ] Evidence precedes conclusion in the response (not appended after)

## Exceptions

- User explicitly requests a quick/short answer ("간단히", "한 줄로", "빠르게")
- Task is a simple lookup or factual question with a single correct answer
- User has already provided the analysis and is asking for execution only

## References

- [/observe report 2026-04-02](~/.claude/logs/proposals/observe-2026-04-02.md) — Proposal #3
