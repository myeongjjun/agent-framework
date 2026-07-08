#!/usr/bin/env bash
# pane-resolve.sh — deterministic target resolution for /pane-msg (L1).
#
# ONE resolution primitive: selector in → {workspace, surface} matches out.
# It never guesses and never creates anything: it emits ALL matches, each
# enriched with enough live state (busy/approval/idle, titles, last message)
# for the caller to apply the policy "reuse if a match exists AND it is free
# and relevant; create only when none matches; ask the user when ambiguous".
#
# Selectors (exactly one):
#   --slug <slug>                 sib state file lookup (most reliable)
#   --cwd <path>                  workspaces rooted at <path> (placement reuse)
#   --title <hint>                case-insensitive substring on workspace and
#                                 surface titles (weakest — titles are
#                                 auto-named and flip; confirm before acting)
#   --surface <ref> --workspace <ref>   explicit refs — verify + enrich only
#
# Output (stdout), one line per match, tab-separated key=value fields:
#   workspace=<ref>  surface=<ref>  slug=<slug|->  cwd=<path|->  self=<yes|no>
#   state=<busy|approval|idle|unknown>  ws_title=<t|->  title=<t|->
#   last_at=<iso8601|->  last_msg=<first 80 chars|->
# Final line is always the verdict:
#   MATCH:<n>        n = distinct workspaces for --cwd, matched surfaces otherwise
# Exit codes:
#   0 = exactly one match          3 = no match ("safe to create")
#   4 = ambiguous (n >= 2)         1 = usage / environment error
#
# cwd source of truth: `cmux workspace list --json` → `.current_directory`
# (authoritative workspace root). Do NOT grep statuslines or parse titles for
# cwd. CAVEAT: current_directory is the workspace's launch/root dir — a
# long-running shell/agent may have `cd`'d elsewhere since, so a match means
# "this workspace is rooted there", not "the process is still there".
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export CMUX_QUIET=1

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/sib/state"

die() { echo "pane-resolve: $*" >&2; exit 1; }
alive() { cmux read-screen --surface "$1" --workspace "$2" --lines 1 >/dev/null 2>&1; }

# A pane is busy when its screen shows either the classic 'esc to interrupt'
# hint or an agent spinner status line ('· Orchestrating… (12m …)'). Newer
# Claude Code builds show ONLY the spinner while working — and keep the ❯
# input marker drawn — so marker-present must never be read as idle on its own.
busy_signal() {
  grep -qiF 'esc to interrupt' <<<"$1" && return 0
  grep -qE '^[[:space:]]*(·|✢|✳|✶|✻|✽|\*|\+|•)[[:space:]]+[A-Z][a-z]+(…|\.\.\.)' <<<"$1"
}

# Classify what the pane is showing right now. Mirrors the approver daemon's
# prompt detection so /pane-msg never injects into a screen the approver may
# also be acting on. Precedence: approval > busy > idle.
pane_state() { # $1=surface $2=workspace
  local screen tail_text
  screen="$(cmux read-screen --surface "$1" --workspace "$2" --lines 40 2>/dev/null)" || { echo unknown; return; }
  tail_text="$(printf '%s\n' "${screen}" \
    | awk '/[^[:space:]]/ { last = NR } { buf[NR] = $0 } END { for (i = 1; i <= last; i++) print buf[i] }' \
    | tail -n 25)"
  if [[ "${tail_text}" == *"Press enter to confirm"* \
     || "${tail_text}" == *"Do you want to proceed?"* \
     || "${tail_text}" == *"Would you like to run the following command?"* \
     || "${tail_text}" == *"Allow once"* || "${tail_text}" == *"Allow always"* \
     || "${tail_text}" == *"[y/N]"* || "${tail_text}" == *"[Y/n]"* ]] \
     || grep -qE '^[[:space:]]*[›❯] 1\. Yes' <<<"${tail_text}"; then
    echo approval; return
  fi
  if busy_signal "${tail_text}"; then echo busy; return; fi
  if grep -qE '[❯›]' <<<"${tail_text}"; then echo idle; return; fi
  echo unknown
}

