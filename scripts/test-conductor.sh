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
#   T17c approver health rejects stale scan metadata          (agent health)
#   T18  start-agent dry-run plan without side effects        (bootstrap plan)
#   T18b approver start-agent is rejected                     (daemon path)
#   T18c approver team start dry-run stays on daemon path
#   T19  stop-agent dry-run plan on fake state                (shutdown plan)
#   T19b approver stop-agent treats runtime as daemon         (daemon stop)
#   T20  protocol.sh is sourceable and exports helpers        (library contract)
#   T21  done execute is idempotent for already-done task     (bug 1)
#   T22  dispatch rejects active duplicate but reuses done     (bug 3)
#   T23  dispatch dry-run exposes advisor metadata             (phase 1)
#   T24  state transition stores advisor metadata              (phase 1)
#   T25  advisor review approve allows done                    (phase 2)
#   T26  advisor review revise blocks done                     (phase 2)
#   T27  advisor parse failure falls through                   (phase 2)
#   T28  daemon dispatch request dry-run                        (daemon)
#   T29  collab --request dry-run                               (daemon)
#   T30  registry schema v2 backward compatibility              (daemon)
#   T30b stale inbox lock is cleared before writing request     (daemon)
#   T33b tidy keeps registered live worktrees                   (live guard)
#   T33c gc keeps live orphan worktree/branch                   (live guard)
#   T33d cleanup refuses live registered worktree               (live guard)
#   T34  guard hook allows installed orchestrator lifecycle wrapper
#   T35  guard hook blocks repo-local lifecycle wrapper
#   T36  guard hook allows deployed approver send-key wrapper
#   T37  approver send-key wrapper only allows enter
#   T38  stop-agent execute clears pending approver restart state
#   T39  start-agent disables force-restart
#   T40  stop-agent disables force mode
#   T41  start-agent rejects daemon-supervised approver
#   T42  team start approver uses daemon supervisor

set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX_DIR="/tmp/conductor-sandbox-$$"
REPO_DIR="${SANDBOX_DIR}/repo"
ORCHESTRATOR_ROOT="${SANDBOX_DIR}/orchestrator"
APPROVER_ROOT="${SANDBOX_DIR}/approver"
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
mkdir -p "${HOME_DIR}/bin"
cat > "${HOME_DIR}/bin/claude" <<'BASH'
#!/usr/bin/env bash
case "${ADVISOR_STUB_VERDICT:-approve}" in
  approve)
    printf '%s\n' '{"result":"{\"verdict\":\"approve\",\"notes\":\"looks good\",\"score\":0.95}"}'
    ;;
  revise)
    printf '%s\n' '{"result":"{\"verdict\":\"revise\",\"notes\":\"fix requested\",\"score\":0.4}"}'
    ;;
  malformed)
    printf '%s\n' '{"result":"not-json"}'
    ;;
  *)
    printf 'unknown advisor stub verdict\n' >&2
    exit 2
    ;;
esac
BASH
chmod +x "${HOME_DIR}/bin/claude"

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
  # ORCHESTRATOR_TARGET_WORKSPACE_ID default: T2 dispatch and others
  # require a workspace ref to route surfaces. workspace:1 is a synthetic
  # value that satisfies the validator without needing a real cmux server.
  PATH="${HOME_DIR}/bin:${PATH}" HOME="${HOME_DIR}" \
    ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" APPROVER_ROOT="${APPROVER_ROOT}" \
    ORCHESTRATOR_TARGET_WORKSPACE_ID="${ORCHESTRATOR_TARGET_WORKSPACE_ID:-workspace:1}" \
    ZMX_SESSION="" \
    "${ROOT_DIR}/scripts/conductor.sh" "$@"
}

run_orchestrator_script() {
  local script_name="$1"
  shift
  (
    cd "${REPO_DIR}"
    HOME="${HOME_DIR}" \
    ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" \
    APPROVER_ROOT="${APPROVER_ROOT}" \
    ORCHESTRATOR_BACKEND=cmux \
      "${ROOT_DIR}/scripts/orchestrator/${script_name}" "$@"
  )
}

run_plan() {
  (
    cd "${REPO_DIR}"
    HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" APPROVER_ROOT="${APPROVER_ROOT}" \
      "${ROOT_DIR}/scripts/orchestrator/core/plan.sh" "$@"
  )
}

run_state_transition() {
  HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" APPROVER_ROOT="${APPROVER_ROOT}" \
    "${ROOT_DIR}/scripts/orchestrator/core/state-transition.sh" "$@"
}

run_guard_hook() {
  local command="$1"
  local payload
  payload="$(jq -nc --arg cmd "${command}" '{tool_name:"Bash",tool_input:{command:$cmd}}')"
  printf '%s\n' "${payload}" | "${ROOT_DIR}/hooks/general/guard-direct-session-control.sh"
}

run_approver_send_key() {
  HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" APPROVER_ROOT="${APPROVER_ROOT}" \
    "${ROOT_DIR}/scripts/orchestrator/effects/approver-send-key.sh" "$@"
}

install_zmx_stub() {
  cat > "${HOME_DIR}/bin/zmx" <<'BASH'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf '%s\n' "${ZMX_STUB_LIST:-}"
    ;;
  kill)
    exit 0
    ;;
  *)
    printf 'unsupported zmx stub command: %s\n' "${1:-}" >&2
    exit 1
    ;;
esac
BASH
  chmod +x "${HOME_DIR}/bin/zmx"
}

remove_zmx_stub() {
  rm -f "${HOME_DIR}/bin/zmx"
}

