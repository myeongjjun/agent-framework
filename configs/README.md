# configs/

Scaffolding slot for shared configuration files you want versioned alongside the framework — e.g., Claude Code / Codex settings fragments, Cursor rules, editor configs that teammates reuse.

The framework ships nothing here; the directory is intentionally empty. Populate it in your fork if you want a single source of truth for cross-tool config. `sync-all.sh` does not deploy anything from `configs/` — wiring into deploy is your responsibility.

See [FORKING.md](../FORKING.md) for the broader fork/customization workflow.
