# Agent Team Examples

## Example 1: Research Team (Agent Team Mode)

### Architecture: Fan-out/Fan-in
### Execution Mode: Agent Team

```
[Leader/Orchestrator]
    +-- TeamCreate(research-team)
    +-- TaskCreate(4 investigation tasks)
    +-- Members self-coordinate (SendMessage)
    +-- Read results
    +-- Generate synthesis report
```

### Agent Composition

| Member | Agent Type | Role | Output |
|--------|-----------|------|--------|
| official-researcher | general-purpose | Official docs/blogs | research_official.md |
| media-researcher | general-purpose | Media/investment | research_media.md |
| community-researcher | general-purpose | Community/SNS | research_community.md |
| background-researcher | general-purpose | Background/competitors | research_background.md |
| (leader = orchestrator) | -- | Synthesis report | final_report.md |

> All researchers use `general-purpose` built-in type but must have `.claude/agents/{name}.md` files defining role, investigation scope, and team communication protocol.

### Team Communication Pattern

```
official ---SendMessage---> background  (share official announcements)
media ------SendMessage---> background  (share investment/M&A info)
community --SendMessage---> media       (community reactions about media coverage)
all members --TaskUpdate--> shared list  (progress updates)
leader <----- idle notify -- completed members (automatic)
```

### Orchestrator Workflow

```
Phase 1: Preparation -- analyze user input, create _workspace/
Phase 2: TeamCreate + TaskCreate (4 members, 4 tasks)
Phase 3: Members investigate independently, share discoveries via SendMessage
Phase 4: Leader reads 4 outputs, generates synthesis (conflicting data: attribute sources, keep both)
Phase 5: Cleanup -- dissolve team, preserve _workspace/
```

---

## Example 2: SF Novel Writing Team (Agent Team Mode)

### Architecture: Pipeline + Fan-out
### Execution Mode: Agent Team (with team restructuring)

```
Phase 1 (parallel -- team): worldbuilder + character-designer + plot-architect
  -> SendMessage for cross-consistency
Phase 2 (sequential -- sub-agent): prose-stylist writes draft
Phase 3 (parallel -- new team): science-consultant + continuity-manager review
Phase 4 (sequential -- sub-agent): prose-stylist applies review fixes
```

### Agent Composition

| Member | Agent Type | Role | Skills |
|--------|-----------|------|--------|
| worldbuilder | custom | World setting | world-setting |
| character-designer | custom | Character design | character-profile |
| plot-architect | custom | Plot structure | outline |
| prose-stylist | custom | Writing + editing | write-scene, review-chapter |
| science-consultant | custom | Scientific verification | science-check |
| continuity-manager | custom | Consistency verification | consistency-check |

### Team Restructuring Flow

Phase 1 and Phase 3 use different teams. Since only one team can be active per session:

1. Phase 1: `TeamCreate("creative-team", [worldbuilder, character-designer, plot-architect])`
2. Phase 1 complete: save outputs to `_workspace/01_*.md`, dissolve team
3. Phase 2: call `prose-stylist` as sub-agent (solo work, no team needed)
4. Phase 3: `TeamCreate("review-team", [science-consultant, continuity-manager])`
5. Phase 3 complete: dissolve team
6. Phase 4: call `prose-stylist` as sub-agent again with review feedback

### Agent Definition Excerpt: `worldbuilder.md`

```markdown
---
name: worldbuilder
description: "SF world setting specialist. Designs physics, social structures, technology levels, and history."
---

# Worldbuilder -- SF World Setting Specialist

You are an SF world-setting specialist. Build scientifically grounded yet imaginative foundations for stories.

## Core Responsibilities
1. Define physical laws and technology levels
2. Design social structures, political systems, economic models
3. Establish historical context and current conflict structures

## Working Principles
- Internal consistency above all -- no contradictions between settings
- "What if this technology existed?" -- trace cascading societal effects
- World serves the story -- avoid excessive detail that blocks the plot

## Input/Output Protocol
- Input: user's world concept, genre requirements
- Output: `_workspace/01_worldbuilder_setting.md`

## Team Communication Protocol
- Send to character-designer: social structures, class systems, occupations
- Send to plot-architect: major world conflicts, crisis elements
- Receive from science-consultant: scientific error feedback -> revise settings
- Broadcast to all on major world changes

## Error Handling
- Vague concept: propose 3 directions and ask for selection
- Scientific error found: present alternatives alongside the correction
```

