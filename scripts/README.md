# scripts/

Automation and deployment helpers for agent-framework. Unlike the other top-level dirs, this one is populated — the framework's deploy / release / analysis / transcript pipeline lives here.

See the **Scripts** table in the root [README.md](../README.md) for the canonical index of each script's purpose.

## Conventions

- Every script should be executable (`chmod +x`) and carry a usage header at the top.
- Top-level scripts that agents invoke by absolute path (e.g., `~/.claude/scripts/handoff-rotate.sh`) are deployed by `sync-all.sh` Step 4.
- The `orchestrator/` subtree is a long-lived daemon and is deployed to `~/.orchestrator/` by `sync-all.sh` Step 5; do not edit the deployed copy directly (see `hooks/general/guard-deployed-artifact-edit.sh`).
