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
# Statusline layering (ADR-043): configs/claude/statusline.sh is the L1
# PUBLIC BASELINE — provider-agnostic skeleton only, no in-house specifics.
# On in-house machines the agent-workspace L2 overlay (sync-hooks.sh) ALSO
# deploys ~/.claude/statusline.sh and MUST WIN. Since this installer can run
# from cron, an L1 run may transiently overwrite the in-house L2 version with
# the baseline until the next sync-all; re-running sync-all restores L2.
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
# Skill layering: a non-symlink dir at ~/.{claude,codex}/skills/<name>
# is treated as an L2 overlay copy (e.g. agent-workspace sync-skills.sh)
# and left in place — L2 wins, same rule as the statusline (ADR-043).
# --force replaces it with the L1 symlink.
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
    # Regular file/dir — an L2 overlay copy (or a hand-edited one). Leave
    # it; L2 wins over L1. --force replaces it with the L1 symlink.
    if (( FORCE == 0 )); then
      warn "skill ${name} at ${dst} is a non-symlink copy (L2 overlay?) — kept; L1 version not linked."
      warn "  Re-run with --force to replace it with the L1 symlink."
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
# 4) Statusline — copy the L1 baseline into ~/.claude/statusline.sh (+chmod).
#    Copied (not symlinked) so the L2 in-house overlay (agent-workspace
#    sync-hooks.sh) can overwrite it in place on in-house machines without
#    fighting a symlink. L2 wins; see ADR-043 / header note above.
# ---------------------------------------------------------------------------
statusline_src="${FRAMEWORK_ROOT}/configs/claude/statusline.sh"
if [[ -f "${statusline_src}" ]]; then
  mkdir -p "${HOME}/.claude"
  statusline_dst="${HOME}/.claude/statusline.sh"
  if [[ -f "${statusline_dst}" ]] && cmp -s "${statusline_src}" "${statusline_dst}"; then
    ok "statusline.sh → ~/.claude/ (already current)"
  elif (( DRY_RUN == 1 )); then
    printf '  [dry-run] install -m 755 %s %s\n' "${statusline_src}" "${statusline_dst}"
  else
    install -m 755 "${statusline_src}" "${statusline_dst}"
    ok "statusline.sh → ~/.claude/"
  fi
fi

# ---------------------------------------------------------------------------
# 5) AGENTS.md — copy as base. Personas APPEND to this; never edit.
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
      find agent-context/constraints -type f -name '*.md' -print0 \
        | sort -z | xargs -0 shasum -a 256
      [[ -f configs/claude/statusline.sh ]] && shasum -a 256 configs/claude/statusline.sh
      [[ -f AGENTS.md ]] && shasum -a 256 AGENTS.md
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
echo "   Targets: ~/.claude/{skills,hooks,statusline.sh,AGENTS.md.framework-base}"
echo "            ~/.codex/skills"
echo "            ~/.local/bin"
echo ""
echo "   Update path: scripts/check-update.sh (run via cron / SessionStart)."
(( REFUSED == 0 )) || exit 3