slug="" cwd="" title="" surface="" workspace=""
while (($#)); do case "$1" in
  --slug)      shift; slug="${1:?--slug needs a value}" ;;
  --cwd)       shift; cwd="${1:?--cwd needs a path}" ;;
  --title)     shift; title="${1:?--title needs a hint}" ;;
  --surface)   shift; surface="${1:?--surface needs a ref}" ;;
  --workspace) shift; workspace="${1:?--workspace needs a ref}" ;;
  *) die "unknown arg: $1" ;;
esac; shift || true; done

n_selectors=0
[[ -n "${slug}" ]] && ((n_selectors += 1))
[[ -n "${cwd}" ]] && ((n_selectors += 1))
[[ -n "${title}" ]] && ((n_selectors += 1))
[[ -n "${surface}" ]] && ((n_selectors += 1))
(( n_selectors == 1 )) || die "exactly one selector required (--slug | --cwd | --title | --surface+--workspace)"
[[ -n "${surface}" && -z "${workspace}" ]] && die "--surface requires --workspace"

command -v cmux >/dev/null || die "cmux not found on PATH"
command -v jq >/dev/null || die "jq not found on PATH"

# Self identity — the caller's own pane is a forbidden delivery target; its
# workspace stays in results (splitting your own workspace is valid placement).
self_surface=""
if ident="$(cmux identify --json 2>/dev/null)"; then
  self_surface="$(jq -r '.caller.surface_ref // empty' <<<"${ident}" 2>/dev/null || true)"
fi

