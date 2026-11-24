#!/usr/bin/env bash
# install.sh — agent-framework L1 baseline installer.
#
# Pulls L1 contents into the user's runtime locations:
#   skills/*               → ~/.claude/skills/<name>   (symlink)
#                           ~/.codex/skills/<name>    (symlink, same source)
#   hooks/**/*.sh          → ~/.claude/hooks/<name>    (copy + chmod +x)
#   bin/*                  → ~/.local/bin/<name>       (symlink)
#   configs/claude/statusline.sh → ~/.claude/statusline.sh (copy + chmod +x)
#   AGENTS.md              → ~/.claude/AGENTS.md       (copy, L1 base only — personas append)
#
# Ownership: a copied target belongs to the layer that last wrote it. This
# installer records what it wrote in ~/.claude/.framework-owned and only
# updates a target whose content is still what it wrote (or equals the
# source). A target another layer or the user has written is left alone,
# so L1 and a persona installer can run in any order. --force takes a
# target over. An owned target whose source is gone from L1 is removed.
#
# Symlinks point back at this repo so L1 git pulls are immediately
# visible to running tools without re-running install.sh.
#
# Hooks are copied (not symlinked) so the running Claude Code can read
# them without resolving relative paths inside the framework repo.
# guard-permission-bypass.sh will then prevent agent edits to the
# deployed copy; source edits go to this repo's hooks/general/.
#
# Atomicity: per-file operations. A refused target is reported and
# skipped; the remaining sections still run, and the refusal surfaces
# as the final exit code. Re-run is safe.
#
# Skills follow the same rule by type: a non-symlink dir at
# ~/.{claude,codex}/skills/<name> is another layer's copy and is left in
# place. --force replaces it with the L1 symlink.
#
# Idempotent: re-running with no L1 changes is a no-op (or just
# re-creates symlinks pointing at the same target).
#
# Exit codes:
#   0  success
#   1  generic failure
#   2  framework directory missing or malformed
#   3  refused: a bin target exists as a non-symlink and would need
#      user-confirmed overwrite (--force); reported after all sections run

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the framework root (the parent of scripts/).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

[[ -d "${FRAMEWORK_ROOT}/skills" && -d "${FRAMEWORK_ROOT}/hooks" && -d "${FRAMEWORK_ROOT}/bin" ]] || {
  echo "[install] framework root missing expected dirs (skills/hooks/bin): ${FRAMEWORK_ROOT}" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------
DRY_RUN=0
FORCE=0
while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      sed -n '2,28p' "$0" >&2
      exit 0 ;;
    *) echo "[install] unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

REFUSED=0

ok()   { printf '\033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m✗\033[0m %s\n' "$*" >&2; }

run() {
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Copied targets: ownership manifest (see header).
# ---------------------------------------------------------------------------
OWNED_FILE="${HOME}/.claude/.framework-owned"
SNAPSHOT_FILE="${HOME}/.claude/.framework-checksums"
OWNED_NEW="$(mktemp)"
trap 'rm -f "${OWNED_NEW}"' EXIT

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
note() { printf '· %s\n' "$*"; }

# Hash this installer last wrote to <dst>. An install that predates the
# manifest is read from its source snapshot (keyed by source path).
owned_sum() {
  local dst="$1" rel="$2" file key
  if [[ -f "${OWNED_FILE}" ]]; then file="${OWNED_FILE}"; key="${dst}"
  elif [[ -f "${SNAPSHOT_FILE}" ]]; then file="${SNAPSHOT_FILE}"; key="${rel}"
  else return 0; fi
  awk -v p="${key}" '{h=$1; sub(/^[^ ]+  /,""); if ($0==p) print h}' "${file}" | tail -1
}

deploy_copy() {
  local src="$1" dst="$2" mode="$3" label="$4"
  local rel="${src#"${FRAMEWORK_ROOT}/"}" src_sum dst_sum="" prev
  src_sum="$(sha "${src}")"
  if [[ -e "${dst}" || -L "${dst}" ]]; then
    [[ -f "${dst}" && ! -L "${dst}" ]] && dst_sum="$(sha "${dst}")"
    if [[ "${dst_sum}" == "${src_sum}" ]]; then
      printf '%s  %s\n' "${src_sum}" "${dst}" >> "${OWNED_NEW}"
      ok "${label} (already current)"
      return 0
    fi
    prev="$(owned_sum "${dst}" "${rel}")"
    if [[ -z "${dst_sum}" || "${dst_sum}" != "${prev}" ]] && (( FORCE == 0 )); then
      note "${label}: ${dst} was written by another layer — kept"
      return 0
    fi
  fi
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] install -m %s %s %s\n' "${mode}" "${src}" "${dst}"
  else
    mkdir -p "$(dirname "${dst}")"
    [[ -L "${dst}" ]] && rm -f "${dst}"
    install -m "${mode}" "${src}" "${dst}"
  fi
  printf '%s  %s\n' "${src_sum}" "${dst}" >> "${OWNED_NEW}"
  ok "${label} → ${dst}"
}