create_live_guard_worktree() {
  local slug="$1"
  local agent="${2:-codex}"
  local index="${3:-1}"
  LIVE_GUARD_BRANCH="dispatch/${slug}-${agent}-${index}"
  LIVE_GUARD_WORKTREE="${REPO_DIR}/.worktrees/dispatch-${slug}-${agent}-${index}"
  mkdir -p "${REPO_DIR}/.worktrees"
  git -C "${REPO_DIR}" worktree remove --force "${LIVE_GUARD_WORKTREE}" >/dev/null 2>&1 || true
  git -C "${REPO_DIR}" branch -D "${LIVE_GUARD_BRANCH}" >/dev/null 2>&1 || true
  git -C "${REPO_DIR}" worktree prune >/dev/null 2>&1 || true
  git -C "${REPO_DIR}" worktree add -q -b "${LIVE_GUARD_BRANCH}" "${LIVE_GUARD_WORKTREE}" >/dev/null
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
# Tolerate guard refusals (process-tree role guard rejects direct effect
# script invocation outside the daemon). Test asserts JSON shape only.
spawn_cmux="$(ORCHESTRATOR_BACKEND=cmux "${ROOT_DIR}/scripts/orchestrator/effects/spawn-surface.sh" --dry-run claude-test-1 /tmp 2>&1 || true)"
spawn_iterm="$(ORCHESTRATOR_BACKEND=iterm2 "${ROOT_DIR}/scripts/orchestrator/effects/spawn-surface.sh" --dry-run claude-test-1 /tmp 2>&1 || true)"
inject_cmux="$(ORCHESTRATOR_BACKEND=cmux "${ROOT_DIR}/scripts/orchestrator/effects/inject-takeover.sh" --dry-run "fake-id" "/tmp/wi.md" 2>&1 || true)"
inject_iterm="$(ORCHESTRATOR_BACKEND=iterm2 "${ROOT_DIR}/scripts/orchestrator/effects/inject-takeover.sh" --dry-run "fake-id" "/tmp/wi.md" 2>&1 || true)"
kill_cmux="$(ORCHESTRATOR_BACKEND=cmux "${ROOT_DIR}/scripts/orchestrator/effects/kill-surface.sh" --dry-run claude-test-1 2>&1 || true)"
kill_iterm="$(ORCHESTRATOR_BACKEND=iterm2 "${ROOT_DIR}/scripts/orchestrator/effects/kill-surface.sh" --dry-run claude-test-1 2>&1 || true)"
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

# T17c — approver health should reject stale RUNNING/scan metadata
section "T17c approver health rejects stale scan metadata"
mkdir -p "${APPROVER_ROOT}"
printf 'started_at=2026-04-15T00:00:00Z\n' > "${APPROVER_ROOT}/RUNNING"
printf '999999\n' > "${APPROVER_ROOT}/scan.pid"
printf 'codex-approver-global\n' > "${APPROVER_ROOT}/slot"
set +e
approver_health_output="$(
  cd "${REPO_DIR}" && \
    HOME="${HOME_DIR}" \
    ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" \
    APPROVER_ROOT="${APPROVER_ROOT}" \
    ORCHESTRATOR_BACKEND=cmux \
    "${ROOT_DIR}/scripts/orchestrator/health.sh" --agent-name approver 2>&1
)"
approver_health_status=$?
set -e
if [[ "${approver_health_status}" -eq 1 ]] \
  && printf '%s\n' "${approver_health_output}" | grep -F 'status=dead' >/dev/null; then
  ok "approver health reports dead when only stale RUNNING/scan metadata remains"
else
  bad "approver health accepted stale approver metadata as alive"
  printf '%s\n' "${approver_health_output}" | sed 's/^/    /'
fi
rm -f "${APPROVER_ROOT}/RUNNING" "${APPROVER_ROOT}/scan.pid" "${APPROVER_ROOT}/slot"
rmdir "${APPROVER_ROOT}" 2>/dev/null || true

# T18 — start-agent dry-run produces a plan without side effects
section "T18 start-agent dry-run is side-effect free"
# Tolerate sandbox-missing canonical runtime — start-agent.sh checks for
# ~/.orchestrator/scripts/orchestrator/* which doesn't exist in the
# isolated test sandbox. Test asserts plan content shape regardless.
start_plan="$(run_orchestrator_script start-agent.sh --dry-run 2>&1 || true)"
if [[ "${start_plan}" == *"action=start-agent"* ]] \
  && [[ "${start_plan}" == *"mode=dry-run"* ]] \
  && [[ "${start_plan}" == *"type=daemon"* ]] \
  && [[ "${start_plan}" == *"daemon="* ]] \
  && [[ ! -e "${ORCHESTRATOR_ROOT}/agents/orchestrator" ]]; then
  ok "start-agent dry-run returns a valid plan without creating sentinel state"
else
  bad "start-agent dry-run plan or side-effect check failed"
  printf '%s\n' "${start_plan}" | head -5
fi

# T18b — approver start-agent is rejected because it is daemon-supervised
section "T18b approver start-agent is rejected"
set +e
approver_start_plan="$(run_orchestrator_script start-agent.sh --agent-name approver --dry-run 2>&1)"
approver_start_status=$?
set -e
if [[ "${approver_start_status}" -ne 0 ]] \
  && printf '%s\n' "${approver_start_plan}" | grep -F "daemon-supervised" >/dev/null; then
  ok "approver start-agent refuses daemon-supervised startup"
else
  bad "approver start-agent did not reject daemon-supervised startup"
  printf '%s\n' "${approver_start_plan}" | head -5
fi

# T18c — team.sh dry-run routes approver start through the daemon supervisor
section "T18c approver team start stays on daemon path"
approver_team_start_plan="$(
  cd "${REPO_DIR}" && \
    HOME="${HOME_DIR}" \
    ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" \
    APPROVER_ROOT="${APPROVER_ROOT}" \
    ORCHESTRATOR_BACKEND=cmux \
      "${ROOT_DIR}/scripts/orchestrator/team.sh" start approver --dry-run
)"
if printf '%s\n' "${approver_team_start_plan}" | jq -e '
    .action == "team-start"
    and .agent == "approver"
    and .mode == "dry-run"
    and .path == "daemon-supervisor"
  ' >/dev/null; then
  ok "team.sh dry-run keeps approver on the daemon-supervisor path"
else
  bad "team.sh dry-run did not report the daemon-supervisor path"
  printf '%s\n' "${approver_team_start_plan}" | jq . 2>/dev/null | head -20
fi

# T19 — stop-agent dry-run handles imaginary running state without side effects
section "T19 stop-agent dry-run plans cleanup for stale sentinel state"
mkdir -p "${ORCHESTRATOR_ROOT}/agents/orchestrator"
printf 'started_at=2026-04-09T00:00:00Z\n' > "${ORCHESTRATOR_ROOT}/agents/orchestrator/RUNNING"
printf '999999\n' > "${ORCHESTRATOR_ROOT}/agents/orchestrator/pid"
printf 'claude-orchestrator-global\n' > "${ORCHESTRATOR_ROOT}/agents/orchestrator/slot"
printf 'cmux\n' > "${ORCHESTRATOR_ROOT}/agents/orchestrator/backend"
printf 'surface:999\n' > "${ORCHESTRATOR_ROOT}/agents/orchestrator/surface_id"
stop_plan="$(run_orchestrator_script stop-agent.sh --dry-run)"
if printf '%s\n' "${stop_plan}" | jq -e '
    .action == "stop-agent"
    and .mode == "dry-run"
    and .strategy == "stale-cleanup"
    and .target.slot == "claude-orchestrator-global"
    and .target.backend == "cmux"
  ' >/dev/null \
  && [[ -f "${ORCHESTRATOR_ROOT}/agents/orchestrator/RUNNING" ]] \
  && [[ -f "${ORCHESTRATOR_ROOT}/agents/orchestrator/pid" ]]; then
  ok "stop-agent dry-run returns a valid plan and leaves fake sentinel files untouched"
