#!/usr/bin/env bash
#
# test-conductor.sh — sandbox test harness for the conductor CLI.
#
# Stage 0 dry-run only. NO live cmux/zmx/git operations beyond initializing
# a throwaway git repo. Hermetic: every test runs against an isolated
# ORCHESTRATOR_ROOT under /tmp/conductor-sandbox-$$ which is deleted on exit.
#
# Test layout (post-collab Phase 5 synthesis: B's harness extended with A's
# stronger coverage and the T6/T15 bug fixes baked in):
#
#   T1   help                                                 (CLI sanity)
#   T2   dispatch dry-run end-to-end (plan JSON shape)        (B's existing)
#   T3   dispatch dry-run did not mutate state                (purity proof)
#   T4   list on empty state does not crash                   (B's existing)
#   T5   reserved slug 'base' rejected                        (A: T12)
#   T6   reserved slug 'main' rejected                        (A: T12 ext)
#   T7   bad slug 'Has Spaces' rejected                       (input guard)
#   T8   status on missing task errors                        (A: T13)
#   T9   done on missing task errors                          (A: T14)
#   T10  core/ purity grep guard                              (A: T15, fixed)
#   T11  effect scripts have --dry-run path                   (defense)
#   T12  dispatch defaults to per-task worktree               (worktree plan)
#   T13  --no-worktree escape hatch                           (override path)
#   T14  dry-run does not create worktree dir                 (side-effect)
#   T15  backend dispatchers support cmux and iTerm2          (routing)
#   T16  detect.sh backend priority                           (selection)
#   T17  orchestrator health dead when no sentinel            (agent health)
#   T18  start-agent dry-run plan without side effects        (bootstrap plan)
#   T19  stop-agent dry-run plan on fake state                (shutdown plan)
#   T20  protocol.sh is sourceable and exports helpers        (library contract)
#   T21  done execute is idempotent for already-done task     (bug 1)
#   T22  dispatch rejects active duplicate but reuses done     (bug 3)

set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX_DIR="/tmp/conductor-sandbox-$$"
REPO_DIR="${SANDBOX_DIR}/repo"
ORCHESTRATOR_ROOT="${SANDBOX_DIR}/orchestrator"
HOME_DIR="${SANDBOX_DIR}/home"

PASS=0
FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
section() { printf '\033[34m==\033[0m %s\n' "$*"; }

cleanup() {
  rm -rf "${SANDBOX_DIR}"
}
trap cleanup EXIT

mkdir -p "${REPO_DIR}" "${ORCHESTRATOR_ROOT}" "${HOME_DIR}"

(
  cd "${REPO_DIR}"
  git init -q
  git config user.name "Conductor Sandbox"
  git config user.email "conductor-sandbox@example.com"
  printf '# Sandbox\n' > README.md
  git add README.md
  git commit -q -m "sandbox init"
)

run_conductor() {
  cd "${REPO_DIR}"
  HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" ZMX_SESSION="" \
    "${ROOT_DIR}/scripts/conductor.sh" "$@"
}

run_orchestrator_script() {
  local script_name="$1"
  shift
  (
    cd "${REPO_DIR}"
    HOME="${HOME_DIR}" \
    ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" \
    ORCHESTRATOR_BACKEND=cmux \
      "${ROOT_DIR}/scripts/orchestrator/${script_name}" "$@"
  )
}

# T1 — help
section "T1 conductor help"
if run_conductor help >/dev/null 2>&1 || run_conductor --help >/dev/null 2>&1; then
  ok "help command runs"
else
  bad "help command failed"
fi

# T2 — dispatch dry-run plan shape
section "T2 dispatch dry-run end-to-end"
dispatch_output="$(run_conductor dispatch test-task "test description" --dry-run)"
if printf '%s\n' "${dispatch_output}" | jq -e '
    .mode == "dry-run"
    and .plan.task.slug == "test-task"
    and .plan.task.description == "test description"
    and .plan.task.work_item_path == "'"${ORCHESTRATOR_ROOT}"'/tasks/test-task.md"
    and (.plan.agents | length) >= 1
    and (.plan.agents[0].slot | startswith("claude-"))
    and (.effects.spawn.commands | length) >= 1
  ' >/dev/null; then
  ok "dispatch dry-run produces valid plan JSON"
