# plugins/

Scaffolding slot for MCP servers, Claude plugins, or other extensions you want to keep next to the framework source.

The framework ships nothing here; the directory is intentionally empty. `sync-all.sh` does not deploy anything from `plugins/` — wire installation into your own setup script if you add content. Keep vendored MCP servers in self-contained subdirectories so they can be symlinked or npm-installed independently.

See [FORKING.md](../FORKING.md) for the broader fork/customization workflow.
