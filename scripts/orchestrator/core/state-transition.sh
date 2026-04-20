#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: state-transition.sh --mode <dispatch|done> --state-json <json> \
  --plan-json <json> [--now <iso8601>]

Apply a pure state transition and emit the new state JSON to stdout.
EOF
}

mode=''
state_json=''
plan_json=''
now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

while (($# > 0)); do
  case "$1" in
    --mode)
      shift
      [[ $# -gt 0 ]] || { echo "state-transition.sh: missing value for --mode" >&2; exit 1; }
      mode="$1"
      ;;
    --state-json)
      shift
      [[ $# -gt 0 ]] || { echo "state-transition.sh: missing value for --state-json" >&2; exit 1; }
      state_json="$1"
      ;;
    --plan-json)
      shift
      [[ $# -gt 0 ]] || { echo "state-transition.sh: missing value for --plan-json" >&2; exit 1; }
      plan_json="$1"
      ;;
    --now)
      shift
      [[ $# -gt 0 ]] || { echo "state-transition.sh: missing value for --now" >&2; exit 1; }
      now="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "state-transition.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

[[ -n "${mode}" ]] || { echo "state-transition.sh: --mode is required" >&2; exit 1; }
[[ -n "${state_json}" ]] || { echo "state-transition.sh: --state-json is required" >&2; exit 1; }
[[ -n "${plan_json}" ]] || { echo "state-transition.sh: --plan-json is required" >&2; exit 1; }

case "${mode}" in
  dispatch)
    jq \
      --arg now "${now}" \
      --argjson plan "${plan_json}" '
      .version = (.version // 1)
      | .projects = (.projects // {})
      | .tasks = (.tasks // {})
      | .agents = (.agents // {})
      | .updated_at = $now
      | .projects[$plan.project.slug] = (
          (.projects[$plan.project.slug] // {
            name: $plan.project.name,
            slug: $plan.project.slug,
            path: $plan.project.path,
            tasks: [],
            created_at: $now
          })
          | .name = $plan.project.name
          | .slug = $plan.project.slug
          | .path = $plan.project.path
          | .tasks = (((.tasks // []) + [$plan.task.slug]) | unique)
          | .updated_at = $now
        )
      | .tasks[$plan.task.slug] = (
          (.tasks[$plan.task.slug] // {
            slug: $plan.task.slug,
            created_at: $now
          })
          | .description = $plan.task.description
          | .project = $plan.project.slug
          | .project_path = $plan.project.path
          | .status = "planned"
          | .work_item_path = $plan.task.work_item_path
          | .done_report_path = $plan.task.done_report_path
          | .request_metadata = ($plan.request // {})
          | .keep_alive = (($plan.request.keep_alive // false) == true)
          | .agents = ($plan.agents | map(.slot))
          | .worktree_required = ($plan.worktree.required // false)
          | .worktree_path = ($plan.worktree.path // null)
          | .worktree_branch = ($plan.worktree.branch // null)
          | .updated_at = $now
        )
      | reduce $plan.agents[] as $agent (.;
          .agents[$agent.slot] = (
            (.agents[$agent.slot] // {
              slot: $agent.slot,
              created_at: $now
            })
            | .family = $agent.family
            | .project = $plan.project.slug
            | .task = $plan.task.slug
            | .cwd = $agent.cwd
            | .advisor_mode = ($plan.request.advisor_mode // null)
            | .executor_tier = ($agent.executor_tier // ($plan.request.executor_tier // null))
            | .surface_id = (.surface_id // null)
            | .status = "planned"
            | .updated_at = $now
          )
        )
      ' <<<"${state_json}"
    ;;
  done)
    jq \
      --arg now "${now}" \
      --argjson plan "${plan_json}" '
      .version = (.version // 1)
      | .projects = (.projects // {})
      | .tasks = (.tasks // {})
      | .agents = (.agents // {})
      | .updated_at = $now
      | .tasks[$plan.task.slug] = (
          (.tasks[$plan.task.slug] // {
            slug: $plan.task.slug,
            created_at: $now
          })
          | .status = "done"
          | .done_report_path = $plan.task.done_report_path
          | .completed_at = $now
          | .updated_at = $now
        )
      | (if ($plan.project.slug // "") != "" and (.projects[$plan.project.slug] != null) then
           .projects[$plan.project.slug].updated_at = $now
         else
           .
         end)
      | reduce ((.tasks[$plan.task.slug].agents // []))[] as $slot (.;
          .agents[$slot] = (
            (.agents[$slot] // {
              slot: $slot,
              created_at: $now
            })
            | .status = "done"
            | .updated_at = $now
          )
        )
      ' <<<"${state_json}"
    ;;
  *)
    echo "state-transition.sh: unsupported mode: ${mode}" >&2
    exit 1
    ;;
esac