else
  bad "stop-agent dry-run plan or sentinel preservation check failed"
  printf '%s\n' "${stop_plan}" | jq . 2>/dev/null | head -20
fi

# T19b — approver stop-agent treats runtime as a daemon-backed process
section "T19b approver stop-agent treats runtime as daemon"
mkdir -p "${APPROVER_ROOT}"
printf 'started_at=2026-04-09T00:00:00Z\n' > "${APPROVER_ROOT}/RUNNING"
printf '999998\n' > "${APPROVER_ROOT}/pid"
printf 'daemon\n' > "${APPROVER_ROOT}/backend"
approver_stop_plan="$(run_orchestrator_script stop-agent.sh --agent-name approver --dry-run)"
if printf '%s\n' "${approver_stop_plan}" | jq -e '
    .action == "stop-agent"
    and .mode == "dry-run"
    and .type == "daemon"
    and .strategy == "stale-cleanup"
    and .target.slot == null
    and .target.backend == "daemon"
  ' >/dev/null \
  && [[ -f "${APPROVER_ROOT}/RUNNING" ]]; then
  ok "approver stop-agent dry-run treats approver as a daemon runtime"
else
  bad "approver stop-agent dry-run did not report daemon shutdown"
  printf '%s\n' "${approver_stop_plan}" | jq . 2>/dev/null | head -20
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

# T23 — dispatch dry-run exposes advisor metadata in the reviewable plan
section "T23 dispatch dry-run exposes advisor metadata"
advisor_dispatch="$(run_conductor dispatch advisor-meta-task "wire metadata only" --dry-run --advisor-mode review --executor-tier fast)"
if printf '%s\n' "${advisor_dispatch}" | jq -e '
    .mode == "dry-run"
    and .plan.request.advisor_mode == "review"
    and .plan.request.executor_tier == "fast"
    and .plan.task.metadata.advisor_mode == "review"
    and .plan.task.metadata.executor_tier == "fast"
    and .plan.agents[0].executor_tier == "fast"
  ' >/dev/null; then
  ok "dispatch dry-run surfaces advisor metadata in the plan JSON"
else
  bad "dispatch dry-run omitted advisor metadata"
  printf '%s\n' "${advisor_dispatch}" | jq '.plan.request, .plan.task, .plan.agents[0]' 2>/dev/null | head -30
fi

# T24 — pure state transition persists advisor metadata for tasks and agents
section "T24 state transition stores advisor metadata"
base_state='{"version":1,"projects":{},"tasks":{},"agents":{}}'
advisor_plan="$(run_plan \
  --root "${ORCHESTRATOR_ROOT}" \
  --state-json "${base_state}" \
  --slug advisor-state-task \
  --description "persist metadata" \
  --cwd "${REPO_DIR}" \
  --project-name "$(basename "${REPO_DIR}")" \
  --agent codex \
  --advisor-mode review \
  --executor-tier capable
)"
advisor_state="$(run_state_transition \
  --mode dispatch \
  --now "2026-04-10T00:00:00Z" \
  --state-json "${base_state}" \
  --plan-json "${advisor_plan}"
)"
if printf '%s\n' "${advisor_state}" | jq -e '
    .tasks["advisor-state-task"].request_metadata.advisor_mode == "review"
    and .tasks["advisor-state-task"].request_metadata.executor_tier == "capable"
    and (.tasks["advisor-state-task"].agents | length) == 1
    and (.tasks["advisor-state-task"].agents[0] as $slot | .agents[$slot].advisor_mode == "review")
    and (.tasks["advisor-state-task"].agents[0] as $slot | .agents[$slot].executor_tier == "capable")
  ' >/dev/null; then
  ok "state transition keeps advisor metadata on both task and agent state"
else
  bad "state transition dropped advisor metadata"
  printf '%s\n' "${advisor_state}" | jq '.tasks["advisor-state-task"], .agents' 2>/dev/null | head -30
fi

# T25 — advisor review approve allows the done transition to proceed
section "T25 advisor review approve allows done"
mkdir -p "${ORCHESTRATOR_ROOT}/tasks" "${ORCHESTRATOR_ROOT}/done"
printf '# Work Item: advisor-review-approve\n' > "${ORCHESTRATOR_ROOT}/tasks/advisor-review-approve.md"
printf 'advisor review change\n' >> "${REPO_DIR}/README.md"
jq -n \
  --arg project_path "${REPO_DIR}" \
  --arg task_path "${ORCHESTRATOR_ROOT}/tasks/advisor-review-approve.md" \
  --arg done_report_path "${ORCHESTRATOR_ROOT}/done/advisor-review-approve.md" \
  '{
    version: 1,
    updated_at: "2026-04-10T00:00:00Z",
    projects: {repo: {slug: "repo", path: $project_path, tasks: ["advisor-review-approve"]}},
    tasks: {
      "advisor-review-approve": {
        slug: "advisor-review-approve",
        status: "in_progress",
        description: "exercise advisor approve",
        project: "repo",
        project_path: $project_path,
        work_item_path: $task_path,
        done_report_path: $done_report_path,
        request_metadata: {advisor_mode: "review", executor_tier: "fast"},
        agents: []
      }
    },
    agents: {}
  }' > "${ORCHESTRATOR_ROOT}/state.json"
set +e
advisor_approve_output="$(ADVISOR_STUB_VERDICT=approve run_conductor done advisor-review-approve --execute 2>&1)"
advisor_approve_status=$?
set -e
if [[ "${advisor_approve_status}" -eq 0 ]] \
  && printf '%s\n' "${advisor_approve_output}" | jq -e '.mode == "execute"' >/dev/null \
  && jq -e '.tasks["advisor-review-approve"].status == "done"' "${ORCHESTRATOR_ROOT}/state.json" >/dev/null \
  && grep -F '"event":"advisor-review"' "${ORCHESTRATOR_ROOT}/activity.jsonl" | grep -F '"verdict":"approve"' >/dev/null; then
  ok "advisor approve verdict allows done transition"
else
  bad "advisor approve verdict did not allow done"
  printf '%s\n' "${advisor_approve_output}" | sed 's/^/    /'
  jq '.tasks["advisor-review-approve"]' "${ORCHESTRATOR_ROOT}/state.json" 2>/dev/null | sed 's/^/    /'