# ---------------------------------------------------------------------------
# 1) Skills — symlink each skill dir into ~/.claude/skills and ~/.codex/skills
# ---------------------------------------------------------------------------
install_skill() {
  local src="$1" target_dir="$2"
  local name; name="$(basename "$src")"
  local dst="${target_dir}/${name}"

  mkdir -p "${target_dir}"

  if [[ -L "${dst}" ]]; then
    # Existing symlink — replace if not pointing at our source
    local current; current="$(readlink "${dst}")"
    if [[ "${current}" == "${src}" ]]; then
      ok "skill ${name} → ${target_dir} (already linked)"
      return 0
    fi
    run rm -f "${dst}"
  elif [[ -e "${dst}" ]]; then
    # Regular file/dir — another layer's copy. Same rule as copied targets.
    if (( FORCE == 0 )); then
      note "skill ${name}: ${dst} was written by another layer — kept"
      return 0
    fi
    run rm -rf "${dst}"
  fi

  run ln -s "${src}" "${dst}"
  ok "skill ${name} → ${target_dir}"
}

for skill in "${FRAMEWORK_ROOT}/skills"/*/; do
  [[ -d "$skill" ]] || continue
  skill="${skill%/}"
  install_skill "${skill}" "${HOME}/.claude/skills"
  install_skill "${skill}" "${HOME}/.codex/skills"
done

# ---------------------------------------------------------------------------
# 2) Hooks — copy each .sh into ~/.claude/hooks/ (copied, not symlinked,
#    so the deployed copy can be guarded while source lives in this repo).
# ---------------------------------------------------------------------------
for hook in "${FRAMEWORK_ROOT}/hooks"/*/*.sh; do
  [[ -f "$hook" ]] || continue
  name="$(basename "$hook")"
  deploy_copy "${hook}" "${HOME}/.claude/hooks/${name}" 755 "hook ${name}"
done

