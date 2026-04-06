# Orchestrator Skill Template

An orchestrator is the top-level skill that coordinates the entire agent team. Two templates are provided based on execution mode.

---

## Template A: Agent Team Mode (Default)

```markdown
---
name: {domain}-orchestrator
description: "{Domain} agent team orchestrator. {trigger keywords}."
---

# {Domain} Orchestrator

Coordinates the {domain} agent team to produce {final deliverable}.

## Execution Mode: Agent Team

## Agent Composition

| Member | Agent Type | Role | Skill | Output |
|--------|-----------|------|-------|--------|
| {member-1} | {custom or built-in} | {role} | {skill} | {output-file} |
| {member-2} | {custom or built-in} | {role} | {skill} | {output-file} |

## Workflow

### Phase 1: Preparation
1. Analyze user input -- {what to determine}
2. Create `_workspace/` in working directory
3. Save input data to `_workspace/00_input/`

### Phase 2: Team Formation
1. Create team:
   TeamCreate(
     team_name: "{domain}-team",
     members: [
       { name: "{member-1}", agent_type: "{type}", model: "opus", prompt: "{role and task}" },
       { name: "{member-2}", agent_type: "{type}", model: "opus", prompt: "{role and task}" },
     ]
   )

2. Register tasks:
   TaskCreate(tasks: [
     { title: "{task-1}", description: "{details}", assignee: "{member-1}" },
     { title: "{task-2}", description: "{details}", assignee: "{member-2}" },
     { title: "{task-3}", description: "{details}", depends_on: ["{task-1}"] },
   ])

   > Target 5-6 tasks per member. Use `depends_on` for dependent tasks.

### Phase 3: {Main Work}

**Execution:** Members self-coordinate

Members claim tasks from the shared list and work independently.
Leader monitors progress and intervenes only when needed.

**Communication rules:**
- {member-1} sends {what info} to {member-2} via SendMessage
- {member-2} saves results to file and notifies leader on completion
- Members request each other's results via SendMessage when needed

**Output paths:**

| Member | Path |
|--------|------|
| {member-1} | `_workspace/{phase}_{member-1}_{artifact}.md` |
| {member-2} | `_workspace/{phase}_{member-2}_{artifact}.md` |

**Leader monitoring:**
- Receives automatic idle notification when members complete
- Sends guidance via SendMessage when a member is stuck
- Checks overall progress via TaskGet

### Phase 4: {Follow-up}
1. Wait for all members to complete (check via TaskGet)
2. Read each member's output
3. {Integration/verification logic}
4. Generate final deliverable: `{output-path}/{filename}`

### Phase 5: Cleanup
1. Request shutdown from members (SendMessage)
2. Dissolve team (TeamDelete)
3. Preserve `_workspace/` (do not delete -- needed for audit trail)
4. Report summary to user

> **Team restructuring:** If a different expert combination is needed for the next phase, dissolve the current team via TeamDelete, then create a new team via TeamCreate. Prior outputs in `_workspace/` remain accessible via Read.

## Data Flow

[Leader] -> TeamCreate -> [member-1] <-SendMessage-> [member-2]
                             |                          |
                          artifact-1               artifact-2
                             |                          |
                             +---------- Read ----------+
                                          |
                                    [Leader: integrate]
                                          |
                                    Final deliverable

## Error Handling

| Situation | Strategy |
|-----------|----------|
| 1 member fails/stops | Leader detects -> SendMessage to check -> restart or spawn replacement |
| Majority fails | Notify user, ask whether to proceed |
| Timeout | Use partial results collected so far, terminate stalled members |
| Data conflict between members | Attribute sources, keep both -- never delete |
| Task stuck | Leader checks via TaskGet, manually updates via TaskUpdate |

## Test Scenarios

### Happy Path
1. User provides {input}
2. Phase 1: {analysis result}
3. Phase 2: team formed ({N} members + {M} tasks)
4. Phase 3: members self-coordinate and complete work
5. Phase 4: integrate outputs into final result
6. Phase 5: team dissolved
7. Expected: `{output-path}/{filename}` created

### Error Path
1. Phase 3: {member-2} stops due to error
2. Leader receives idle notification
3. SendMessage to check -> restart attempt
4. Restart fails -> reassign {member-2}'s work to {member-1}
5. Proceed to Phase 4 with remaining results
6. Final report notes "{member-2} area partially uncovered"
```

---

## Template B: Sub-agent Mode (Lightweight)

```markdown
---
name: {domain}-orchestrator
description: "{Domain} agent orchestrator. {trigger keywords}."
---

# {Domain} Orchestrator

Coordinates {domain} agents to produce {final deliverable}.

## Execution Mode: Sub-agents

## Agent Composition

| Agent | subagent_type | Role | Skill | Output |
|-------|--------------|------|-------|--------|
| {agent-1} | {custom or built-in} | {role} | {skill} | {output-file} |
| {agent-2} | {custom or built-in} | {role} | {skill} | {output-file} |

## Workflow

### Phase 1: Preparation
1. Analyze user input
2. Create `_workspace/`
3. Save input to `_workspace/00_input/`

### Phase 2: {Main Work}

**Execution:** {parallel | sequential | conditional}

{Parallel:}
Invoke N Agent tools simultaneously in one message:

| Agent | Input | Output | model | run_in_background |
|-------|-------|--------|-------|--------------------|
| {agent-1} | {source} | `_workspace/{phase}_{agent}_{artifact}.md` | opus | true |
| {agent-2} | {source} | `_workspace/{phase}_{agent}_{artifact}.md` | opus | true |

{Sequential:}
Chain outputs as inputs:
1. {agent-1} -> `_workspace/01_{artifact}.md`
2. {agent-2} (input: step 1 output) -> `_workspace/02_{artifact}.md`

### Phase 3: {Follow-up}
1. Read Phase 2 outputs
2. {Integration/verification logic}
3. Generate final deliverable

### Phase 4: Cleanup
1. Preserve `_workspace/`
2. Report summary to user

## Error Handling

| Situation | Strategy |
|-----------|----------|
| 1 agent fails | Retry once. If still failing, proceed without, note gap in report |
| Majority fails | Notify user, ask whether to proceed |
| Timeout | Use partial results collected so far |
| Data conflict | Attribute sources, keep both |

## Test Scenarios

### Happy Path
1. User provides {input}
2. Phase 1: analysis
3. Phase 2: {N} agents run in parallel, each produces output
4. Phase 3: integrate into final deliverable
5. Expected: `{output-path}/{filename}` created

### Error Path
1. Phase 2: {agent-2} fails
2. Retry once -> still fails
3. Proceed without {agent-2} results
4. Final report notes "{agent-2} area uncovered"
5. Notify user of partial completion
```

---

## Authoring Principles

1. **State the execution mode upfront** -- first thing after the title
2. **Team mode: specify TeamCreate/SendMessage/TaskCreate usage concretely** -- team formation, task registration, communication rules
3. **Sub-agent mode: specify all Agent tool parameters** -- name, subagent_type, prompt, run_in_background
4. **Use absolute file paths** -- no relative paths, `_workspace/` as the anchor
5. **State inter-phase dependencies** -- which phase depends on which output
6. **Error handling must be realistic** -- never assume everything succeeds
7. **Test scenarios are mandatory** -- at least 1 happy + 1 error path
