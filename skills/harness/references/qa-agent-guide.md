# QA Agent Design Guide

Guide for including a QA agent in a build harness. Based on real-world bug patterns, this provides a verification methodology that catches defects QA agents commonly miss -- particularly integration boundary mismatches.

---

## Table of Contents

1. [Defect Patterns QA Agents Miss](#1-defect-patterns-qa-agents-miss)
2. [Integration Coherence Verification](#2-integration-coherence-verification)
3. [QA Agent Design Principles](#3-qa-agent-design-principles)
4. [Verification Checklist Template](#4-verification-checklist-template)
5. [QA Agent Definition Template](#5-qa-agent-definition-template)

---

## 1. Defect Patterns QA Agents Miss

### 1-1. Boundary Mismatch

The most frequent defect class. Two components are each "correctly" implemented in isolation, but their connection contract is broken.

| Boundary | Mismatch Example | Why QA misses it |
|----------|-----------------|------------------|
| API response -> frontend hook | API returns `{ projects: [...] }`, hook expects `SlideProject[]` | Each passes individual review; no cross-comparison |
| API field naming -> type definition | API uses `thumbnailUrl` (camelCase), type defines `thumbnail_url` (snake_case) | TypeScript generic casting bypasses compiler |
| File path -> link href | Page lives at `/dashboard/create`, link points to `/create` | File structure and href values not cross-checked |
| State transition map -> actual status update | Map defines `generating -> approved`, code never executes that transition | Map existence verified, but not all update code traced |
| API endpoint -> frontend hook | API exists but no corresponding hook calls it | API list and hook list not mapped 1:1 |
| Immediate response -> async result | API returns instant `{ status }`, frontend accesses `data.failedIndices` | Sync/async response shapes not distinguished |

### 1-2. Why Static Code Review Fails

- **TypeScript generics mask runtime mismatches:** `fetchJson<SlideProject[]>()` compiles fine even when the actual response is `{ projects: [...] }`
- **`npm run build` passing does not mean correct behavior:** Type casting, `any`, and generics allow compile-time success with runtime failure
- **Existence checks are not connection checks:** "Does this API exist?" is a completely different question from "Does this API's response shape match what the caller expects?"

---

## 2. Integration Coherence Verification

Cross-comparison verification areas that every QA agent should include.

### 2-1. API Response vs Frontend Hook Type

**Method:** Compare each API route's `NextResponse.json()` payload shape with the corresponding hook's `fetchJson<T>` type parameter.

```
Steps:
1. Extract the object shape passed to NextResponse.json() in each API route
2. Identify the T type in the corresponding hook's fetchJson<T>
3. Compare shapes for structural match
4. Check wrapping: if API returns { data: [...] }, does the hook unwrap .data?
```

**Watch for:**
- Pagination APIs: `{ items: [], total, page }` vs frontend expecting a flat array
- snake_case DB field -> camelCase API response -> frontend type definition mismatches
- Immediate response (202 Accepted) vs final result having different shapes

### 2-2. File Path vs Link/Router Path

**Method:** Extract URL patterns from `src/app/` page files and cross-reference all `href`, `router.push()`, `redirect()` values in code.

```
Steps:
1. Derive URL patterns from src/app/ page file paths
   - (group) -> removed from URL
   - [param] -> dynamic segment
2. Collect all href=, router.push(, redirect( values from code
3. Verify each link targets an actually existing page path
4. Watch for route group URL prefix implications
```

### 2-3. State Transition Completeness

**Method:** Extract all `status:` updates from code and cross-reference with the state transition map.

```
Steps:
1. Extract allowed transitions from STATE_TRANSITIONS map
2. Find all .update({ status: "..." }) patterns in API routes
3. Verify each code transition is defined in the map
4. Identify dead transitions (defined in map but never executed)
5. Especially: intermediate state -> final state transitions that are missing
```

### 2-4. API Endpoint vs Frontend Hook 1:1 Mapping

**Method:** List all API routes and frontend hooks, verify pairing.

```
Steps:
1. Extract HTTP method + endpoint list from src/app/api/ route.ts files
2. Extract fetch URL list from src/hooks/ use*.ts files
3. Identify API endpoints with no corresponding hook call -> flag "unused"
4. Determine if "unused" is intentional (admin API, etc.) or a missing call
```

---

## 3. QA Agent Design Principles

### 3-1. Use general-purpose, NOT Explore

QA agents need more than read access. Effective QA requires:
- Grep for pattern searching (extract all `NextResponse.json()` calls)
- Script execution for automated cross-referencing (API shape vs hook type)
- Ability to write fix suggestions or correction files

**Recommended:** `general-purpose` type with "verify -> report -> request fix" protocol defined in the agent file.

### 3-2. Cross-comparison Over Existence Checks

| Weak checklist | Strong checklist |
|---------------|-----------------|
| Does the API endpoint exist? | Does the API response shape match the hook's expected type? |
| Is a state transition map defined? | Do all status update code paths match the map's transitions? |
| Does the page file exist? | Do all code links point to actually existing pages? |
| Is TypeScript strict mode on? | Are there type safety bypasses via generic casting? |

### 3-3. "Read Both Sides Simultaneously"

To catch boundary bugs, the QA agent must read both sides of every boundary at once:
- API route **and** its corresponding hook -- together
- State transition map **and** actual update code -- together
- File structure **and** link paths -- together

Explicitly state this principle in the agent definition file.

### 3-4. Incremental QA, Not End-of-Build QA

Running QA only after everything is complete causes:
- Bug accumulation that raises fix cost
- Early boundary mismatches propagating to downstream modules

**Recommended pattern:** Run QA immediately after each module is complete. Each backend API completion triggers cross-verification of that API + its corresponding hook (incremental QA).

---

## 4. Verification Checklist Template

Include this in QA agent definitions for web application harnesses.

```markdown
### Integration Coherence Verification (Web App)

#### API <-> Frontend Connection
- [ ] All API route response shapes match corresponding hook generic types
- [ ] Wrapped responses ({ items: [...] }) are unwrapped by hooks
- [ ] snake_case <-> camelCase conversion applied consistently
- [ ] Immediate (202) vs final result shapes distinguished in frontend
- [ ] Every API endpoint has a corresponding hook that actually calls it

#### Routing Coherence
- [ ] All href/router.push values match actual page file paths
- [ ] Route group ((group)) URL removal accounted for in path checks
- [ ] Dynamic segments ([id]) filled with correct parameters

#### State Machine Coherence
- [ ] Every defined transition is executed in code (no dead transitions)
- [ ] Every code status update is defined in the transition map (no rogue transitions)
- [ ] Intermediate -> final state transitions are not missing
- [ ] Frontend status-based branching (if status === "X") uses reachable states

#### Data Flow Coherence
- [ ] DB schema field names map consistently to API response fields
- [ ] Frontend type definitions match API response field names
- [ ] Optional field null/undefined handling is consistent on both sides
```

---

## 5. QA Agent Definition Template

Core sections for a QA agent in a build harness.

```markdown
---
name: qa-inspector
description: "QA verification specialist. Validates spec compliance,
  integration coherence, and design quality."
---

# QA Inspector

## Core Responsibilities
Verify implementation quality against specs and **cross-module integration coherence**.

## Verification Priority

1. **Integration coherence** (highest) -- boundary mismatches are the #1 runtime error source
2. **Functional spec compliance** -- API, state machines, data models
3. **Design quality** -- colors, typography, responsiveness
4. **Code quality** -- unused code, naming conventions

## Verification Method: "Read Both Sides"

For boundary verification, always open **both sides simultaneously**:

| Target | Producer (left) | Consumer (right) |
|--------|----------------|-------------------|
| API response shape | route.ts NextResponse.json() | hooks/ fetchJson<T> |
| Routing | src/app/ page file paths | href, router.push values |
| State transitions | STATE_TRANSITIONS map | .update({ status }) code |
| DB -> API -> UI | Table column names | API response fields -> type definitions |

## Team Communication Protocol
- On finding an issue: immediately SendMessage to the responsible agent with file:line + fix instructions
- Boundary issues: notify **both** sides' agents
- To leader: verification report (passed / failed / not-verified items)

## Error Handling
- Cannot access a file: flag as "not-verified" and continue
- Conflicting results: report both with sources attributed
```

---

## Real-World Bug Cases

All content in this guide derives from bugs discovered in actual projects:

| Bug | Boundary | Root Cause |
|-----|----------|------------|
| `projects?.filter is not a function` | API -> hook | API returns `{projects:[]}`, hook expects array |
| All dashboard links 404 | File path -> href | `/dashboard/` prefix missing |
| Theme images not visible | API -> component | `thumbnailUrl` vs `thumbnail_url` |
| Theme selection not saved | API -> hook | select-theme API exists, no hook calls it |
| Generation page infinite wait | State transition -> code | `template_approved` transition code missing |
| `data.failedIndices` crash | Immediate response -> frontend | Accesses background result from immediate response |
| Post-completion slide view 404 | File path -> href | `/projects/` should be `/dashboard/projects/` |
