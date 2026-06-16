# Constraint: Hook Source of Truth

- **Status**: Active
- **Severity**: High
- **Category**: Architecture
- **Scope**: `hooks/`, `~/.claude/hooks/`, `~/.claude/settings.json`

## Rule

Hook scripts MUST be managed in `hooks/<category>/` and deployed via `sync-hooks.sh` only.

## Violations

- Directly creating/editing files in `~/.claude/hooks/`
- Manually editing the `hooks` section in `~/.claude/settings.json`
- Placing hook scripts outside of a category subdirectory

## Rationale

`sync-hooks.sh --push` regenerates the `settings.json` hooks section from `HOOKS.md`. Manual edits to deployed hooks or settings.json will be overwritten on next push, causing silent drift between source and deployed state.

## Correct Workflow

1. Add/edit hook script in `hooks/<category>/`
2. Update `hooks/HOOKS.md` manifest if adding new hook
3. Run `./sync-hooks.sh --push [--profile <name>]`