fi

# T26 — advisor review revise blocks the done transition
section "T26 advisor review revise blocks done"
printf '# Work Item: advisor-review-revise\n' > "${ORCHESTRATOR_ROOT}/tasks/advisor-review-revise.md"
jq -n \
  --arg project_path "${REPO_DIR}" \
  --arg task_path "${ORCHESTRATOR_ROOT}/tasks/advisor-review-revise.md" \
  --arg done_report_path "${ORCHESTRATOR_ROOT}/done/advisor-review-revise.md" \
  '{
    version: 1,
    updated_at: "2026-04-10T00:00:00Z",
    projects: {repo: {slug: "repo", path: $project_path, tasks: ["advisor-review-revise"]}},
    tasks: {
      "advisor-review-revise": {
        slug: "advisor-review-revise",
        status: "in_progress",
        description: "exercise advisor revise",
        project: "repo",
        project_path: $project_path,
        work_item_path: $task_path,
        done_report_path: $done_report_path,
        request_metadata: {advisor_mode: "review", executor_tier: "fast"},
        agents: []
      }
    },
    agents: {}
  }' > "${ORCHESTRATOR_ROOT}/state.json"
set +e
advisor_revise_output="$(ADVISOR_STUB_VERDICT=revise run_conductor done advisor-review-revise --execute 2>&1)"
advisor_revise_status=$?
set -e
if [[ "${advisor_revise_status}" -eq 20 ]] \
  && printf '%s\n' "${advisor_revise_output}" | grep -F "advisor requested revision" >/dev/null \
  && jq -e '.tasks["advisor-review-revise"].status == "in_progress"' "${ORCHESTRATOR_ROOT}/state.json" >/dev/null \
  && [[ ! -f "${ORCHESTRATOR_ROOT}/done/advisor-review-revise.md" ]] \
  && grep -F '"event":"advisor-review"' "${ORCHESTRATOR_ROOT}/activity.jsonl" | grep -F '"verdict":"revise"' >/dev/null; then
  ok "advisor revise verdict blocks done transition"
else
  bad "advisor revise verdict did not block done"
  printf '%s\n' "${advisor_revise_output}" | sed 's/^/    /'
  jq '.tasks["advisor-review-revise"]' "${ORCHESTRATOR_ROOT}/state.json" 2>/dev/null | sed 's/^/    /'
fi

# T27 — advisor parse failures are recorded but do not block done
section "T27 advisor parse failure falls through"
printf '# Work Item: advisor-review-malformed\n' > "${ORCHESTRATOR_ROOT}/tasks/advisor-review-malformed.md"
jq -n \
  --arg project_path "${REPO_DIR}" \
  --arg task_path "${ORCHESTRATOR_ROOT}/tasks/advisor-review-malformed.md" \
  --arg done_report_path "${ORCHESTRATOR_ROOT}/done/advisor-review-malformed.md" \
  '{
    version: 1,
    updated_at: "2026-04-10T00:00:00Z",
    projects: {repo: {slug: "repo", path: $project_path, tasks: ["advisor-review-malformed"]}},
    tasks: {
      "advisor-review-malformed": {
        slug: "advisor-review-malformed",
        status: "in_progress",
        description: "exercise advisor malformed response",
        project: "repo",
        project_path: $project_path,
        work_item_path: $task_path,
        done_report_path: $done_report_path,
        request_metadata: {advisor_mode: "review", executor_tier: "fast"},
        agents: []
      }
    },
    agents: {}
  }' > "${ORCHESTRATOR_ROOT}/state.json"
set +e
advisor_malformed_output="$(ADVISOR_STUB_VERDICT=malformed run_conductor done advisor-review-malformed --execute 2>&1)"
advisor_malformed_status=$?
set -e
if [[ "${advisor_malformed_status}" -eq 0 ]] \
  && printf '%s\n' "${advisor_malformed_output}" | jq -e '.mode == "execute"' >/dev/null \
  && ! printf '%s\n' "${advisor_malformed_output}" | grep -F "parse error" >/dev/null \
  && jq -e '.tasks["advisor-review-malformed"].status == "done"' "${ORCHESTRATOR_ROOT}/state.json" >/dev/null \
  && grep -F '"event":"advisor-review-failed"' "${ORCHESTRATOR_ROOT}/activity.jsonl" | grep -F '"reason":"parse-failed"' >/dev/null; then
  ok "advisor parse failure falls through to done transition"
else
  bad "advisor parse failure did not fall through cleanly"
  printf '%s\n' "${advisor_malformed_output}" | sed 's/^/    /'
  jq '.tasks["advisor-review-malformed"]' "${ORCHESTRATOR_ROOT}/state.json" 2>/dev/null | sed 's/^/    /'
fi

# T28 — daemon processes a dispatch request in dry-run mode and archives it
section "T28 daemon dispatch --request dry-run"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}/inbox" "${ORCHESTRATOR_ROOT}/outbox" "${ORCHESTRATOR_ROOT}/inbox-processed"
dispatch_req="${ORCHESTRATOR_ROOT}/inbox/req-daemon-dispatch.md"
dispatch_res="${ORCHESTRATOR_ROOT}/outbox/res-daemon-dispatch.md"
cat > "${dispatch_req}" <<EOF
---
schema_version: 1
id: daemon-dispatch
type: dispatch
slug: daemon-dispatch
requester:
  slot: claude-base
  project: ${REPO_DIR}
  session_id: test
  cmux_workspace_id: workspace:1
created_at: 2026-04-14T00:00:00Z
response_path: ${dispatch_res}
timeout_seconds: 30
---

## Payload
- slug: daemon-dispatch
- description: Exercise daemon dispatch dry run
- worker_family: codex
- dry_run: true
- no_worktree: false
EOF
set +e
daemon_dispatch_output="$(run_orchestrator_script daemon.sh --once 2>&1)"
daemon_dispatch_status=$?
set -e
if [[ "${daemon_dispatch_status}" -eq 0 ]] \
  && [[ -f "${dispatch_res}" ]] \
  && [[ -f "${ORCHESTRATOR_ROOT}/inbox-processed/req-daemon-dispatch.md" ]] \
  && grep -F 'status: ok' "${dispatch_res}" >/dev/null \
  && grep -F '"mode": "dry-run"' "${dispatch_res}" >/dev/null \
  && grep -F 'codex-' "${dispatch_res}" >/dev/null; then
  ok "daemon handled dispatch dry-run request and archived it"