else
  bad "dispatch dry-run plan JSON shape unexpected"
  printf '%s\n' "${dispatch_output}" | jq . 2>/dev/null | head -30
fi

# T3 — dispatch dry-run did not mutate state
section "T3 dispatch dry-run is side-effect free"
if [[ ! -f "${ORCHESTRATOR_ROOT}/state.json" ]] && [[ ! -f "${ORCHESTRATOR_ROOT}/tasks/test-task.md" ]]; then
  ok "dry-run did not create state.json or work item files"
else
  bad "dry-run mutated orchestrator state"
fi

# T4 — list on empty state
section "T4 list on empty state"
list_output="$(run_conductor list)"
if printf '%s\n' "${list_output}" | grep -F "Tasks:" >/dev/null; then
  ok "list runs on empty state"
else
  bad "list output missing 'Tasks:' header"
fi

# T5 — reserved slug 'base'
section "T5 reserved slug 'base' rejected"
if run_conductor dispatch base "should fail" --dry-run >/dev/null 2>&1; then
  bad "dispatch accepted reserved slug 'base'"
else
  ok "dispatch rejected reserved slug 'base'"
fi

# T6 — reserved slug 'main'
section "T6 reserved slug 'main' rejected"
if run_conductor dispatch main "should fail" --dry-run >/dev/null 2>&1; then
  bad "dispatch accepted reserved slug 'main'"
else
  ok "dispatch rejected reserved slug 'main'"
fi

# T7 — bad slug format
section "T7 bad slug format rejected"
if run_conductor dispatch "Has Spaces" "should fail" --dry-run >/dev/null 2>&1; then
  bad "dispatch accepted slug with spaces"
else
  ok "dispatch rejected slug with spaces"
fi

# T8 — status on missing task errors
section "T8 status on missing task errors"
if run_conductor status nonexistent-slug >/dev/null 2>&1; then
  bad "status accepted nonexistent task"
else
  ok "status errors on missing task"
fi

# T9 — done on missing task errors
section "T9 done on missing task errors"
if run_conductor done nonexistent-slug --dry-run >/dev/null 2>&1; then
  bad "done accepted nonexistent task"
else
  ok "done errors on missing task"
fi

# T10 — core/ purity grep guard
# Detect actual cmux/zmx/git command invocations in core/, while ignoring:
#   - comment lines (start with #)
#   - heredoc body lines (between <<EOF and EOF)
#   - string assignment / heredoc content where the token appears as data
# Strategy: only flag lines where (cmux|zmx|git) appears at command position,
# meaning preceded by start-of-line (with optional whitespace), or by a
# command separator like ; && || $( ` then else do { (.
section "T10 core/ purity grep guard"
# Strip comments and heredoc bodies via a small python helper, then grep for
# (cmux|zmx|git) at command position. Python is more portable than gawk's
# match() third-argument extension on macOS.
purity_violations="$(python3 - "${ROOT_DIR}/scripts/orchestrator/core" <<'PY'
import os
import re
import sys

core_dir = sys.argv[1]
heredoc_open = re.compile(r"<<-?[\"']?([A-Za-z_][A-Za-z0-9_]*)")
# cmux/zmx/git at command position: start-of-line (after optional whitespace)
# OR after a command separator, NOT preceded by " or ' (which means it's data).
# Match cmux/zmx/git at command position. Negative lookbehind for `="` (and `='`)
# rules out assignments like  attach_command="cd && zmx attach ..."  where the
# token appears inside a string literal.
cmd_pat = re.compile(
    r"(?:^|[;&|`{(]|\$\()\s*(cmux|zmx|git)\s+[a-z-]"
)
string_assign = re.compile(r'=["\']')
violations = []
for fname in sorted(os.listdir(core_dir)):
    if not fname.endswith(".sh"):
        continue
    path = os.path.join(core_dir, fname)
    with open(path) as fh:
        in_heredoc = None
        for lineno, raw in enumerate(fh, start=1):
            line = raw.rstrip("\n")
            if in_heredoc is not None:
                if line.strip() == in_heredoc:
                    in_heredoc = None
                continue
            stripped = line.lstrip()
            if stripped.startswith("#"):
                continue
            m = heredoc_open.search(line)
            if m:
                in_heredoc = m.group(1)
            m = cmd_pat.search(line)
            if m:
                # Check if the match is inside a string assignment
                prefix = line[:m.start()]
                if string_assign.search(prefix):
                    continue
                violations.append(f"{path}:{lineno}:{line}")