# ---------------------------------------------------------------------------
# 3) bin — symlink each into ~/.local/bin/
# ---------------------------------------------------------------------------
mkdir -p "${HOME}/.local/bin"
for binfile in "${FRAMEWORK_ROOT}/bin"/*; do
  [[ -f "$binfile" ]] || continue
  name="$(basename "$binfile")"
  dst="${HOME}/.local/bin/${name}"
  if [[ -L "${dst}" ]]; then
    current="$(readlink "${dst}")"
    if [[ "${current}" == "${binfile}" ]]; then
      ok "bin ${name} (already linked)"
      continue
    fi
    run rm -f "${dst}"
  elif [[ -e "${dst}" ]]; then
    if (( FORCE == 0 )); then
      err "bin ${name} at ${dst} is not a symlink. Re-run with --force to overwrite."
      REFUSED=1
      continue
    fi
    run rm -f "${dst}"
  fi
  run chmod +x "${binfile}"
  run ln -s "${binfile}" "${dst}"
  ok "bin ${name} → ~/.local/bin/"
done

# ---------------------------------------------------------------------------
# 3b) Agents + cmux session desk (ADR-003).
#     agents/*.md        → ~/.claude/agents/   (copy; claude --agent <name>)
#     cmux/ desk files   → ~/.config/cmux/, ~/.local/bin/brief (symlink)
#     cmux/seeds/*       → ~/.local/share/cmux/orch/ (copied once; local-only
#                          git, no remote — orch edits them with user data)
#     cmux/automations.json → merged by rule id into ~/.cmuxterm/automations.json
#     Personas extend the morning start via ~/.config/cmux/morning-brief.d/*.sh.
# ---------------------------------------------------------------------------
link_file() {
  local src="$1" dst="$2" label="$3"
  if [[ -L "${dst}" ]]; then
    if [[ "$(readlink "${dst}")" == "${src}" ]]; then
      ok "${label} (already linked)"
      return 0
    fi
    run rm -f "${dst}"
  elif [[ -e "${dst}" ]]; then
    if (( FORCE == 0 )); then
      err "${label}: ${dst} is not a symlink. Re-run with --force to overwrite."
      REFUSED=1
      return 0
    fi
    run rm -rf "${dst}"
  fi
  run ln -s "${src}" "${dst}"
  ok "${label} → ${dst}"
}

for agent in "${FRAMEWORK_ROOT}/agents"/*.md; do
  name="$(basename "$agent")"
  case "$name" in README.md|INDEX.md) continue ;; esac
  deploy_copy "${agent}" "${HOME}/.claude/agents/${name}" 644 "agent ${name%.md}"
done

CMUX_SRC="${FRAMEWORK_ROOT}/cmux"
if [[ -d "${CMUX_SRC}" ]]; then
  mkdir -p "${HOME}/.config/cmux/sidebars" "${HOME}/.config/cmux/morning-brief.d"
  run chmod +x "${CMUX_SRC}/brief" "${CMUX_SRC}/morning-brief.sh" "${CMUX_SRC}/sessions-toggle.sh"
  for f in morning-brief.sh morning-brief.md brief-mod sessions-toggle.sh; do
    link_file "${CMUX_SRC}/${f}" "${HOME}/.config/cmux/${f}" "cmux ${f}"
  done
  link_file "${CMUX_SRC}/brief" "${HOME}/.local/bin/brief" "bin brief"

  ORCH_DATA="${HOME}/.local/share/cmux/orch"
  mkdir -p "${ORCH_DATA}"
  for seed in "${CMUX_SRC}/seeds"/*.md; do
    name="$(basename "$seed")"
    [[ -e "${ORCH_DATA}/${name}" ]] || run cp "${seed}" "${ORCH_DATA}/${name}"
    link_file "${ORCH_DATA}/${name}" "${HOME}/.config/cmux/${name}" "cmux ${name}"
  done
  [[ -d "${ORCH_DATA}/.git" ]] || run git -C "${ORCH_DATA}" init -q

  # Committee member panes (agent-scout) run unattended in folders under the
  # pane root. sib pre-trusts a folder for Claude and Codex only when it is
  # under $HOME and matches its allowlist, so list `<root>/*` there.
  PANE_ROOT_OLD="/private/tmp/agent-scout"     # pre-2026-11 default: outside $HOME, never trusted
  # shellcheck disable=SC2088  # a literal `~/` pattern: sib expands it
  PANE_ROOT_PAT="~/.local/share/cmux/hr/panes/*"
  SIB_TRUST="${XDG_CONFIG_HOME:-${HOME}/.config}/sib/trusted-dirs"
  committee="${ORCH_DATA}/agent-committee.md"
  if [[ -f "${committee}" ]] && grep -qE "^- root: ${PANE_ROOT_OLD}([[:space:]]|$)" "${committee}"; then
    if (( DRY_RUN == 1 )); then
      printf '  [dry-run] committee pane root %s → %s\n' "${PANE_ROOT_OLD}" "${PANE_ROOT_PAT%/\*}"
    else
      sed "s#^- root: ${PANE_ROOT_OLD}\$#- root: ${PANE_ROOT_PAT%/\*}#; s#^- root: ${PANE_ROOT_OLD}[[:space:]].*#- root: ${PANE_ROOT_PAT%/\*}#" \
        "${committee}" > "${committee}.tmp" && mv -f "${committee}.tmp" "${committee}"
      ok "committee pane root ${PANE_ROOT_OLD} → ${PANE_ROOT_PAT%/\*} (sib cannot pre-trust outside \$HOME)"
    fi
  fi
  if ! grep -qE '^[[:space:]]*~/\.local/share/cmux/hr/panes/\*[[:space:]]*(#.*)?$' "${SIB_TRUST}" 2>/dev/null; then
    if (( DRY_RUN == 1 )); then
      printf '  [dry-run] add %s to %s\n' "${PANE_ROOT_PAT}" "${SIB_TRUST}"
    else
      mkdir -p "$(dirname "${SIB_TRUST}")"
      [[ -s "${SIB_TRUST}" ]] || printf '# sib: dirs a sibling may start in without the trust dialog\n' > "${SIB_TRUST}"
      printf '# agent-scout committee member panes (added by agent-framework install)\n%s\n' "${PANE_ROOT_PAT}" >> "${SIB_TRUST}"
      ok "sib trusted-dirs: ${PANE_ROOT_PAT} (committee member panes)"
    fi
  fi

  if (( DRY_RUN == 1 )); then
    "${FRAMEWORK_ROOT}/bin/cmux-automations-merge" "${CMUX_SRC}/automations.json" --dry-run >/dev/null \
      && printf '  [dry-run] merge %s\n' "${CMUX_SRC}/automations.json"
  else
    "${FRAMEWORK_ROOT}/bin/cmux-automations-merge" "${CMUX_SRC}/automations.json" \
      && ok "cmux automations merged" || { err "cmux automations merge failed"; REFUSED=1; }
    "${CMUX_SRC}/brief" render >/dev/null 2>&1 || warn "brief render failed (cmux not running?)"
  fi
fi

# ---------------------------------------------------------------------------
# 4) Statusline — the L1 baseline (provider-agnostic skeleton).
# ---------------------------------------------------------------------------
statusline_src="${FRAMEWORK_ROOT}/configs/claude/statusline.sh"
if [[ -f "${statusline_src}" ]]; then
  deploy_copy "${statusline_src}" "${HOME}/.claude/statusline.sh" 755 "statusline.sh"
fi

# ---------------------------------------------------------------------------
# 5) AGENTS.md — copy as base. Personas APPEND to this; never edit.
#    install only seeds ~/.claude/AGENTS.md.framework-base; the actual
#    ~/.claude/AGENTS.md is the persona's responsibility to compose.
# ---------------------------------------------------------------------------
if [[ -f "${FRAMEWORK_ROOT}/AGENTS.md" ]]; then
  deploy_copy "${FRAMEWORK_ROOT}/AGENTS.md" "${HOME}/.claude/AGENTS.md.framework-base" 644 "AGENTS.md.framework-base"
fi

# ---------------------------------------------------------------------------
# 5a) cmux session completion report — reaches every session, not only the
#     ones `sib spawn` starts. Claude Code loads ~/.claude/rules/*.md in
#     every session; Codex reads ~/.codex/AGENTS.md, which another layer
#     owns, so L1 keeps only a marked block inside it.
# ---------------------------------------------------------------------------
report_src="${FRAMEWORK_ROOT}/cmux/session-report.md"
if [[ -f "${report_src}" ]]; then
  deploy_copy "${report_src}" "${HOME}/.claude/rules/cmux-session-report.md" 644 "rules/cmux-session-report.md"
  codex_md="${HOME}/.codex/AGENTS.md"
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] update L1 block in %s\n' "${codex_md}"
  else
    mkdir -p "$(dirname "${codex_md}")"
    L1_BLOCK_SRC="${report_src}" python3 - "${codex_md}" <<'PY'
import os, sys
path, start, end = sys.argv[1], "<!-- agent-framework:cmux-session-report:start -->", "<!-- agent-framework:cmux-session-report:end -->"
block = start + "\n" + open(os.environ["L1_BLOCK_SRC"]).read().rstrip("\n") + "\n" + end
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
if start in text and end in text:
    head, rest = text.split(start, 1)
    new = head + block + rest.split(end, 1)[1]
else:
    new = text.rstrip("\n") + ("\n\n" if text.strip() else "") + block + "\n"
if new != text:
    open(path, "w").write(new)
PY
  fi
  ok "codex AGENTS.md L1 block → ${codex_md}"
fi

# ---------------------------------------------------------------------------
# 5b) Ownership manifest. An owned target that this run did not deploy has
#     left L1: remove it if it is still exactly what L1 wrote.
# ---------------------------------------------------------------------------
if [[ -f "${OWNED_FILE}" ]]; then
  while IFS= read -r line; do
    old_sum="${line%%  *}"; old_dst="${line#*  }"
    awk -v p="${old_dst}" '{sub(/^[^ ]+  /,""); if ($0==p) f=1} END{exit !f}' "${OWNED_NEW}" && continue
    [[ -f "${old_dst}" && ! -L "${old_dst}" && "$(sha "${old_dst}")" == "${old_sum}" ]] || continue
    run rm -f "${old_dst}"
    ok "removed ${old_dst} (no longer in L1)"
  done < "${OWNED_FILE}"
fi
if (( DRY_RUN == 0 )); then
  mkdir -p "${HOME}/.claude"
  sort -u -k2 "${OWNED_NEW}" > "${OWNED_FILE}"
fi

# ---------------------------------------------------------------------------
# 6) Drift-detection checksum file — verify.sh consumes this.
# ---------------------------------------------------------------------------
sum_file="${HOME}/.claude/.framework-checksums"
if (( DRY_RUN == 0 )); then
  (
    cd "${FRAMEWORK_ROOT}"
    {
      find skills -type f \( -name 'SKILL.md' -o -name 'templates.md' -o -name '*.sh' \) -print0 \
        | sort -z | xargs -0 shasum -a 256
      find hooks -type f -name '*.sh' -print0 \
        | sort -z | xargs -0 shasum -a 256
      find bin -type f -print0 \
        | sort -z | xargs -0 shasum -a 256
      find agents -type f -name '*.md' -print0 \
        | sort -z | xargs -0 shasum -a 256
      find agent-context/constraints -type f -name '*.md' -print0 \
        | sort -z | xargs -0 shasum -a 256
      [[ -f configs/claude/statusline.sh ]] && shasum -a 256 configs/claude/statusline.sh
      [[ -f AGENTS.md ]] && shasum -a 256 AGENTS.md
      [[ -f cmux/automations.json ]] && shasum -a 256 cmux/automations.json
    } > "${sum_file}"
  )
  ok "checksum snapshot → ${sum_file}"
else
  printf '  [dry-run] would write checksum snapshot to %s\n' "${sum_file}"
fi

echo ""
if (( REFUSED == 1 )); then
  err "L1 install finished with refused targets (see ✗ above)."
else
  ok "L1 install complete."
fi
echo "   Source : ${FRAMEWORK_ROOT}"
echo "   Targets: ~/.claude/{skills,hooks,agents,statusline.sh,AGENTS.md.framework-base}"
echo "            ~/.codex/skills"
echo "            ~/.local/bin"
echo ""
echo "   Update path: scripts/check-update.sh (run via cron / SessionStart)."
(( REFUSED == 0 )) || exit 3