else
  bad "daemon dispatch request handling failed"
  printf '%s\n' "${daemon_dispatch_output}" | sed 's/^/    daemon: /'
  [[ -f "${dispatch_res}" ]] && sed -n '1,80p' "${dispatch_res}" | sed 's/^/    response: /'
fi

# T29 — collab supports --request dry-run without mutating state
section "T29 collab --request dry-run"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}/inbox" "${ORCHESTRATOR_ROOT}/outbox"
collab_req="${ORCHESTRATOR_ROOT}/inbox/req-collab-request.md"
cat > "${collab_req}" <<EOF
---
schema_version: 1
id: collab-request
type: collab
slug: daemon-collab
requester:
  slot: claude-base
  project: ${REPO_DIR}
  session_id: test
  cmux_workspace_id: workspace:1
created_at: 2026-04-14T00:00:00Z
response_path: ${ORCHESTRATOR_ROOT}/outbox/res-collab-request.md
timeout_seconds: 30
---

## Payload
- slug: daemon-collab
- description: Exercise collab request dry run
- dry_run: true
- advisor_mode: review
- executor_tier: fast
EOF
collab_request_output="$(run_conductor collab --request "${collab_req}" --dry-run)"
if printf '%s\n' "${collab_request_output}" | jq -e '
    .mode == "dry-run"
    and .status == "ok"
    and .base_slug == "daemon-collab"
    and .claude_worker.output.plan.task.slug == "daemon-collab-claude"
    and .codex_worker.output.plan.task.slug == "daemon-collab-codex"
    and .claude_worker.output.plan.request.advisor_mode == "review"
    and .codex_worker.output.plan.request.executor_tier == "fast"
  ' >/dev/null; then
  ok "collab --request dry-run derives both worker dispatch plans"
else
  bad "collab --request dry-run output was unexpected"
  printf '%s\n' "${collab_request_output}" | jq . 2>/dev/null | head -80
fi

# T30 — registry updates upgrade v1 files to schema v2 and preserve agents
section "T30 registry schema v2 backward compatibility"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}/agents"
printf '%s\n' '{"schema_version":1,"agents":{"orchestrator":{"status":"stopped","pid":null}}}' > "${ORCHESTRATOR_ROOT}/agents/registry.json"
set +e
registry_update_output="$(
  HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" bash -lc '
    . "'"${ROOT_DIR}"'/scripts/orchestrator/protocol.sh"
    _locked_registry_update "'"${ORCHESTRATOR_ROOT}"'/agents/registry.json" ".agents[\"orchestrator\"].type = \"daemon\" | .agents[\"orchestrator\"].status = \"running\""
  ' 2>&1
)"
registry_update_status=$?
set -e
if [[ "${registry_update_status}" -eq 0 ]] \
  && jq -e '.schema_version == 2 and .agents.orchestrator.type == "daemon" and .agents.orchestrator.status == "running"' "${ORCHESTRATOR_ROOT}/agents/registry.json" >/dev/null; then
  ok "registry v1 file is upgraded to schema_version 2 with type metadata"
else
  bad "registry v2 compatibility update failed"
  printf '%s\n' "${registry_update_output}" | sed 's/^/    /'
  [[ -f "${ORCHESTRATOR_ROOT}/agents/registry.json" ]] && jq . "${ORCHESTRATOR_ROOT}/agents/registry.json" 2>/dev/null | sed 's/^/    /'
fi

# T30b — request writer should clear stale inbox lock dirs
section "T30b orchestrator request clears stale inbox lock"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}/inbox" "${ORCHESTRATOR_ROOT}/outbox" "${ORCHESTRATOR_ROOT}/locks"
mkdir -p "${ORCHESTRATOR_ROOT}/locks/inbox.lock.d"
touch -t 202604140000 "${ORCHESTRATOR_ROOT}/locks/inbox.lock.d"
set +e
stale_lock_output="$(
  HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" APPROVER_ROOT="${APPROVER_ROOT}" bash -lc '
    . "'"${ROOT_DIR}"'/scripts/orchestrator/protocol.sh"
    _orchestrator_write_request "stale-lock-test" "status" "" "ping" "5"
  ' 2>&1
)"
stale_lock_status=$?
set -e
if [[ "${stale_lock_status}" -eq 0 ]] \
  && [[ -f "${ORCHESTRATOR_ROOT}/inbox/req-stale-lock-test.md" ]] \
  && [[ ! -d "${ORCHESTRATOR_ROOT}/locks/inbox.lock.d" ]]; then
  ok "request writer removes stale inbox lock and writes the request"
else
  bad "request writer failed to recover from stale inbox lock"
  printf '%s\n' "${stale_lock_output}" | sed 's/^/    /'
  find "${ORCHESTRATOR_ROOT}" -maxdepth 2 -mindepth 1 | sed 's/^/    /'
fi

# T31 — state-read rejects blank state files
section "T31 state-read rejects blank state files"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}"
printf '\n' > "${ORCHESTRATOR_ROOT}/state.json"
set +e
blank_state_output="$(
  HOME="${HOME_DIR}" ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT}" \
    "${ROOT_DIR}/scripts/orchestrator/core/state-read.sh" --root "${ORCHESTRATOR_ROOT}" 2>&1
)"
blank_state_status=$?
set -e
if [[ "${blank_state_status}" -ne 0 ]] \
  && printf '%s\n' "${blank_state_output}" | grep -F "state file is blank" >/dev/null; then
  ok "state-read fails loudly on blank state.json"
else
  bad "state-read accepted a blank state.json"
  printf '%s\n' "${blank_state_output}" | sed 's/^/    /'
fi

# T32 — resume does not overwrite blank state files
section "T32 resume refuses blank state without clobbering it"
rm -rf "${ORCHESTRATOR_ROOT}" "${HOME_DIR}/.codex"
mkdir -p "${ORCHESTRATOR_ROOT}" "${HOME_DIR}/.codex"
printf '\n' > "${ORCHESTRATOR_ROOT}/state.json"
printf '%s\n' '{"id":"resume-1","thread_name":"resume-blank-state","updated_at":"2026-04-14T00:00:00Z"}' > "${HOME_DIR}/.codex/session_index.jsonl"
set +e
resume_blank_output="$(run_conductor resume resume-blank-state --dry-run --agent codex 2>&1)"
resume_blank_status=$?
set -e
resume_blank_state_bytes="$(wc -c < "${ORCHESTRATOR_ROOT}/state.json" | tr -d ' ')"
if [[ "${resume_blank_status}" -ne 0 ]] \
  && printf '%s\n' "${resume_blank_output}" | grep -F "failed to read orchestrator state" >/dev/null \
  && [[ "${resume_blank_state_bytes}" == "1" ]]; then
  ok "resume stops on blank state.json without overwriting it"