---

## Example 3: Code Review Team (Agent Team Mode)

### Architecture: Fan-out/Fan-in + Discussion
### Execution Mode: Agent Team

```
[Leader] -> TeamCreate(review-team)
    +-- security-reviewer: vulnerability scanning
    +-- performance-reviewer: performance impact analysis
    +-- test-reviewer: test coverage verification
    -> reviewers share findings (SendMessage)
    -> leader synthesizes
```

### Team Communication Pattern

```
security ---SendMessage---> performance  ("SQL injection possible here, check perf angle too")
performance --SendMessage--> test        ("N+1 query found, any test covering this?")
test --------SendMessage---> security    ("Auth module untested, priority from security perspective?")
```

Key: reviewers communicate **directly without routing through the leader**, catching cross-domain issues faster.

### Agent Composition

| Member | Role | Focus Area |
|--------|------|------------|
| security-reviewer | Vulnerability scanning | Injection, auth gaps, secrets exposure |
| performance-reviewer | Performance analysis | N+1 queries, memory leaks, algorithmic complexity |
| test-reviewer | Test coverage | Missing tests, edge cases, assertion quality |

---

## Example 4: Code Migration Team (Agent Team -- Supervisor Pattern)

### Architecture: Supervisor
### Execution Mode: Agent Team

```
[supervisor/leader] -> analyze file list -> batch assignment
    +-> [migrator-1] (batch A)
    +-> [migrator-2] (batch B)
    +-> [migrator-3] (batch C)
    <- TaskUpdate received -> assign more batches or reassign
```

### Dynamic Dispatch Logic

1. Collect target file list
2. Estimate complexity (file size, import count, dependencies)
3. `TaskCreate` with file batches as tasks (include dependency info)
4. Workers self-claim tasks from shared list
5. On `TaskUpdate` completion:
   - Success: worker claims next available task
   - Failure: leader investigates via `SendMessage`, reassigns or assists
6. All tasks complete: leader runs integration tests

**Difference from fan-out:** Work is not pre-assigned -- it is **dynamically claimed at runtime**. The shared task list's claim mechanism makes supervisor pattern natural in team mode.

### Error Handling

- Worker fails on a file: leader sends guidance via `SendMessage`, worker retries once
- Worker repeatedly fails: reassign batch to another worker
- All workers done but integration tests fail: leader identifies affected files, creates new tasks for fix-up

---

## Example 5: Webtoon Production (Sub-agent Mode)

### Architecture: Producer-Reviewer
### Execution Mode: Sub-agents

> Only 2 agents with pure result handoff (no inter-communication needed), so sub-agents are appropriate.

```
Phase 1: Agent(webtoon-artist) -> panel generation
Phase 2: Agent(webtoon-reviewer) -> inspection
Phase 3: Agent(webtoon-artist) -> regenerate problem panels (max 2 retries)
```

### Agent Composition

| Agent | subagent_type | Role | Skills |
|-------|--------------|------|--------|
| webtoon-artist | custom | Panel image generation | generate-webtoon |
| webtoon-reviewer | custom | Quality inspection | review-webtoon |

### Retry Policy

- REDO panels: artist regenerates with specific correction instructions
- Max 2 retry loops, then force-PASS
- If 50%+ panels are REDO: suggest user revise the prompt

---

## Output Pattern Summary

### Agent Definition Files
Location: `project/.claude/agents/{agent-name}.md`
Required sections: Core Responsibilities, Working Principles, Input/Output Protocol, Error Handling, Collaboration
Team mode addition: **Team Communication Protocol** (message targets, task claim scope)

### Skill Files
Location: `project/.claude/skills/{skill-name}/SKILL.md`
Structure: SKILL.md + optional scripts/, references/, assets/

### Orchestrator Skill
A top-level skill coordinating the entire team. Must include: execution mode, agent composition table, phase workflow, data flow, error handling, test scenarios.
Template: `references/orchestrator-template.md`