for v in violations:
    print(v)
PY
)"
if [[ -z "${purity_violations}" ]]; then
  ok "core/ has no cmux/zmx/git invocations (purity intact)"
else
  bad "core/ purity violation:"
  printf '%s\n' "${purity_violations}" | head -5 | sed 's/^/    /'
fi

# T11 — effect scripts each have a dry-run path (top-level + backends)
section "T11 effect scripts have --dry-run path"
all_have_dry_run=true
# Top-level dispatchers
for f in "${ROOT_DIR}"/scripts/orchestrator/effects/*.sh; do
  if ! grep -qE -- '--dry-run|dry[-_]?run' "$f"; then
    bad "effect $(basename "$f") missing --dry-run path"
    all_have_dry_run=false
  fi
done
# Backend implementations (each backend dir must have spawn/inject/kill
# all with dry-run support)
for backend_dir in "${ROOT_DIR}"/scripts/orchestrator/effects/backends/*/; do
  backend_name="$(basename "${backend_dir}")"
  for op in spawn inject kill; do
    f="${backend_dir}${op}.sh"
    if [[ ! -f "$f" ]]; then
      bad "backend ${backend_name} missing ${op}.sh"
      all_have_dry_run=false
      continue
    fi
    if ! grep -qE -- '--dry-run|dry[-_]?run' "$f"; then
      bad "backend ${backend_name}/${op}.sh missing --dry-run path"
      all_have_dry_run=false
    fi
  done
done
if [[ "${all_have_dry_run}" == true ]]; then
  ok "all effect scripts (top-level + backends) have --dry-run path"
fi

# T12 — dispatch dry-run plan contains worktree provisioning by default
section "T12 dispatch defaults to per-task worktree"
wt_dispatch="$(run_conductor dispatch worktree-default-task "verify worktree default" --dry-run)"
if printf '%s\n' "${wt_dispatch}" | jq -e '
    .plan.worktree.required == true
    and (.plan.worktree.path | test("/.worktrees/dispatch-worktree-default-task-claude-1$"))
    and (.plan.worktree.branch == "dispatch/worktree-default-task-claude-1")
    and (.plan.agents[0].cwd | endswith("/.worktrees/dispatch-worktree-default-task-claude-1"))
    and (.effects.worktree.commands | length) >= 1
    and (.effects.worktree.commands[0] | test("git .* worktree add -b dispatch/worktree-default-task-claude-1"))
  ' >/dev/null; then
  ok "dispatch dry-run plan provisions per-task worktree by default"
else
  bad "dispatch dry-run plan missing or wrong worktree fields"
  printf '%s\n' "${wt_dispatch}" | jq '.plan.worktree, .effects.worktree' 2>/dev/null | head -15
fi

# T13 — --no-worktree escape hatch
section "T13 --no-worktree escape hatch"
nowt_dispatch="$(run_conductor dispatch readonly-task "verify --no-worktree" --dry-run --no-worktree)"
if printf '%s\n' "${nowt_dispatch}" | jq -e '
    .plan.worktree.required == false
    and (.plan.worktree | has("path") | not)
    and (.plan.agents[0].cwd | test("\\.worktrees") | not)
    and (.effects.worktree.mode == "skipped" or .effects.worktree.script == null)
  ' >/dev/null; then
  ok "--no-worktree skips worktree provisioning and keeps agent in project root"
else
  bad "--no-worktree escape did not fully skip worktree"
  printf '%s\n' "${nowt_dispatch}" | jq '.plan.worktree, .plan.agents[0].cwd, .effects.worktree' 2>/dev/null | head -15
fi

# T14 — dry-run did not actually create the worktree directory
section "T14 dispatch dry-run does not create the worktree on disk"
if [[ ! -e "${REPO_DIR}/.worktrees" ]]; then
  ok "dry-run did not create .worktrees directory"
else
  bad "dry-run created .worktrees directory — should be side-effect free"
fi

