---
name: harness
description: "하네스를 구성합니다. 전문 에이전트를 정의하며, 해당 에이전트가 사용할 스킬을 생성하는 메타 스킬. (1) '하네스 구성해줘', '하네스 구축해줘' 요청 시, (2) '하네스 설계', '하네스 엔지니어링' 요청 시, (3) 새로운 도메인/프로젝트에 대한 하네스 기반 자동화 체계를 구축할 때, (4) 하네스 구성을 재구성하거나 확장할 때 사용."
---

# Harness -- Agent Team & Skill Architect

A meta-skill that designs agent teams for a given domain/project, defines each agent's role, and creates the skills they use.

> **Disambiguation**: This skill designs agent teams (`.claude/agents/` + `.claude/skills/`). For runtime guardrails and feedback loops, see [ADR-020: Harness Engineering Adoption](../../agent-context/decisions/2026-03-10-harness-engineering-adoption.md).

**Core principles:**
1. Generate agent definitions (`.claude/agents/`) and skills (`.claude/skills/`).
2. **Agent teams are the default execution mode.** Select sub-agents only when inter-agent communication is unnecessary.
3. Every agent must have a definition file -- never inline roles into the Agent tool's prompt parameter alone.

## Workflow

### Phase 1: Domain Analysis

1. Identify the domain/project from the user's request
2. Identify core task types (creation, verification, editing, analysis, etc.)
3. Check existing agents/skills to avoid conflicts and duplication
4. Explore the project codebase -- tech stack, data models, key modules
5. **Detect user proficiency** from conversational cues (terminology, question depth) and calibrate communication accordingly

### Phase 2: Execution Mode & Architecture

This phase makes two decisions in sequence: execution mode, then architecture pattern.

#### 2-1. Execution Mode Selection

**Default is Agent Team.** When 2+ agents collaborate, prefer teams. Team members self-coordinate via `SendMessage` and shared task lists (`TaskCreate`), enabling discovery sharing, conflict resolution, and gap coverage that raise output quality.

Choose Sub-agents only when a single agent suffices or agents need no inter-communication (pure result handoff).

> Decision tree and comparison table: `references/agent-design-patterns.md` "Execution Mode" section.

#### 2-2. Architecture Pattern Selection

Decompose work into specialized areas, then select a pattern:

| Pattern | When to use | Team mode fit |
|---------|-------------|---------------|
| **Pipeline** | Sequential dependencies | Limited (unless parallel sub-phases exist) |
| **Fan-out/Fan-in** | Parallel independent work | Best fit -- always use agent team |
| **Expert Pool** | Situational on-demand selection | Sub-agents preferred |
| **Producer-Reviewer** | Generate then quality-check | Team useful for real-time feedback |
| **Supervisor** | Variable workload, dynamic dispatch | Team's shared task list is a natural fit |
| **Hierarchical Delegation** | Recursive decomposition | Team (1 level) + sub-agents (level 2); keep depth <= 2 |

Composite patterns (e.g., Fan-out + Producer-Reviewer) are common in practice. Details and composite examples in `references/agent-design-patterns.md`.

#### 2-3. Agent Separation Criteria

Evaluate along 4 axes -- expertise, parallelism, context burden, reusability. Full criteria table in `references/agent-design-patterns.md` "Agent Separation" section.

### Phase 3: Agent Definition Generation

**Every agent must be defined as `project/.claude/agents/{name}.md`.** No exceptions, even for built-in types (`general-purpose`, `Explore`, `Plan`). Reasons:
- File-based definitions enable cross-session reuse
- Team communication protocols must be explicit for collaboration quality
- Harness separates "who" (agent) from "how" (skill)

**Model:** All agents use `model: "opus"`. Always specify this parameter when calling the Agent tool.

**Required sections** in each agent definition file:

| Section | Purpose |
|---------|---------|
| Core Responsibilities | What the agent does |
| Working Principles | How it approaches tasks |
| Input/Output Protocol | Where it reads from and writes to |
| Team Communication Protocol | (Team mode) SendMessage targets and TaskCreate scope |
| Error Handling | Behavior on failure or timeout |
| Collaboration | Relationships with other agents |

**Team restructuring:** Only one team can be active per session, but teams can be dissolved and recreated between phases. Persist prior outputs to `_workspace/` before restructuring so the new team can `Read` them.

**QA Agent requirements** (when included):
- Use `general-purpose` type (not `Explore` -- QA needs script execution for cross-boundary verification)
- QA's core method is **cross-boundary comparison**, not existence checks
- Run QA incrementally after each module, not once at the end
- Detailed guide: `references/qa-agent-guide.md`

> Agent definition template and full examples: `references/agent-design-patterns.md` "Agent Definition" + `references/team-examples.md`.

### Phase 4: Skill Generation

Create skills for each agent at `project/.claude/skills/{name}/SKILL.md`. Detailed writing guide: `references/skill-writing-guide.md`.

#### Skill structure

```
skill-name/
  SKILL.md          (required: YAML frontmatter + markdown body)
  scripts/          (optional: deterministic/repeated tasks)
  references/       (optional: conditionally loaded docs)
  assets/           (optional: templates, images)
```

#### Description writing -- aggressive trigger induction

The description is the only trigger mechanism. Claude tends to be conservative about triggering, so write descriptions **aggressively**: list all actions + concrete trigger situations + boundary conditions distinguishing near-miss cases.

#### Body writing principles

