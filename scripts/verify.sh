#!/usr/bin/env bash
# verify.sh — drift detection between L1 source and deployed copies.
#
# Reads the checksum snapshot written by install.sh
# (~/.claude/.framework-checksums) and compares it with the current
# state of the framework source tree. If they differ, L1 source has
# changed since the last install — caller should re-run install.sh.
#
# Also walks the deployed locations and detects missing targets and stale
# L1 copies. A target that another layer or the user has written is not
# L1's to judge (install.sh leaves it alone) and is only listed.
#
# Exit codes:
#   0  in sync
#   1  source vs snapshot drift (install.sh needed)
#   2  deployed vs source drift (one or more copies differ)
#   3  framework root or snapshot missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUM_FILE="${HOME}/.claude/.framework-checksums"

QUIET=0
while (( $# > 0 )); do
  case "$1" in
    -q|--quiet) QUIET=1 ;;
    -h|--help) sed -n '2,16p' "$0" >&2; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

say() { (( QUIET == 1 )) || printf '%s\n' "$*"; }

[[ -d "${FRAMEWORK_ROOT}/skills" ]] || { say "[verify] framework missing"; exit 3; }
[[ -f "${SUM_FILE}" ]] || { say "[verify] no snapshot — run install.sh first"; exit 3; }

# 1) Source-vs-snapshot drift
current_sum="$(
  cd "${FRAMEWORK_ROOT}" && {
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
  }
)"
snapshot_sum="$(cat "${SUM_FILE}")"

if [[ "${current_sum}" != "${snapshot_sum}" ]]; then
  say "[verify] source vs snapshot DRIFT — re-run install.sh"
  exit 1
fi

# 2) Deployed copies vs source
fail=0

check_symlink() {
  local dst="$1" src="$2"
  if [[ ! -L "${dst}" ]]; then
    say "[verify] missing symlink: ${dst}"
    fail=1
    return
  fi
  local current; current="$(readlink "${dst}")"
  if [[ "${current}" != "${src}" ]]; then
    say "[verify] wrong target: ${dst} → ${current} (expected ${src})"
    fail=1
  fi
}

OWNED_FILE="${HOME}/.claude/.framework-owned"

check_copy() {
  local dst="$1" src="$2" prev=""
  if [[ ! -e "${dst}" ]]; then
    say "[verify] missing: ${dst}"
    fail=1
    return
  fi
  cmp -s "${dst}" "${src}" && return
  # Differs from source: stale only if it is still what install.sh wrote.
  [[ -f "${OWNED_FILE}" ]] && prev="$(awk -v p="${dst}" '{h=$1; sub(/^[^ ]+  /,""); if ($0==p) print h}' "${OWNED_FILE}" | tail -1)"
  if [[ -n "${prev}" && "$(shasum -a 256 "${dst}" | awk '{print $1}')" == "${prev}" ]]; then
    say "[verify] stale copy: ${dst}"
    fail=1
  else
    say "[verify] other layer: ${dst}"
  fi
}

check_skill() {
  local dst="$1" src="$2"
  if [[ -e "${dst}" && ! -L "${dst}" ]]; then
    say "[verify] other layer: ${dst}"
    return
  fi
  check_symlink "${dst}" "${src}"
}

# Skills
for skill in "${FRAMEWORK_ROOT}/skills"/*/; do
  [[ -d "$skill" ]] || continue
  skill="${skill%/}"
  name="$(basename "${skill}")"
  check_skill "${HOME}/.claude/skills/${name}" "${skill}"
  check_skill "${HOME}/.codex/skills/${name}" "${skill}"
done

# Hooks (copied)
for hook in "${FRAMEWORK_ROOT}/hooks"/*/*.sh; do
  [[ -f "$hook" ]] || continue
  name="$(basename "${hook}")"
  check_copy "${HOME}/.claude/hooks/${name}" "${hook}"
done

# Bin
for binfile in "${FRAMEWORK_ROOT}/bin"/*; do
  [[ -f "$binfile" ]] || continue
  name="$(basename "${binfile}")"
  check_symlink "${HOME}/.local/bin/${name}" "${binfile}"
done

# Agents + cmux desk
for agent in "${FRAMEWORK_ROOT}/agents"/*.md; do
  case "$(basename "$agent")" in README.md|INDEX.md) continue ;; esac
  check_copy "${HOME}/.claude/agents/$(basename "$agent")" "${agent}"
done
if [[ -d "${FRAMEWORK_ROOT}/cmux" ]]; then
  check_symlink "${HOME}/.local/bin/brief" "${FRAMEWORK_ROOT}/cmux/brief"
  check_symlink "${HOME}/.config/cmux/morning-brief.sh" "${FRAMEWORK_ROOT}/cmux/morning-brief.sh"
fi

# Statusline + AGENTS base (copied)
[[ -f "${FRAMEWORK_ROOT}/configs/claude/statusline.sh" ]] \
  && check_copy "${HOME}/.claude/statusline.sh" "${FRAMEWORK_ROOT}/configs/claude/statusline.sh"
[[ -f "${FRAMEWORK_ROOT}/AGENTS.md" ]] \
  && check_copy "${HOME}/.claude/AGENTS.md.framework-base" "${FRAMEWORK_ROOT}/AGENTS.md"

if (( fail == 1 )); then
  say "[verify] deployment drift — re-run install.sh"
  exit 2
fi

say "[verify] in sync"
exit 0