# Workspace metadata table: ref \t current_directory \t title \t last_at \t last_msg
WS_TABLE="$(cmux workspace list --json 2>/dev/null | jq -r '
  .workspaces[] | [
    .ref,
    (.current_directory // "-"),
    ((.custom_title // .title // "-") | gsub("[\\t\\n]"; " ")),
    (.latest_submitted_at // "-"),
    ((.latest_conversation_message // "-") | gsub("[\\t\\n]"; " ") | .[0:80])
  ] | @tsv')"
[[ -n "${WS_TABLE}" ]] || die "cmux workspace list --json returned nothing"

ws_field() { # $1=ws_ref $2=field_index(2..5)
  awk -F'\t' -v ws="$1" -v i="$2" '$1 == ws { print $i; exit }' <<<"${WS_TABLE}"
}

# sib state files store the workspace as a ref (workspace:N) when spawned
# with --workspace/--new-workspace, but as a raw UUID ($CMUX_WORKSPACE_ID)
# for a default caller-split. cmux commands accept both; our WS_TABLE joins
# need the ref form. Map UUID → ref via sidebar-state's tab= field.
normalize_ws() { # $1 = workspace ref or UUID → ref (falls back to input)
  local id="$1" ref tab
  [[ "${id}" == workspace:* ]] && { printf '%s' "${id}"; return; }
  while IFS=$'\t' read -r ref _; do
    tab="$(cmux sidebar-state --workspace "${ref}" 2>/dev/null | sed -n 's/^tab=//p' | head -1)"
    [[ "${tab}" == "${id}" ]] && { printf '%s' "${ref}"; return; }
  done <<<"${WS_TABLE}"
  printf '%s' "${id}"
}

# sib slug lookup table: "workspace surface" → slug
declare -A SLUG_BY_TARGET=()
if [[ -d "${STATE_DIR}" ]]; then
  for f in "${STATE_DIR}"/*.env; do
    [[ -f "$f" ]] || continue
    s_slug="$(sed -n 's/^slug=//p' "$f")"
    s_surface="$(sed -n 's/^surface=//p' "$f")"
    s_workspace="$(normalize_ws "$(sed -n 's/^workspace=//p' "$f")")"
    [[ -n "${s_surface}" && -n "${s_workspace}" ]] && SLUG_BY_TARGET["${s_workspace} ${s_surface}"]="${s_slug}"
  done
fi

emit() { # $1=ws $2=surface $3=slug $4=surface_title
  # surface refs are a global namespace (unique across workspaces), so the
  # surface alone identifies self — no workspace-format juggling needed.
  local self=no st
  [[ "$2" == "${self_surface}" ]] && self=yes
  st="$(pane_state "$2" "$1")"
  printf 'workspace=%s\tsurface=%s\tslug=%s\tcwd=%s\tself=%s\tstate=%s\tws_title=%s\ttitle=%s\tlast_at=%s\tlast_msg=%s\n' \
    "$1" "$2" "${3:--}" "$(ws_field "$1" 2)" "${self}" "${st}" \
    "$(ws_field "$1" 3)" "${4:--}" "$(ws_field "$1" 4)" "$(ws_field "$1" 5)"
}

# List a workspace's surfaces as "surface:N<TAB>title" (leading '* ' marker
# and trailing '[selected]' trimmed; status glyphs kept — they do not affect
# substring matching).
list_surfaces() {
  cmux list-pane-surfaces --workspace "$1" 2>/dev/null \
    | sed -E 's/^[* ]+//; s/ +\[selected\]$//' \
    | sed -E $'s/^(surface:[0-9]+) +/\\1\t/'
}

matches=""

if [[ -n "${surface}" ]]; then
  workspace="$(normalize_ws "${workspace}")"
  alive "${surface}" "${workspace}" || { echo "MATCH:0"; echo "pane-resolve: ${surface} in ${workspace} is not readable (gone?)" >&2; exit 3; }
  matches="$(emit "${workspace}" "${surface}" "${SLUG_BY_TARGET["${workspace} ${surface}"]:-}" "-")"

elif [[ -n "${slug}" ]]; then
  f="${STATE_DIR}/${slug}.env"
  if [[ ! -f "$f" ]]; then
    echo "MATCH:0"; echo "pane-resolve: no sib state for slug '${slug}'" >&2; exit 3
  fi
  s_surface="$(sed -n 's/^surface=//p' "$f")"
  s_workspace="$(normalize_ws "$(sed -n 's/^workspace=//p' "$f")")"
  if ! alive "${s_surface}" "${s_workspace}"; then
    echo "MATCH:0"
    echo "pane-resolve: slug '${slug}' state is stale — pane gone (run: sib kill ${slug})" >&2
    exit 3
  fi
  matches="$(emit "${s_workspace}" "${s_surface}" "${slug}" "-")"

elif [[ -n "${cwd}" ]]; then
  target="$(cd "${cwd}" 2>/dev/null && pwd -P)" || die "cwd does not exist: ${cwd}"
  while IFS=$'\t' read -r ws w _rest; do
    [[ -n "${w}" && "${w}" != "-" ]] || continue
    real_w="$(cd "${w}" 2>/dev/null && pwd -P)" || continue
    [[ "${real_w}" == "${target}" ]] || continue
    while IFS=$'\t' read -r sref stitle; do
      [[ -n "${sref}" ]] || continue
      matches+="$(emit "${ws}" "${sref}" "${SLUG_BY_TARGET["${ws} ${sref}"]:-}" "${stitle}")"$'\n'
    done < <(list_surfaces "${ws}")
  done <<<"${WS_TABLE}"
  matches="${matches%$'\n'}"

else # --title
  hint="$(tr '[:upper:]' '[:lower:]' <<<"${title}")"
  while IFS=$'\t' read -r ws _w ws_title _rest; do
    while IFS=$'\t' read -r sref stitle; do
      [[ -n "${sref}" ]] || continue
      hay="$(tr '[:upper:]' '[:lower:]' <<<"${ws_title} ${stitle}")"
      [[ "${hay}" == *"${hint}"* ]] || continue
      matches+="$(emit "${ws}" "${sref}" "${SLUG_BY_TARGET["${ws} ${sref}"]:-}" "${stitle}")"$'\n'
    done < <(list_surfaces "${ws}")
  done <<<"${WS_TABLE}"
  matches="${matches%$'\n'}"
fi

if [[ -z "${matches}" ]]; then
  echo "MATCH:0"
  exit 3
fi

printf '%s\n' "${matches}"

# Verdict granularity: --cwd answers "is a workspace already rooted there?"
# (placement reuse), so count distinct workspaces; other selectors answer
# "which pane gets the message?", so count surfaces.
if [[ -n "${cwd}" ]]; then
  n="$(printf '%s\n' "${matches}" | sed -n 's/^workspace=\([^\t]*\).*/\1/p' | sort -u | wc -l | tr -d ' ')"
else
  n="$(printf '%s\n' "${matches}" | grep -c .)"
fi
echo "MATCH:${n}"
(( n == 1 )) && exit 0
exit 4
