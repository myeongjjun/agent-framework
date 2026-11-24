# Constraint: L1 Holds Environment-Neutral Content Only

- **Category**: architecture
- **Severity**: High
- **Status**: Active
- **Scope**: `agent-framework` (L1, public) — every tracked file and every commit message
- **Created**: 2026-11-24
- **Last Verified**: 2026-11-24

## Description

L1 is the layer every user's machine shares, so it holds only abstract,
environment-neutral content: procedures, principles, verdict rules, and
generic examples (fake names such as `widgetdb`, "an ask-first work area").
Anything true only on one machine or in one job belongs to a lower layer:
the L2 persona repo, an L3 domain pack, or the machine's local profile
(`~/.config/cmux/*`). Where the lower layer keeps its evidence is the lower
layer's own rule; L1 does not name it.

Knowledge that must last is kept as code and tests (behaviour) and as ACP
decisions and constraints (rules). Commit messages and long design notes
are not where it lives.

Agents follow the same layers. L1 defines agents every machine can use (the desk, the committee, its
members); an agent for one job or one environment is defined in L2 or L3, and L1 reaches it only through
the local profile.

The test for one sentence: would it still be true and useful on another
user's machine? If not, it belongs below L1.

- **R1** L1 files MUST NOT contain work domains, real area names, or lower-layer agent, skill or repo names.
- **R2** L1 files MUST NOT contain numbers, cases or user quotes taken from one machine's logs.
- **R3** A commit message in L1 MUST NOT carry environment-specific detail.
- **R4** When L1 needs a concrete lower-layer name, L1 MUST read it from the local profile.
- **R5** An L1 example SHOULD use a fake name or a generic role, unless the rule concerns that public technology.
- **R6** Lasting knowledge SHOULD live in code, tests or ACP records, except a short commit summary.
- **R7** L1 MAY state that lower layers exist.
- **R8** L1 MAY suggest creating a missing lower-layer agent through `/agent-scout`.

## Scope

- **Applies to**: `**` in this repo, in every commit reachable from `main` (history counts, not only the tip), and commit messages on `main`
- **Excludes**: none. Test fixtures follow R5: fake names, or names that state a rule's own example.

## Rationale

The 2026-11-24 push review of 65 unpushed commits found one machine's work
history in two design docs, an internal session name in a code comment, a
hard-coded alias in `cmux/brief-lead`, and lower-layer agent names in
`agents/orch.md`. The range was rewritten before the push. The layering
table in `AGENTS.md` said what each layer *adds* but gave no test for what
L1 must *not* hold, so each session either asked the user again or mixed
layers without asking. The user ruled that L1 keeps abstract content, and
that lasting knowledge lives in code and ACP records rather than commit
messages.

## Verification

Manual review checklist (before every push — see `git-workflow`):
- [ ] `git log -p origin/main..HEAD`: no work domain, real lower-layer name, local number or work quote (R1–R3).
- [ ] `agents/*.md` and code name lower-layer agents only through the local profile (R4).
- [ ] New examples use fake names or generic roles (R5).

## Trace

| ID | Check |
|---|---|
| R1 | manual: pre-push review of `git log -p origin/main..HEAD` |
| R2 | manual: pre-push review of `git log -p origin/main..HEAD` |
| R3 | manual: pre-push review of `git log --format=%B origin/main..HEAD` |
| R4 | manual: `agents/orch.md` names agents only via the local profile's `Agent calls` |
| R5 | manual: review of new examples and fixtures |
| R6 | manual: review of commit messages against the ACP records |
| R7 | manual: permission, nothing to check |
| R8 | manual: permission, nothing to check |

## Exceptions

- Public product and tool names used as such (Claude, Codex, cmux, pstack, GitHub) are not environment-specific.
- A rule about one public technology names that technology (see R5), with no local detail attached.