else
  bad "resume did not guard against blank state.json"
  printf '%s\n' "${resume_blank_output}" | sed 's/^/    /'
  printf '    state.json bytes = %s\n' "${resume_blank_state_bytes}"
fi

# T33 — cleanup removes stale task entries with no remaining agents
section "T33 cleanup removes stale task entries"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}"
jq -n '{
  version: 1,
  updated_at: "2026-04-14T00:00:00Z",
  projects: {
    repo: {
      slug: "repo",
      path: "/tmp/repo",
      tasks: ["cleanup-me"],
      updated_at: "2026-04-14T00:00:00Z"
    }
  },
  tasks: {
    "cleanup-me": {
      slug: "cleanup-me",
      status: "in_progress",
      project: "repo",
      project_path: "/tmp/repo",
      agents: [],
      updated_at: "2026-04-14T00:00:00Z"
    }
  },
  agents: {}
}' > "${ORCHESTRATOR_ROOT}/state.json"
cleanup_stale_output="$(run_conductor cleanup cleanup-me --execute)"
if printf '%s\n' "${cleanup_stale_output}" | jq -e '.mode == "execute" and .action == "cleanup"' >/dev/null \
  && jq -e '.tasks["cleanup-me"] == null and (.projects.repo.tasks | index("cleanup-me")) == null' "${ORCHESTRATOR_ROOT}/state.json" >/dev/null; then
  ok "cleanup removes stale task entries once no agents remain"
else
  bad "cleanup left stale task state behind"
  printf '%s\n' "${cleanup_stale_output}" | sed 's/^/    /'
  jq . "${ORCHESTRATOR_ROOT}/state.json" 2>/dev/null | sed 's/^/    /'
fi

# T33b — tidy must not reap a registered worktree owned by a live zmx start_dir
section "T33b tidy keeps registered live worktree"
install_zmx_stub
create_live_guard_worktree "very-long-live-guard-target" codex 1
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}"
zmx_live_line="name=codex-unrelated-slot pid=4242 clients=1 start_dir=${LIVE_GUARD_WORKTREE}"
tidy_live_output="$(ZMX_STUB_LIST="${zmx_live_line}" run_conductor tidy --execute --all)"
if [[ -d "${LIVE_GUARD_WORKTREE}" ]] \
  && git -C "${REPO_DIR}" rev-parse --verify "${LIVE_GUARD_BRANCH}" >/dev/null 2>&1 \
  && printf '%s\n' "${tidy_live_output}" | jq -e --arg path "${LIVE_GUARD_WORKTREE}" '
    .mode == "execute"
    and .cleaned == 0
    and .skipped_running >= 1
    and ([.candidates[] | select(.path == $path and .classification == "running" and .zmx_status == "alive")] | length) == 1
  ' >/dev/null; then
  ok "tidy keeps registered live worktrees based on start_dir, not slot reconstruction"
else
  bad "tidy reaped or misclassified a live registered worktree"
  printf '%s\n' "${tidy_live_output}" | jq . 2>/dev/null | sed 's/^/    /'
fi

# T33c — gc must not classify a registered worktree/branch as orphan while zmx owns it
section "T33c gc keeps live orphan worktree and branch"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}"
printf '%s\n' '{"version":1,"updated_at":"2026-04-28T00:00:00Z","projects":{},"tasks":{},"agents":{}}' > "${ORCHESTRATOR_ROOT}/state.json"
gc_live_output="$(ZMX_STUB_LIST="${zmx_live_line}" run_conductor gc --execute)"
if [[ -d "${LIVE_GUARD_WORKTREE}" ]] \
  && git -C "${REPO_DIR}" rev-parse --verify "${LIVE_GUARD_BRANCH}" >/dev/null 2>&1 \
  && printf '%s\n' "${gc_live_output}" | jq -e --arg path "${LIVE_GUARD_WORKTREE}" --arg branch "${LIVE_GUARD_BRANCH}" '
    .mode == "execute"
    and .orphans.worktrees == 0
    and .orphans.branches == 0
    and ([.orphans.details[]? | select((.path? == $path) or (.branch? == $branch))] | length) == 0
  ' >/dev/null; then
  ok "gc skips orphan worktree/branch cleanup when git and zmx show the worker is still live"
else
  bad "gc still classified a live worktree or branch as orphan"
  printf '%s\n' "${gc_live_output}" | jq . 2>/dev/null | sed 's/^/    /'
fi

# T33d — cleanup must refuse to remove a live registered worktree without --force
section "T33d cleanup refuses live registered worktree"
rm -rf "${ORCHESTRATOR_ROOT}"
mkdir -p "${ORCHESTRATOR_ROOT}"
jq -n \
  --arg repo_dir "${REPO_DIR}" \
  --arg worktree "${LIVE_GUARD_WORKTREE}" \
  --arg branch "${LIVE_GUARD_BRANCH}" \
  '{
    version: 1,
    updated_at: "2026-04-28T00:00:00Z",
    projects: {
      repo: {
        slug: "repo",
        path: $repo_dir,
        tasks: ["cleanup-live-guard"],
        updated_at: "2026-04-28T00:00:00Z"
      }
    },
    tasks: {
      "cleanup-live-guard": {
        slug: "cleanup-live-guard",
        status: "done",
        project: "repo",
        project_path: $repo_dir,
        worktree_path: $worktree,
        worktree_branch: $branch,
        agents: [],
        updated_at: "2026-04-28T00:00:00Z"
      }
    },
    agents: {}
  }' > "${ORCHESTRATOR_ROOT}/state.json"
set +e
cleanup_live_output="$(ZMX_STUB_LIST="${zmx_live_line}" run_conductor cleanup cleanup-live-guard --execute 2>&1)"
cleanup_live_status=$?
set -e
if [[ "${cleanup_live_status}" -ne 0 ]] \
  && [[ -d "${LIVE_GUARD_WORKTREE}" ]] \
  && git -C "${REPO_DIR}" rev-parse --verify "${LIVE_GUARD_BRANCH}" >/dev/null 2>&1 \
  && jq -e '.tasks["cleanup-live-guard"] != null' "${ORCHESTRATOR_ROOT}/state.json" >/dev/null \
  && printf '%s\n' "${cleanup_live_output}" | grep -F "cleanup refused for 'cleanup-live-guard'" >/dev/null \
  && printf '%s\n' "${cleanup_live_output}" | grep -F "registered git worktree" >/dev/null \
  && printf '%s\n' "${cleanup_live_output}" | grep -F "zmx start_dir=${LIVE_GUARD_WORKTREE}" >/dev/null; then
  ok "cleanup refuses live worktree removal until the caller explicitly forces it"