| Principle | Rationale |
|-----------|-----------|
| Explain **why** | LLMs generalize from reasons better than from rigid rules |
| Stay lean (<500 lines) | Context window is a shared resource |
| Generalize, don't overfit | Principles over narrow examples |
| Bundle repeated code | If agents keep generating the same helper, put it in `scripts/` |
| Imperative tone | Skills are directives, not documentation |

#### Progressive disclosure (3-tier loading)

| Tier | Loaded when | Size target |
|------|-------------|-------------|
| Metadata (name + description) | Always in context | ~100 words |
| SKILL.md body | Skill triggered | <500 lines |
| references/ | On demand | Unlimited |

When SKILL.md approaches 500 lines, extract details to `references/` and leave a pointer ("when to read this file") in the body.

#### Skill-agent binding

- 1 agent binds 1..N skills; shared skills across agents are fine
- Skills = "how"; agents = "who"
- Binding methods: Skill tool invocation, inline in agent definition (<50 lines), or `Read` for large references

### Phase 5: Integration & Orchestration

An orchestrator is a special skill that weaves individual agents and skills into a coordinated workflow. Template: `references/orchestrator-template.md`.

#### Mode-specific orchestration

**Agent Team (default):** Orchestrator calls `TeamCreate` to form the team, `TaskCreate` to assign work. Members self-coordinate via `SendMessage`. The leader monitors progress and synthesizes results.

**Sub-agents:** Orchestrator calls `Agent` tool directly. Sub-agents return results to main only.

#### Data transfer protocol

| Strategy | Mechanism | Mode | Best for |
|----------|-----------|------|----------|
| Message-based | `SendMessage` | Team | Real-time coordination, lightweight state |
| Task-based | `TaskCreate`/`TaskUpdate` | Team | Progress tracking, dependency management |
| File-based | Read/Write to agreed paths | Both | Large artifacts, audit trail |

File-based rules: use `_workspace/` for intermediates, name files `{phase}_{agent}_{artifact}.{ext}`, preserve `_workspace/` after completion (audit trail).

#### Error handling

Core policy: retry once on failure; if still failing, proceed without that result and note the gap in the final report. Never delete conflicting data -- attribute sources and present both.

> Error type matrix and implementation details: `references/orchestrator-template.md` "Error Handling" section.

#### Team size guidelines

| Scale | Recommended members | Tasks per member |
|-------|--------------------:|:----------------:|
| Small (5-10 tasks) | 2-3 | 3-5 |
| Medium (10-20 tasks) | 3-5 | 4-6 |
| Large (20+ tasks) | 5-7 | 4-5 |

3 focused members outperform 5 unfocused ones.

### Phase 6: Verification & Testing

Validate the generated harness. Full testing methodology: `references/skill-testing-guide.md`.

#### 6-1. Structural validation

- All agent files in correct locations
- Skill frontmatter (name, description) present and valid
- Cross-references between agents are consistent
- No commands were created (`.claude/commands/` must stay empty)

#### 6-2. Execution mode validation

- **Team mode:** communication paths, task dependencies, team size appropriateness
- **Sub-agent mode:** I/O connections, `run_in_background` settings

#### 6-3. Skill execution test

1. Write 2-3 realistic test prompts per skill (core case + edge case)
2. Run with-skill vs without-skill (baseline) comparison using parallel sub-agents
3. Evaluate via qualitative review + assertion-based grading
4. Iterate: generalize feedback into skill improvements, re-test
5. Bundle repeated helper scripts into `scripts/`

#### 6-4. Trigger validation

For each skill's description, prepare:
- **Should-trigger queries** (8-10): varied expressions of the same intent
- **Should-NOT-trigger queries** (8-10): near-miss queries with similar keywords but different intent

Check for trigger conflicts with existing skills.

#### 6-5. Dry-run validation

- Orchestrator phase ordering is logical
- No dead links in data transfer paths
- Every agent's input matches a prior phase's output
- Fallback paths for error scenarios are executable

#### 6-6. Test scenario documentation

Add a `## Test Scenarios` section to the orchestrator skill with at least 1 happy path + 1 error path.

## Output Checklist

- [ ] `project/.claude/agents/` -- agent definition files (mandatory even for built-in types)
- [ ] `project/.claude/skills/` -- skill files (SKILL.md + references/)
- [ ] 1 orchestrator skill (data flow + error handling + test scenarios)
- [ ] Execution mode explicitly stated (agent team or sub-agents)
- [ ] All Agent calls include `model: "opus"`
- [ ] `.claude/commands/` -- nothing created
- [ ] No conflicts with existing agents/skills
- [ ] Skill descriptions written aggressively ("pushy")
- [ ] SKILL.md bodies under 500 lines; overflow moved to references/
- [ ] 2-3 test prompts executed per skill
- [ ] Trigger validation (should-trigger + should-NOT-trigger) complete

## Deployment

After generating or modifying harness skills, deploy via `sync-skills.sh`:

```bash
./sync-skills.sh --push          # Deploy to Claude Code
./sync-skills.sh --target both --push  # Deploy to both Claude and Codex
```

## Integration with agent-framework

- **`/collab`**: Use for designing the harness itself collaboratively (dual-agent worktree pattern).
- **`/acp-decision`**: Record significant architectural decisions made during harness design.
- **`/acp-constraint`**: Add constraints discovered during harness validation.

## References

- Design patterns: `references/agent-design-patterns.md`
- Team examples: `references/team-examples.md`
- Orchestrator template: `references/orchestrator-template.md`
- Skill writing guide: `references/skill-writing-guide.md`
- Skill testing guide: `references/skill-testing-guide.md`
- QA agent guide: `references/qa-agent-guide.md`
