#!/usr/bin/env bash
# install.sh — agent-framework L1 baseline installer.
#
# Pulls L1 contents into the user's runtime locations:
#   skills/*       → ~/.claude/skills/<name>   (symlink)
#                   ~/.codex/skills/<name>    (symlink, same source)
#   hooks/**/*.sh  → ~/.claude/hooks/<name>    (copy + chmod +x)
#   bin/*          → ~/.local/bin/<name>       (symlink)
#   AGENTS.md      → ~/.claude/AGENTS.md       (copy, L1 base only — personas append)
#
# Symlinks point back at this repo so L1 git pulls are immediately
# visible to running tools without re-running install.sh.
#
# Hooks are copied (not symlinked) so the running Claude Code can read
# them without resolving relative paths inside the framework repo.
# guard-permission-bypass.sh will then prevent agent edits to the
# deployed copy; source edits go to this repo's hooks/general/.
#
# Atomicity: per-file operations. A failure during one file leaves
# previous files installed; re-run is safe.
#
# Idempotent: re-running with no L1 changes is a no-op (or just
# re-creates symlinks pointing at the same target).
#
# Exit codes:
#   0  success
#   1  generic failure
#   2  framework directory missing or malformed
#   3  refused: detected a conflicting non-framework symlink that
#      would need user-confirmed overwrite

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
    # Regular file/dir — refuse without --force (so we don't blow away
    # a hand-edited deployed copy without consent)
    if (( FORCE == 0 )); then
      err "skill ${name} at ${dst} is a regular file/dir, not a symlink."
      err "  Move or remove it, or re-run with --force to overwrite."
      return 3
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
# 2) Hooks — copy each .sh into ~/.claude/hooks/ and chmod +x.
#    Copied (not symlinked) so guard-deployed-artifact-edit.sh can refuse
#    edits to the deployed copy while source lives in this repo.
# ---------------------------------------------------------------------------
mkdir -p "${HOME}/.claude/hooks"
for hook in "${FRAMEWORK_ROOT}/hooks"/*/*.sh; do
  [[ -f "$hook" ]] || continue
  name="$(basename "$hook")"
  dst="${HOME}/.claude/hooks/${name}"
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] cp %s %s\n' "${hook}" "${dst}"
  else
    install -m 755 "${hook}" "${dst}"
  fi
  ok "hook ${name} → ~/.claude/hooks/"
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
      exit 3
    fi
    run rm -f "${dst}"
  fi
  run chmod +x "${binfile}"
  run ln -s "${binfile}" "${dst}"
  ok "bin ${name} → ~/.local/bin/"
done

# ---------------------------------------------------------------------------
# 4) AGENTS.md — copy as base. Personas APPEND to this; never edit.
#    install only seeds ~/.claude/AGENTS.md.framework-base; the actual
#    ~/.claude/AGENTS.md is the persona's responsibility to compose.
# ---------------------------------------------------------------------------
if [[ -f "${FRAMEWORK_ROOT}/AGENTS.md" ]]; then
  base_dst="${HOME}/.claude/AGENTS.md.framework-base"
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] cp %s %s\n' "${FRAMEWORK_ROOT}/AGENTS.md" "${base_dst}"
  else
    install -m 644 "${FRAMEWORK_ROOT}/AGENTS.md" "${base_dst}"
  fi
  ok "AGENTS.md.framework-base → ~/.claude/"
fi

# ---------------------------------------------------------------------------
# 5) Drift-detection checksum file — verify.sh consumes this.
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
      find agent-context/constraints -type f -name '*.md' -print0 \
        | sort -z | xargs -0 shasum -a 256
      [[ -f AGENTS.md ]] && shasum -a 256 AGENTS.md
    } > "${sum_file}"
  )
  ok "checksum snapshot → ${sum_file}"
else
  printf '  [dry-run] would write checksum snapshot to %s\n' "${sum_file}"
fi

echo ""
ok "L1 install complete."
echo "   Source : ${FRAMEWORK_ROOT}"
echo "   Targets: ~/.claude/{skills,hooks,AGENTS.md.framework-base}"
echo "            ~/.codex/skills"
echo "            ~/.local/bin"
echo ""
echo "   Update path: scripts/check-update.sh (run via cron / SessionStart)."