# T15 — backend dispatchers route to both cmux and iterm2 via env override
section "T15 backend dispatchers support cmux and iterm2"
spawn_cmux="$(ORCHESTRATOR_BACKEND=cmux "${ROOT_DIR}/scripts/orchestrator/effects/spawn-surface.sh" --dry-run claude-test-1 /tmp 2>&1)"
spawn_iterm="$(ORCHESTRATOR_BACKEND=iterm2 "${ROOT_DIR}/scripts/orchestrator/effects/spawn-surface.sh" --dry-run claude-test-1 /tmp 2>&1)"
inject_cmux="$(ORCHESTRATOR_BACKEND=cmux "${ROOT_DIR}/scripts/orchestrator/effects/inject-takeover.sh" --dry-run "fake-id" "/tmp/wi.md")"
inject_iterm="$(ORCHESTRATOR_BACKEND=iterm2 "${ROOT_DIR}/scripts/orchestrator/effects/inject-takeover.sh" --dry-run "fake-id" "/tmp/wi.md")"
kill_cmux="$(ORCHESTRATOR_BACKEND=cmux "${ROOT_DIR}/scripts/orchestrator/effects/kill-surface.sh" --dry-run claude-test-1)"
kill_iterm="$(ORCHESTRATOR_BACKEND=iterm2 "${ROOT_DIR}/scripts/orchestrator/effects/kill-surface.sh" --dry-run claude-test-1)"
if printf '%s\n' "${spawn_cmux}" | jq -e '.backend == "cmux" and .mode == "dry-run"' >/dev/null \
   && printf '%s\n' "${spawn_iterm}" | jq -e '.backend == "iterm2" and .mode == "dry-run"' >/dev/null \
   && printf '%s\n' "${inject_cmux}" | jq -e '.backend == "cmux"' >/dev/null \
   && printf '%s\n' "${inject_iterm}" | jq -e '.backend == "iterm2"' >/dev/null \
   && printf '%s\n' "${kill_cmux}" | jq -e '.backend == "cmux"' >/dev/null \
   && printf '%s\n' "${kill_iterm}" | jq -e '.backend == "iterm2"' >/dev/null; then
  ok "spawn/inject/kill dispatchers all route to cmux and iterm2 backends"
else
  bad "one or more backend dispatchers failed routing"
fi

# T16 — backend detection picks the right one given env hints
section "T16 backend detect.sh picks expected backend from env"
detect_helper="$(cat <<'BASH'
. "${ROOT_DIR}/scripts/orchestrator/effects/backends/detect.sh"
detect_backend
echo "${BACKEND}"
BASH
)"
b1="$(env -i HOME="${HOME}" PATH="${PATH}" ROOT_DIR="${ROOT_DIR}" ORCHESTRATOR_BACKEND=cmux bash -c "${detect_helper}")"
b2="$(env -i HOME="${HOME}" PATH="${PATH}" ROOT_DIR="${ROOT_DIR}" ORCHESTRATOR_BACKEND=iterm2 bash -c "${detect_helper}")"
b3="$(env -i HOME="${HOME}" PATH="${PATH}" ROOT_DIR="${ROOT_DIR}" CMUX_SURFACE_ID="surface:1" bash -c "${detect_helper}")"
b4="$(env -i HOME="${HOME}" PATH="${PATH}" ROOT_DIR="${ROOT_DIR}" TERM_PROGRAM="iTerm.app" ITERM_SESSION_ID="w0t1p0:UUID" bash -c "${detect_helper}")"
detect_ok=true
[[ "${b1}" == "cmux"   ]] || { bad "explicit cmux override failed (got: ${b1})";   detect_ok=false; }
[[ "${b2}" == "iterm2" ]] || { bad "explicit iterm2 override failed (got: ${b2})"; detect_ok=false; }
# b3 only passes if cmux is on PATH; on the sandbox CI box it may not be — skip strict check
# b4 only passes if osascript is on PATH; same caveat
if [[ "${b3}" == "cmux"   || "${b3}" == "unknown" ]]; then : ; else bad "CMUX_SURFACE_ID detect failed (got: ${b3})"; detect_ok=false; fi
if [[ "${b4}" == "iterm2" || "${b4}" == "unknown" ]]; then : ; else bad "iTerm.app detect failed (got: ${b4})"; detect_ok=false; fi
if [[ "${detect_ok}" == true ]]; then
  ok "backend detection follows the expected priority order"
