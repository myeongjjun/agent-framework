# Agent Team Design Patterns

## Execution Mode: Agent Team vs Sub-agents

### Agent Team -- Default Mode

The leader creates a team via `TeamCreate`. Members run as independent Claude Code instances, communicate directly via `SendMessage`, and self-coordinate through a shared task list (`TaskCreate`/`TaskUpdate`).

```
[Leader] <-> [Member A] <-> [Member B]
  |              |              |
  +-------- Shared Task List --+
```

**Key tools:** `TeamCreate`, `SendMessage({to: name})`, `SendMessage({to: "all"})` (expensive, use sparingly), `TaskCreate`/`TaskUpdate`

**Strengths:** Direct peer challenge and verification, information exchange without routing through leader, self-coordination via shared tasks, automatic idle notifications, plan-approval mode for risky operations.

**Constraints:** One active team per session (but dissolve-and-recreate between phases is allowed), no nested teams, fixed leader, higher token cost.

**Team restructuring pattern:** When different phases need different expert combinations -- save outputs to `_workspace/` -> dissolve team -> create new team. The new team reads prior outputs via `Read`.

### Sub-agents -- Lightweight Mode

The main agent creates sub-agents via the `Agent` tool. Each sub-agent returns results to main only; no peer communication.

```
[Main] -> [Sub A] -> result
       -> [Sub B] -> result
       -> [Sub C] -> result
```

**Key tool:** `Agent(prompt, subagent_type, run_in_background)`

**Strengths:** Lightweight, fast, token-efficient, results summarized into main context.

**Constraints:** No inter-agent communication, main handles all coordination, no real-time collaboration.

### Execution Mode Decision Tree

```
Are there 2+ agents?
|-- Yes -> Do agents need inter-communication?
|          |-- Yes -> Agent Team (default)
|          |         Cross-validation, discovery sharing, real-time feedback.
|          |
|          +-- No  -> Sub-agents viable
|                     Pure result handoff only (e.g., producer-reviewer, expert pool).
|
+-- No (1 agent) -> Sub-agent
                    Single agent needs no team infrastructure.
```

**Guiding principle:** Agent team is the default. When choosing sub-agents, ask: "Is peer communication truly unnecessary?"

---

## Architecture Patterns

### 1. Pipeline
Sequential flow. Prior output feeds next input.

```
[Analyze] -> [Design] -> [Implement] -> [Verify]
```

**Use when:** Each step strongly depends on the prior step's output.
**Team fit:** Limited -- but useful if parallel sub-phases exist within a step.

### 2. Fan-out/Fan-in
Parallel processing then result aggregation.

```
         +-> [Expert A] -+
[Split] -+-> [Expert B] -+-> [Merge]
         +-> [Expert C] -+
```

**Use when:** Same input needs analysis from different angles/domains.
**Team fit:** The most natural team pattern. **Always use agent team.** Members share discoveries in real-time, adjusting each other's investigation direction.

### 3. Expert Pool
Route to the appropriate expert based on input type.

```
[Router] -> { Expert A | Expert B | Expert C }
```

**Use when:** Input type determines which processing path to take.
**Team fit:** Sub-agents preferred -- only the relevant expert is invoked.

### 4. Producer-Reviewer
Generator and validator operate as a pair.

```
[Generate] -> [Review] -> (issues?) -> [Generate] re-run
```

**Use when:** Output quality is critical and objective review criteria exist.
**Team fit:** Team enables real-time feedback exchange via `SendMessage`. Set max retry to 2-3 to prevent infinite loops.

### 5. Supervisor
Central agent manages state and dynamically dispatches work to workers.

```
           +-> [Worker A]
[Super] ---+-> [Worker B]    <- dynamic dispatch based on state
           +-> [Worker C]
```

**Use when:** Workload is variable or dispatch decisions happen at runtime.
**Difference from fan-out:** Fan-out pre-assigns work; supervisor adjusts dynamically.
**Team fit:** Shared task list's claim mechanism is a natural fit. Workers self-claim via `TaskCreate`.

### 6. Hierarchical Delegation
Upper-level agent recursively delegates to lower-level agents.

