# agent-framework

> **L1 — agent baseline.** This repo is the policy origin for every persona
> (개인 + 사내 + 도메인) the maintainer operates. Skills, hooks, constraints,
> and AGENTS.md baselines installed here are **enforced** on every machine
> where the maintainer's agents run.

This is **not** a public framework or fork target. It is one person's
multi-persona agent baseline.

## Layering

```
L1  ── this repo  (~/personal/agent-framework)
        Global baseline. Every persona inherits.
        Contents: ACP skills, codex skill, sib, security guards,
                  AGENTS.md base, critical constraints.

L2  ── persona repos
        ~/personal/dotfiles    (개인 페르소나)
        ~/agent-workspace      (사내 페르소나)
        Each persona = one repo, may run on N machines.
        Inherits L1, adds persona-specific overlay.

L3  ── domain packs
        Live inside a project's root (not a separate repo)
        Example: ~/o11y/ch-ops-pack
        Inherits L2 from cwd, adds domain-specific overlay.
```

L1 → L2 → L3 is **single-direction**: lower layers can add but never
delete or modify what higher layers install. If a persona needs to
change L1 behaviour, it goes back to L1 (not a local override).

## What lives here (L1)

| Path | Purpose |
|---|---|
| `AGENTS.md` | Base AGENTS.md every persona starts from. Personas append; never delete. |
| `agent-context/constraints/` | Critical constraints. Active in every persona. |
| `agent-context/decisions/` | ADRs that justify L1 contents. |
| `skills/acp-{constraint,decision,init}` | ACP standard skills. Required by every persona that uses ACP. |
| `skills/codex` | Codex CLI integration. Used in every persona. |
| `bin/sib` | cmux + worktree sibling-agent launcher. Used in every persona. |
| `hooks/general/guard-acp-direct-edit.sh` | Block agent edits to `agent-context/`. Force ACP skill use. |
| `hooks/general/guard-deployed-artifact-edit.sh` | Block agent edits to deployed runtime (~/.claude/skills, ~/.codex/skills, ...). |
| `hooks/general/guard-permission-bypass.sh` | Block agent edits to `~/.claude/settings.json`, `hooks/**/*.sh`, `.claude.json`. |
| `agents/approver.md` | cmux approval-prompt auto-approver agent (daemon). |
| `scripts/install.sh` | Pull L1 contents into `~/.claude/`, `~/.codex/`, `~/.local/bin/`. Atomic, overwrite. |
| `scripts/check-update.sh` | git fetch + detect changes + trigger install. Driven by cron. |
| `scripts/verify.sh` | Drift verify (checksum). Called from SessionStart hook. |

## Install / update flow

```
Maintainer pushes L1 change → github.com/myeongjjun/agent-framework
                                      ↓
On every machine:
   1. cron + SessionStart hook call check-update.sh
   2. check-update.sh: git fetch → diff → if changed, run install.sh
   3. install.sh: atomic pull into ~/.claude/, ~/.codex/, ~/.local/bin/
   4. SessionStart hook calls verify.sh: checksum vs origin → alert on drift
```

L1 changes are **forced** within the next session-start (or cron interval),
whichever comes first.

## ADR / constraint conventions

L1 uses [AWS Well-Architected ADR](https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/establish-a-process-for-architecture-decision-records-adrs.html) status terminology.

| Status | Meaning |
|---|---|
| **Proposed** | Decision drafted, not yet adopted. |
| **Accepted** | Decision adopted and in effect. |
| **Rejected** | Considered but not adopted (kept as record of "why we did NOT do this"). |
| **Deprecated** | No longer recommended. No successor decision needed (just retired). |
| **Superseded** | Replaced by another ADR. Body retained, points at successor. |

Cross-references in ADR frontmatter:

| Field | Meaning |
|---|---|
| `Supersedes: ADR-XXX` | This ADR replaces ADR-XXX. |
| `Superseded by: ADR-YYY` | This ADR was replaced by ADR-YYY. |
| `Amends: ADR-XXX` | This ADR partially amends ADR-XXX (not full supersede). |
| `Amended by: ADR-YYY` | This ADR was partially amended by ADR-YYY. |

Constraints follow the same status set; treat severity (`critical / high /
medium`) as orthogonal to status.

References for the ADR pattern:
- Michael Nygard, *Documenting Architecture Decisions* (2011)
- AWS Well-Architected, *Establish a process for ADRs* (2022) — chosen status set
- MADR (Markdown ADR), <https://adr.github.io/madr/>

## Layering rules

### What goes in L1 (this repo)

A change belongs in L1 if **all** the following hold:

1. The maintainer wants it active on every machine, in every persona.
2. Removing it would create risk (security, compliance, ACP integrity) regardless of persona.
3. It does not depend on persona-specific infrastructure
   (no Jira/Wiki/사내 GHE/ClickHouse references).

Examples of in-scope: permission-bypass guard, ACP skills, sib, codex skill.

Examples of out-of-scope: anything OBSERV-specific, anything that names
a particular Slack/Discord workspace, ClickHouse log-comment guards.

### What goes in L2

L2 = persona overlay. Same rules as L1 but scoped to the persona:
"every machine in this persona, but not other personas".

Examples (사내 페르소나): Jira/Wiki MCP wiring, OBSERV ticket templates,
사내 GHE network constraints, ClickHouse cluster guards.

### What goes in L3

L3 = domain pack inside a project root. Active only when working in
that project tree.

Examples (ch-ops-pack): cluster-specific runbooks, partition-move dashboards,
domain DDL guards.

## Why this is not a fork target

Older versions of this repo positioned themselves as a public fork target
with `FORKING.md`, mirror sync from a downstream workspace, and dual-review
gates on push. Those are **retired**: the repo is now the maintainer's
personal baseline, not a community framework.

If you stumbled into this repo from outside: you can still copy ideas, but
nothing here is being maintained for general adoption.

## Status terminology elsewhere

L2 personas (`agent-workspace`, `dotfiles`) and L3 domain packs (`ch-ops-pack`)
adopt the same status set above. If you see an older ADR using only
`accepted | proposed | deprecated | superseded` (4-state Nygard original),
that's a pre-2026-06-16 record waiting for a sweep — see
`agent-workspace/agent-context/decisions/INDEX.md` "후속 정리" task.
