# Constraint: Git Workflow (this repo)

- **Status**: Active
- **Severity**: High
- **Category**: Other
- **Scope**: `agent-framework` repo only (NOT inherited by persona repos)

## Rule

In **this repo**, work directly on `main` — commit and push to `main`
without creating a feature branch. Because this repo is **public**,
review the change thoroughly **before pushing** (commits are free; a
push is the public, reviewed step).

## Violations

- Creating a `feat/*` (or any) branch for a change that can land on `main`
- Pushing to `main` without first reviewing the diff
- Applying this strategy to a persona repo (it is repo-scoped — see AGENTS.md)

## Rationale

`main`-direct keeps the history linear and removes branch churn for a
single-maintainer repo. The one hard gate is the **public** surface:
anything pushed is visible immediately, so the review happens before the
push, not after a merge. Default agent git guidance assumes "branch off
main first"; this constraint overrides that for this repo so agents stop
guessing each session.

## Correct Workflow

1. Make the change on `main`.
2. `git add` + `git commit` (commit freely while iterating).
3. Review the full diff (`git diff origin/main`); confirm no secrets,
   no unintended files.
4. `git push origin main`.
