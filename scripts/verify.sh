#!/usr/bin/env bash
# verify.sh — drift detection between L1 source and deployed copies.
#
# Reads the checksum snapshot written by install.sh
# (~/.claude/.framework-checksums) and compares it with the current
# state of the framework source tree. If they differ, L1 source has
# changed since the last install — caller should re-run install.sh.
#
# Also walks the deployed locations and detects copies that don't
# match the source (manual edits / corruption / partial install).
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
    find agent-context/constraints -type f -name '*.md' -print0 \
      | sort -z | xargs -0 shasum -a 256
    [[ -f AGENTS.md ]] && shasum -a 256 AGENTS.md
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

check_hook_copy() {
  local dst="$1" src="$2"
  if [[ ! -f "${dst}" ]]; then
    say "[verify] missing hook: ${dst}"
    fail=1
    return
  fi
  if ! cmp -s "${dst}" "${src}"; then
    say "[verify] hook drift: ${dst} differs from source"
    fail=1
  fi
}

# Skills
for skill in "${FRAMEWORK_ROOT}/skills"/*/; do
  [[ -d "$skill" ]] || continue
  skill="${skill%/}"
  name="$(basename "${skill}")"
  check_symlink "${HOME}/.claude/skills/${name}" "${skill}"
  check_symlink "${HOME}/.codex/skills/${name}" "${skill}"
done

# Hooks (copied)
for hook in "${FRAMEWORK_ROOT}/hooks"/*/*.sh; do
  [[ -f "$hook" ]] || continue
  name="$(basename "${hook}")"
  check_hook_copy "${HOME}/.claude/hooks/${name}" "${hook}"
done

# Bin
for binfile in "${FRAMEWORK_ROOT}/bin"/*; do
  [[ -f "$binfile" ]] || continue
  name="$(basename "${binfile}")"
  check_symlink "${HOME}/.local/bin/${name}" "${binfile}"
done

if (( fail == 1 )); then
  say "[verify] deployment drift — re-run install.sh"
  exit 2
fi

say "[verify] in sync"
exit 0