else
  bad "cleanup did not block a live registered worktree"
  printf '%s\n' "${cleanup_live_output}" | sed 's/^/    /'
  jq . "${ORCHESTRATOR_ROOT}/state.json" 2>/dev/null | sed 's/^/    /'
fi
git -C "${REPO_DIR}" worktree remove --force "${LIVE_GUARD_WORKTREE}" >/dev/null 2>&1 || rm -rf "${LIVE_GUARD_WORKTREE}" >/dev/null 2>&1 || true
git -C "${REPO_DIR}" branch -D "${LIVE_GUARD_BRANCH}" >/dev/null 2>&1 || true
remove_zmx_stub

# T34 — guard hook allows installed orchestrator lifecycle wrapper
section "T34 guard hook allows installed orchestrator lifecycle wrapper"
set +e
run_guard_hook "${HOME}/.orchestrator/scripts/orchestrator/start-agent.sh --agent-name approver --execute" >/dev/null 2>&1
guard_allow_status=$?
set -e
if [[ "${guard_allow_status}" -eq 0 ]]; then
  ok "guard hook allows installed ~/.orchestrator lifecycle wrapper"
else
  bad "guard hook blocked installed ~/.orchestrator lifecycle wrapper"
fi

# T35 — guard hook still blocks repo-local lifecycle wrapper
section "T35 guard hook blocks repo-local lifecycle wrapper"
set +e
run_guard_hook "${ROOT_DIR}/scripts/orchestrator/start-agent.sh --agent-name approver --execute" >/dev/null 2>&1
guard_block_status=$?
set -e
if [[ "${guard_block_status}" -eq 2 ]]; then
  ok "guard hook blocks repo-local lifecycle wrapper"
else
  bad "guard hook did not block repo-local lifecycle wrapper"
  printf '    exit_status=%s\n' "${guard_block_status}"
fi

# T36 — guard hook allows deployed approver send-key wrapper
section "T36 guard hook allows deployed approver send-key wrapper"
set +e
run_guard_hook "${HOME}/.approver/send-key.sh --surface surface:1 --workspace workspace:1 enter" >/dev/null 2>&1
guard_send_key_status=$?
set -e
if [[ "${guard_send_key_status}" -eq 0 ]]; then
  ok "guard hook allows deployed approver send-key wrapper"
else
  bad "guard hook blocked deployed approver send-key wrapper"
  printf '    exit_status=%s\n' "${guard_send_key_status}"
fi

# T37 — approver send-key wrapper only allows enter
section "T37 approver send-key wrapper only allows enter"
set +e
approver_send_key_output="$(run_approver_send_key --surface surface:1 --workspace workspace:1 escape 2>&1)"
approver_send_key_status=$?
set -e
if [[ "${approver_send_key_status}" -ne 0 ]] \
  && printf '%s\n' "${approver_send_key_output}" | grep -F "only --surface <id> --workspace <id> enter is allowed" >/dev/null; then
  ok "approver send-key wrapper rejects non-enter keys"
else
  bad "approver send-key wrapper accepted unsupported keys"
  printf '%s\n' "${approver_send_key_output}" | sed 's/^/    /'
fi

# T38 — stop-agent execute clears pending approver restart state
section "T38 stop-agent execute clears pending approver restart state"
mkdir -p "${APPROVER_ROOT}"
printf 'daemon\n' > "${APPROVER_ROOT}/backend"
printf 'workspace:27\n' > "${APPROVER_ROOT}/workspace_id"
printf 'surface:998\n' > "${APPROVER_ROOT}/surface_id"
printf 'workspace:27\n' > "${APPROVER_ROOT}/pending_workspace_id"
printf 'surface:999\n' > "${APPROVER_ROOT}/pending_surface_id"
printf 'started_at=2026-04-15T00:00:00Z\n' > "${APPROVER_ROOT}/RUNNING"
set +e
approver_stop_execute_output="$(run_orchestrator_script stop-agent.sh --agent-name approver --execute 2>&1)"
approver_stop_execute_status=$?
set -e
if [[ "${approver_stop_execute_status}" -eq 0 ]] \
  && [[ ! -e "${APPROVER_ROOT}/pending_surface_id" ]] \
  && [[ ! -e "${APPROVER_ROOT}/pending_workspace_id" ]] \
  && [[ ! -e "${APPROVER_ROOT}/surface_id" ]] \
  && [[ -f "${APPROVER_ROOT}/DISABLED" ]]; then
  ok "stop-agent execute clears pending approver restart state and disables supervision"
else
  bad "stop-agent execute did not clear pending approver restart state"
  printf '%s\n' "${approver_stop_execute_output}" | sed 's/^/    /'
fi

# T39 — start-agent disables force-restart
section "T39 start-agent disables force-restart"
start_agent_force_block="$(cat "${ROOT_DIR}/scripts/orchestrator/start-agent.sh")"
if printf '%s\n' "${start_agent_force_block}" | grep -F 'die "--force-restart is disabled; use graceful stop then start"' >/dev/null \
  && ! printf '%s\n' "${start_agent_force_block}" | grep -F 'force=0' >/dev/null \
  && ! printf '%s\n' "${start_agent_force_block}" | grep -F 'stop-agent.sh" --agent-name "${agent_name}" --execute --force' >/dev/null; then
  ok "start-agent disables force-restart and no longer contains force cleanup paths"
else
  bad "start-agent still contains force-restart lifecycle"
  printf '%s\n' "${start_agent_force_block}" | sed 's/^/    /'
fi

# T40 — stop-agent disables force mode
section "T40 stop-agent disables force mode"
stop_agent_block="$(cat "${ROOT_DIR}/scripts/orchestrator/stop-agent.sh")"
if printf '%s\n' "${stop_agent_block}" | grep -F 'die "--force is disabled; stop-agent always uses graceful stop"' >/dev/null \
  && ! printf '%s\n' "${stop_agent_block}" | grep -F "strategy='force'" >/dev/null \
  && printf '%s\n' "${stop_agent_block}" | grep -F 'enabled: $alive' >/dev/null; then
  ok "stop-agent uses graceful shutdown only"
else
  bad "stop-agent still contains force mode"
  printf '%s\n' "${stop_agent_block}" | sed 's/^/    /'
fi

