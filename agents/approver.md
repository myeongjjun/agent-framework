---
name: "approver"
description: "Bash daemon that scans cmux surfaces for stuck workers and auto-approves safe approval prompts by pressing enter. No LLM, no zmx."
type: "daemon"

# --- Persistent Agent Config (agent-team extension) ---
# Read by start-agent.sh and daemon.sh supervision for lifecycle management.
persistent: true
health_interval: 30
restart_policy: "always"
max_restarts: 5
priority: 1
tags: ["infra", "automation", "agent-team", "daemon"]
---

# Approver Daemon

The approver is a pure bash daemon. It is **not** an LLM session. Its
runtime is `scripts/orchestrator/effects/approver-scan.sh --loop`,
double-forked under supervision by `scripts/orchestrator/daemon.sh`.

## Runtime

| Item | Value |
|------|-------|
| Runtime root | `~/.approver/` |
| Scan loop | `~/.approver/approver-scan.sh --loop` |
| Scan PID file | `~/.approver/scan.pid` |
| Decision log | `~/.approver/decisions.jsonl` |
| Loop log | `~/.approver/loop.log` |
| Send-key helper | `~/.approver/approver-send-key.sh` |

## Supervision

The orchestrator daemon (`scripts/orchestrator/daemon.sh`) supervises the
scan loop on its periodic tick (piggybacks on `run_periodic_tidy`, ~30s):

- If `~/.approver/RUNNING` exists but the recorded `scan.pid` is dead,
  the daemon double-forks a fresh `approver-scan.sh --loop` and records
  the new PID.
- Heartbeat (`last_health`) is refreshed in
  `~/.orchestrator/agents/registry.json` whenever the scan is alive.

## Lifecycle

| Action | Command |
|--------|---------|
| Start  | `team.sh start approver --execute` |
| Stop   | `team.sh stop approver --execute` |
| Restart| `team.sh restart approver --execute` |
| Status | `team.sh card approver` / `team.sh status` |

No cmux agent surface is created for the approver: the runtime is a
detached bash process. The `agent-team` workspace shows an
`approver-log` pane that tails `~/.approver/loop.log`, managed by
`health.sh recover_surfaces()`.

## Safety Rules (enforced in `approver-scan.sh`)

- NEVER approve `rm -rf` outside `.worktrees/` or `/tmp/`.
- NEVER approve `git push --force` or `git reset --hard`.
- NEVER approve operations on `~/.ssh/`, `~/.aws/`, `~/.env`, or paths
  matching `credential|secret|token`.
- NEVER auto-confirm `Allow always` highlighted prompts (persistent
  tool grants require a human).
- Per-surface cooldown (`~/.approver/approvals/*.ts`) prevents the
  slow-path and the fast-path watcher from double-approving the next
  prompt.