fi

# T17 — health reports dead when no sentinel exists
section "T17 orchestrator health reports dead without sentinel"
set +e
health_output="$(run_orchestrator_script health.sh 2>&1)"
health_status=$?
set -e
if [[ "${health_status}" -eq 1 ]] && printf '%s\n' "${health_output}" | grep -F 'status=dead' >/dev/null; then
  ok "health.sh reports dead with exit code 1 when no sentinel exists"
else
  bad "health.sh did not report dead as expected"
  printf '%s\n' "${health_output}" | sed 's/^/    /'
fi

# T18 — start-agent dry-run produces a plan without side effects
section "T18 start-agent dry-run is side-effect free"
start_plan="$(run_orchestrator_script start-agent.sh --dry-run)"
if printf '%s\n' "${start_plan}" | jq -e '
    .action == "start-orchestrator-agent"
    and .mode == "dry-run"
    and .backend == "cmux"
    and .slot == "claude-orchestrator-global"
    and .effects.spawn.backend == "cmux"
    and .effects.inject.action == "inject-prompt"
    and .effects.wait_seconds == 10
  ' >/dev/null \
  && [[ ! -e "${ORCHESTRATOR_ROOT}/agent" ]]; then
  ok "start-agent dry-run returns a valid plan without creating sentinel state"
else
  bad "start-agent dry-run plan or side-effect check failed"
  printf '%s\n' "${start_plan}" | jq . 2>/dev/null | head -20
fi

# T19 — stop-agent dry-run handles imaginary running state without side effects
section "T19 stop-agent dry-run plans cleanup for stale sentinel state"
mkdir -p "${ORCHESTRATOR_ROOT}/agent"
printf 'started_at=2026-04-09T00:00:00Z\n' > "${ORCHESTRATOR_ROOT}/agent/RUNNING"
printf '999999\n' > "${ORCHESTRATOR_ROOT}/agent/pid"
printf 'claude-orchestrator-global\n' > "${ORCHESTRATOR_ROOT}/agent/slot"
printf 'cmux\n' > "${ORCHESTRATOR_ROOT}/agent/backend"
printf 'surface:999\n' > "${ORCHESTRATOR_ROOT}/agent/surface_id"
stop_plan="$(run_orchestrator_script stop-agent.sh --dry-run)"
if printf '%s\n' "${stop_plan}" | jq -e '
    .action == "stop-orchestrator-agent"
    and .mode == "dry-run"
    and .strategy == "stale-cleanup"
    and .target.slot == "claude-orchestrator-global"
    and .target.backend == "cmux"
  ' >/dev/null \
  && [[ -f "${ORCHESTRATOR_ROOT}/agent/RUNNING" ]] \
  && [[ -f "${ORCHESTRATOR_ROOT}/agent/pid" ]]; then
  ok "stop-agent dry-run returns a valid plan and leaves fake sentinel files untouched"
else
  bad "stop-agent dry-run plan or sentinel preservation check failed"
  printf '%s\n' "${stop_plan}" | jq . 2>/dev/null | head -20
fi

# T20 — protocol.sh can be sourced and exports the declared helpers
section "T20 protocol.sh exports orchestrator helper functions"
set +e
protocol_types="$(
  cd "${REPO_DIR}" && \
    HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" bash -lc '
      . "'"${ROOT_DIR}"'/scripts/orchestrator/protocol.sh"
      type orchestrator_request
      type orchestrator_alive
      type orchestrator_surface_id
      type orchestrator_backend
    ' 2>&1
)"
protocol_status=$?
set -e
if [[ "${protocol_status}" -eq 0 ]] && printf '%s\n' "${protocol_types}" | grep -F 'orchestrator_request is a function' >/dev/null; then
  ok "protocol.sh is sourceable and exports the declared functions"
else
  bad "protocol.sh did not export the expected helpers"
  printf '%s\n' "${protocol_types}" | sed 's/^/    /'
fi