# T41 — start-agent rejects daemon-supervised approver and no longer carries scanner launch logic
section "T41 start-agent rejects daemon-supervised approver"
approver_start_block="$(cat "${ROOT_DIR}/scripts/orchestrator/start-agent.sh")"
if printf '%s\n' "${approver_start_block}" | grep -F "daemon-supervised; use team.sh start" >/dev/null \
  && ! printf '%s\n' "${approver_start_block}" | grep -F 'bootstrap-approver.md' >/dev/null \
  && ! printf '%s\n' "${approver_start_block}" | grep -F 'approver-run.sh' >/dev/null; then
  ok "start-agent rejects daemon-supervised approver and no longer contains scanner launch logic"
else
  bad "start-agent still contains the old approver launch path"
  printf '%s\n' "${approver_start_block}" | sed 's/^/    /'
fi

# T42 — team.sh restart approver uses the daemon supervisor path
section "T42 team.sh restart approver uses daemon supervisor"
team_block="$(cat "${ROOT_DIR}/scripts/orchestrator/team.sh")"
if printf '%s\n' "${team_block}" | grep -F 'team_approver_restart' >/dev/null \
  && printf '%s\n' "${team_block}" | grep -F '"${SCRIPT_DIR}/daemon.sh" --ensure-approver' >/dev/null; then
  ok "team.sh restart approver routes through the daemon supervisor"
else
  bad "team.sh restart approver did not route through the daemon supervisor"
  printf '%s\n' "${team_block}" | sed 's/^/    /'
fi

# T43 — gc never mutates in-progress tasks
section "T43 gc leaves in-progress tasks alone"
gc_block="$(awk '
  /gc_command\(\)/ {capture=1}
  capture {print}
  /^}/ && capture {exit}
' "${ROOT_DIR}/scripts/conductor.sh")"
if printf '%s\n' "${gc_block}" | grep -F 'cmux_snapshot="$(cmux_surface_snapshot)"' >/dev/null \
  && printf '%s\n' "${gc_block}" | grep -F 'surface_alive=1' >/dev/null \
  && printf '%s\n' "${gc_block}" | grep -F 'in_progress)' >/dev/null \
  && printf '%s\n' "${gc_block}" | grep -F 'action="skip"' >/dev/null \
  && ! printf '%s\n' "${gc_block}" | grep -F 'action="mark-failed"' >/dev/null; then
  ok "gc does not mutate in-progress tasks"
else
  bad "gc still mutates in-progress tasks"
  printf '%s\n' "${gc_block}" | sed 's/^/    /'
fi

# T44 — gc reports orphan zmx sessions without killing them
section "T44 gc only reports orphan zmx sessions"
gc_orphan_block="$(awk '
  /# 1\. Orphan zmx sessions: report only\./ {capture=1}
  capture {print}
  /# 2\. Orphan worktrees:/ {exit}
' "${ROOT_DIR}/scripts/conductor.sh")"
if printf '%s\n' "${gc_orphan_block}" | grep -F 'action:"report-only"' >/dev/null \
  && ! printf '%s\n' "${gc_orphan_block}" | grep -F 'zmx kill "${zname}"' >/dev/null \
  && ! printf '%s\n' "${gc_orphan_block}" | grep -F 'rm -f "${_zmx_dir}/${zname}"' >/dev/null; then
  ok "gc leaves orphan zmx sessions untouched"
else
  bad "gc still mutates orphan zmx sessions"
  printf '%s\n' "${gc_orphan_block}" | sed 's/^/    /'
fi

# T45 — execute mode forbids --no-worktree
section "T45 dispatch execute rejects no-worktree"
set +e
dispatch_no_worktree_output="$(bash "${ROOT_DIR}/scripts/conductor.sh" dispatch sample-task "desc" --execute --no-worktree 2>&1)"
dispatch_no_worktree_status=$?
set -e
if [[ "${dispatch_no_worktree_status}" -ne 0 ]] \
  && printf '%s\n' "${dispatch_no_worktree_output}" | grep -F -- '--no-worktree is disabled for execute' >/dev/null; then
  ok "dispatch execute blocks no-worktree"
else
  bad "dispatch execute accepted no-worktree"
  printf '%s\n' "${dispatch_no_worktree_output}" | sed 's/^/    /'
fi

# T46 — requester workspace is normalized to workspace:N form
section "T46 protocol normalizes requester workspace refs"
protocol_block="$(cat "${ROOT_DIR}/scripts/orchestrator/protocol.sh")"
if printf '%s\n' "${protocol_block}" | grep -F '_orchestrator_requester_workspace_ref()' >/dev/null \
  && printf '%s\n' "${protocol_block}" | grep -F 'printf '\''  cmux_workspace_id: %s\n'\'' "$(_orchestrator_requester_workspace_ref)"' >/dev/null; then
  ok "protocol writes canonical requester workspace refs"
else
  bad "protocol still writes raw CMUX_WORKSPACE_ID"
  printf '%s\n' "${protocol_block}" | sed 's/^/    /'
fi

# T47 — dispatch execute wires rollback on failure paths
section "T47 dispatch execute rolls back failed launches"
dispatch_block="$(sed -n '574,940p' "${ROOT_DIR}/scripts/conductor.sh")"
if printf '%s\n' "${dispatch_block}" | grep -F 'rollback_dispatch_artifacts()' >/dev/null \
  && printf '%s\n' "${dispatch_block}" | grep -F '_dispatch_fail()' >/dev/null \
  && printf '%s\n' "${dispatch_block}" | grep -F '_dispatch_fail' >/dev/null; then
  ok "dispatch execute rolls back work item, state, surface, and worktree on failure"
else
  bad "dispatch execute is missing rollback wiring"
  printf '%s\n' "${dispatch_block}" | sed 's/^/    /'
fi

# T48 — team restart no longer routes through forceful lifecycle paths
section "T48 team restart is graceful-only"
team_block="$(cat "${ROOT_DIR}/scripts/orchestrator/team.sh")"
if ! printf '%s\n' "${team_block}" | grep -F -- '--force-restart' >/dev/null \
  && ! printf '%s\n' "${team_block}" | grep -F 'stop-agent.sh" --agent-name "${agent}" --force' >/dev/null \
  && printf '%s\n' "${team_block}" | grep -F 'stop-agent.sh" --agent-name "${agent}" "$@"' >/dev/null \
  && printf '%s\n' "${team_block}" | grep -F 'start-agent.sh" --agent-name "${agent}" "$@"' >/dev/null; then
  ok "team restart uses graceful stop then start"
else
  bad "team restart still uses forceful lifecycle"
  printf '%s\n' "${team_block}" | sed 's/^/    /'
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
