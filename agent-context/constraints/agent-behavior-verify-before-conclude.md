# Constraint: Verify Before Conclude

- **Status**: Active
- **Category**: agent-behavior
- **Severity**: high
- **Created**: 2026-04-02
- **Last Verified**: 2026-11-23

## Description

- **R1** When the agent analyzes, compares or decides, it MUST give quantitative evidence and qualitative reasoning before the conclusion.
- **R2** The agent MUST NOT skip a verification step.
- **R3** The agent MUST NOT state a conclusion without supporting data.

## Scope

- **Applies to**: All analysis, comparison, evaluation, and architectural decision tasks
- **Excludes**: Simple command execution (file creation, git operations, deployments), direct user instructions ("do X"), single-step tool calls

## Rationale

Transcript analysis found a recurring pattern of "premature conclusion without evidence": the agent would state a verdict before presenting the quantitative and qualitative basis, forcing the user to ask for re-analysis. This constraint codifies the expectation that analysis tasks show their work before the conclusion.

## Verification

Before presenting a conclusion in analysis tasks, check:
- [ ] Quantitative evidence provided (metrics, counts, comparisons, measurements)
- [ ] Qualitative reasoning provided (trade-offs, context, implications)
- [ ] Alternatives considered (at least briefly, when choosing between options)
- [ ] Evidence precedes conclusion in the response (not appended after)

## Trace

| ID | Check |
|---|---|
| R1 | manual: review the analysis output |
| R2 | manual: review the analysis output |
| R3 | manual: review the analysis output |

## Exceptions

- User explicitly requests a quick/short answer ("간단히", "한 줄로", "빠르게")
- Task is a simple lookup or factual question with a single correct answer
- User has already provided the analysis and is asking for execution only

## References

- Origin: 2026-04-02 transcript trace-analysis (proposal #3) identified the premature-conclusion pattern.