# T21 — done execute is idempotent for an already-done task
section "T21 done execute is idempotent for already-done task"
mkdir -p "${ORCHESTRATOR_ROOT}/tasks" "${ORCHESTRATOR_ROOT}/done"
printf '# Work Item: already-done\n' > "${ORCHESTRATOR_ROOT}/tasks/already-done.md"
printf '# Done Report: already-done\n' > "${ORCHESTRATOR_ROOT}/done/already-done.md"
jq -n \
  --arg task_path "${ORCHESTRATOR_ROOT}/tasks/already-done.md" \
  --arg done_report_path "${ORCHESTRATOR_ROOT}/done/already-done.md" \
  '{
    version: 1,
    updated_at: "2026-04-09T00:00:00Z",
    projects: {},
    tasks: {
      "already-done": {
        status: "done",
        work_item_path: $task_path,
        done_report_path: $done_report_path,
        agents: []
      }
    },
    agents: {}
  }' > "${ORCHESTRATOR_ROOT}/state.json"
printf '%s\n' '{"timestamp":"2026-04-09T00:00:00Z","event":"task-done","slug":"already-done"}' > "${ORCHESTRATOR_ROOT}/activity.jsonl"
before_activity_lines="$(wc -l < "${ORCHESTRATOR_ROOT}/activity.jsonl" | tr -d ' ')"
existing_done_report="$(cat "${ORCHESTRATOR_ROOT}/done/already-done.md")"
set +e
repeat_done_output="$(run_conductor done already-done --execute 2>&1)"
repeat_done_status=$?
set -e
after_activity_lines="$(wc -l < "${ORCHESTRATOR_ROOT}/activity.jsonl" | tr -d ' ')"
if [[ "${repeat_done_status}" -eq 0 ]] \
  && [[ "${before_activity_lines}" == "${after_activity_lines}" ]] \
  && [[ "$(cat "${ORCHESTRATOR_ROOT}/done/already-done.md")" == "${existing_done_report}" ]] \
  && printf '%s\n' "${repeat_done_output}" | grep -F "already done" >/dev/null; then
  ok "done skips duplicate completion for an already-done task"
else
  bad "done was not idempotent for an already-done task"
  printf '%s\n' "${repeat_done_output}" | sed 's/^/    /'
fi

# T22 — dispatch blocks active duplicates but allows reusing a done slug
section "T22 dispatch rejects active duplicate but reuses done slug"
jq -n '{
  version: 1,
  updated_at: "2026-04-09T00:00:00Z",
  projects: {},
  tasks: {
    "duplicate-task": {
      status: "in_progress",
      description: "first run",
      agents: []
    }
  },
  agents: {}
}' > "${ORCHESTRATOR_ROOT}/state.json"
set +e
duplicate_active_output="$(run_conductor dispatch duplicate-task "second run" --dry-run 2>&1)"
duplicate_active_status=$?
set -e

jq -n '{
  version: 1,
  updated_at: "2026-04-09T00:00:00Z",
  projects: {},
  tasks: {
    "duplicate-task": {
      status: "done",
      description: "first run",
      agents: []
    }
  },
  agents: {}
}' > "${ORCHESTRATOR_ROOT}/state.json"
reuse_done_output="$(run_conductor dispatch duplicate-task "second run" --dry-run)"

if [[ "${duplicate_active_status}" -ne 0 ]] \
  && printf '%s\n' "${duplicate_active_output}" | grep -F "non-done status" >/dev/null \
  && printf '%s\n' "${reuse_done_output}" | jq -e '
      .mode == "dry-run"
      and .plan.task.slug == "duplicate-task"
      and .plan.task.description == "second run"
      and .plan.conflicts.task_exists == true
      and .plan.conflicts.active_task_exists == false
    ' >/dev/null; then
  ok "dispatch rejects active duplicates and allows reusing done task slugs"
else
  bad "dispatch duplicate guard did not match the expected done/non-done policy"
  printf '%s\n' "${duplicate_active_output}" | sed 's/^/    active: /'
  printf '%s\n' "${reuse_done_output}" | jq '.plan.conflicts, .plan.task' 2>/dev/null | sed 's/^/    done: /'
fi

# Summary
echo
echo "------------------------------------------------"
printf '  pass=%d  fail=%d\n' "${PASS}" "${FAIL}"
echo "------------------------------------------------"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
printf 'conductor sandbox tests passed\n'
