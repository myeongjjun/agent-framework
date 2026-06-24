#!/usr/bin/env bash
# statusline.sh — L1 PUBLIC BASELINE Claude Code status line.
#
# OWNERSHIP / LAYERING (ADR-043 — statusline L1/L2 split):
#   This is the PROVIDER-AGNOSTIC baseline. It carries ONLY the generic
#   skeleton (jq parse / git branch / session cost / context % / a generic
#   file-cache API-health badge). It contains NO in-house infrastructure
#   specifics — no kube cluster environment names, no LiteLLM/gateway budget
#   line. Those live ONLY in the L2 in-house overlay.
#
#   scripts/install.sh copies this file verbatim to ~/.claude/statusline.sh.
#   Non-in-house machines get a complete, working status line from this alone.
#
#   PRECEDENCE on in-house machines: BOTH L1 (this file, via agent-framework
#   install.sh) and L2 (agent-workspace configs/claude/statusline.sh, via
#   sync-hooks.sh) deploy to ~/.claude/statusline.sh. L2 MUST WIN. Because L1
#   install.sh can run from cron, an L1 run may transiently overwrite the
#   in-house L2 version with this baseline until the next sync-all. That is
#   acceptable per ADR-043 — re-running agent-workspace sync-all restores L2.
#
# Data sources (all file-cache reads; statusline NEVER blocks on network):
#   ~/.cache/claude/api-health.json    ← api-health-probe.sh (background)
#   ~/.cache/claude/manual-outage.json ← manual outage marker
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
dir=$(basename "$cwd")
model=$(echo "$input" | jq -r '.model.display_name')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')

# 🚦 Generic API/outage badge — surfaces whether slowness is local or upstream.
# 1) Manual marker (highest priority) — covers cases a probe can't observe.
# 2) Background probe result (api-health.json): down=red, slow=yellow.
# Cache lives under ~/.cache/claude; past TTL it refreshes in the background
# (the statusline itself NEVER blocks on the probe).
health_badge=""
_health_cache="${HOME}/.cache/claude/api-health.json"
_health_probe="${HOME}/.claude/api-health-probe.sh"
_manual_marker="${HOME}/.cache/claude/manual-outage.json"

if [[ -f "$_manual_marker" ]] && [[ "$(jq -r '.active // false' "$_manual_marker" 2>/dev/null)" == "true" ]]; then
  _reason=$(jq -r '.reason // "outage"' "$_manual_marker" 2>/dev/null)
  health_badge="\033[41;97m ⚠️ ${_reason} \033[0m "
elif [[ -f "$_health_cache" ]]; then
  _h_status=$(jq -r '.status // "ok"' "$_health_cache" 2>/dev/null)
  _h_lat=$(jq -r '.latency_ms // 0' "$_health_cache" 2>/dev/null)
  _h_ts=$(jq -r '.ts // 0' "$_health_cache" 2>/dev/null)
  _h_age=$(( $(date +%s) - _h_ts ))
  case "$_h_status" in
    down) health_badge="\033[41;97m 🔴 API DOWN \033[0m " ;;
    slow) health_badge="\033[43;30m 🟡 API SLOW ${_h_lat}ms \033[0m " ;;
    *)    health_badge="" ;;  # ok → no badge (clean when healthy)
  esac
  # Refresh in the background if older than 30s.
  if [[ "$_h_age" -gt 30 && -x "$_health_probe" ]]; then
    ( "$_health_probe" >/dev/null 2>&1 & ) 2>/dev/null || true
  fi
else
  # First run: no cache yet → trigger one background probe.
  [[ -x "$_health_probe" ]] && ( "$_health_probe" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

# Git branch
git_info=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    if ! git -C "$cwd" diff --quiet 2>/dev/null || ! git -C "$cwd" diff --cached --quiet 2>/dev/null; then
      dirty=" ✗"
    fi
    git_info=" \033[2;32mgit:($branch)$dirty\033[0m"
  fi
fi

# 💰 Session cost + burn rate
cost_info=""
if [ -n "$cost" ] && [ "$cost" != "null" ] && [ "$cost" != "0" ]; then
  cost_rounded=$(printf '%.1f' "$cost")
  burn=""
  if [ -n "$duration_ms" ] && [ "$duration_ms" != "null" ] && [ "$duration_ms" != "0" ] && [ "$duration_ms" -gt 0 ]; then
    burn_rate=$(awk "BEGIN {printf \"%.1f\", $cost / ($duration_ms / 3600000)}")
    burn=" | 🔥 \$${burn_rate}/hr"
  fi
  cost_info=" 💰 \$${cost_rounded}${burn}"
fi

# 🧠 Context usage (% only, red if ≥90%, green if ≤50%)
ctx_info=""
if [ -n "$used_pct" ] && [ "$used_pct" != "null" ]; then
  pct_int=${used_pct%.*}
  if [ "$pct_int" -ge 90 ] 2>/dev/null; then
    ctx_info=" | \033[0;31m🧠 ${used_pct}%\033[0m"
  elif [ "$pct_int" -le 50 ] 2>/dev/null; then
    ctx_info=" | \033[0;32m🧠 ${used_pct}%\033[0m"
  else
    ctx_info=" | 🧠 ${used_pct}%"
  fi
fi

printf "%b\033[2;36m%s\033[0m%b \033[2;35m⚡%s\033[0m\033[2;33m%b%b\033[0m" \
  "$health_badge" "$dir" "$git_info" "$model" "$cost_info" "$ctx_info"