```
[Director] -> [Lead A] -> [Worker A1]
                        -> [Worker A2]
           -> [Lead B] -> [Worker B1]
```

**Use when:** The problem naturally decomposes into a hierarchy.
**Team fit:** Since teams cannot nest, implement level 1 as a team and level 2 as sub-agents -- or flatten into a single team. Keep depth <= 2 to avoid latency and context loss.

## Composite Patterns

Single patterns are rare in practice. Common composites:

| Composite | Structure | Example |
|-----------|-----------|---------|
| Fan-out + Producer-Reviewer | Parallel generation, each independently reviewed | Multi-language translation with per-language native reviewer |
| Pipeline + Fan-out | Sequential stages with parallel sub-phases | Analyze (seq) -> Implement (parallel) -> Integration test (seq) |
| Supervisor + Expert Pool | Supervisor dynamically invokes specialists | Customer support -- supervisor classifies, routes to specialist |

**Default:** Use agent team for all composites. Active inter-member communication is the core quality driver.

---

## Agent Type Selection

### Built-in Types

| Type | Tool Access | Best for |
|------|-------------|----------|
| `general-purpose` | Full (incl. WebSearch, WebFetch) | Web research, general tasks |
| `Explore` | Read-only (no Edit/Write) | Codebase exploration, analysis |
| `Plan` | Read-only (no Edit/Write) | Architecture design, planning |

### Custom Types

Define in `.claude/agents/{name}.md`, invoke with `subagent_type: "{name}"`. Full tool access.

### Selection Guide

| Situation | Recommended | Reason |
|-----------|-------------|--------|
| Complex role, multi-session reuse | Custom type | Persona and principles managed as file |
| Simple investigation, prompt-sufficient | `general-purpose` | No agent file overhead |
| Read-only analysis/review | `Explore` | Prevents accidental file modification |
| Design/planning only | `Plan` | Focused on analysis, no code changes |
| Implementation requiring file edits | Custom type | Full tool access + specialized directives |

**Rule:** All agents must have a `.claude/agents/{name}.md` file, even when using built-in types. The file captures role, principles, and protocols for reuse and collaboration quality.

**Model:** All agents use `model: "opus"`. Always specify this parameter in Agent tool calls.

---

## Agent Definition Template

```markdown
---
name: agent-name
description: "1-2 sentence role description. Trigger keywords."
---

# Agent Name -- Role summary

You are a [role] specialist in [domain].

## Core Responsibilities
1. Responsibility 1
2. Responsibility 2

## Working Principles
- Principle 1
- Principle 2

## Input/Output Protocol
- Input: [source and format]
- Output: [destination and format]

## Team Communication Protocol (agent team mode)
- Receive from: [who sends what]
- Send to: [who receives what]
- Task scope: [what types of tasks this agent claims from shared list]

## Error Handling
- On failure: [behavior]
- On timeout: [behavior]

## Collaboration
- Relationships with other agents
```

---

## Agent Separation Criteria

| Criterion | Separate | Merge |
|-----------|----------|-------|
| Expertise | Different domains | Overlapping domains |
| Parallelism | Independently executable | Sequentially dependent |
| Context | High context burden | Lightweight and fast |
| Reusability | Used by other teams | Used only by this team |

## Skill vs Agent Distinction

| Aspect | Skill | Agent |
|--------|-------|-------|
| Definition | Procedural knowledge + tool bundle | Expert persona + behavioral principles |
| Location | `.claude/skills/` | `.claude/agents/` |
| Trigger | User request keyword matching | Explicit invocation via Agent tool |
| Size | Small to large (workflows) | Small (role definitions) |
| Purpose | "How to do it" | "Who does it" |

## Skill-Agent Binding Methods

| Method | Implementation | Best when |
|--------|---------------|-----------|
| Skill tool call | Agent prompt says `invoke /skill-name via Skill tool` | Skill is an independent workflow, user-callable |
| Inline in agent def | Embed skill content directly in agent definition | Skill is short (<50 lines) and agent-exclusive |
| Reference load | `Read` skill's references/ on demand | Skill content is large and conditionally needed |
