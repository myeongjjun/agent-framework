#!/usr/bin/env bash
# agent-promote.sh — Promote a dispatched worker branch into the base
# session's current branch via squash-merge. Replaces ad-hoc
# `git cherry-pick` for the routine worker → base integration flow.
#
# Run from the base repo (not from inside a worker worktree).
#
# Usage: agent-promote.sh <slug> [flags]   (on PATH via ~/.local/bin)
#
# Flags:
#   --no-ff               Preserve worker history (default is --squash merge)
#   --yes                 Non-interactive: skip prompts, fail on conflicts
#   --yes-risk            Auto-accept risky-file warnings
#   --cleanup             Delete worker branch + worktree after a clean merge
#   --target <branch>     Override auto-detected base branch
#   --branch <name>       Override auto-detected worker branch (multi-match)
#   --dry-run             Print the plan; do not execute
#   --message <msg>       Override derived commit message
#   --force-dirty-base    Allow merge into a dirty base working tree
#   -h, --help            Show this help
#
# Refuses:
#   - Worker branch absent or matches multiple without --branch
#   - Base in detached HEAD
#   - Base working tree dirty (override: --force-dirty-base)
#   - Worker branch has no commits ahead of merge-base
#
# Risk patterns (warn unless --yes-risk):
#   .env / .env.* , *.key , id_rsa* , *.log , .DS_Store , files > 1 MB

set -euo pipefail

SCRIPT_NAME="agent-promote.sh"

usage() {
  cat <<'USAGE'
agent-promote.sh — Promote a dispatched worker branch into the base
session's current branch via squash-merge. Replaces ad-hoc
`git cherry-pick` for the routine worker → base integration flow.

Run from the base repo (not from inside a worker worktree).

Usage: agent-promote.sh <slug> [flags]   (on PATH via ~/.local/bin)

Flags:
  --no-ff               Preserve worker history (default is --squash merge)
  --yes                 Non-interactive: skip prompts, fail on conflicts
  --yes-risk            Auto-accept risky-file warnings
  --cleanup             Delete worker branch + worktree after a clean merge
  --target <branch>     Override auto-detected base branch
  --branch <name>       Override auto-detected worker branch (multi-match)
  --dry-run             Print the plan; do not execute
  --message <msg>       Override derived commit message
  --force-dirty-base    Allow merge into a dirty base working tree
  -h, --help            Show this help

Refuses:
  - Worker branch absent or matches multiple without --branch
  - Base in detached HEAD
  - Base working tree dirty (override: --force-dirty-base)
  - Worker branch has no commits ahead of merge-base

Risk patterns (warn unless --yes-risk):
  .env / .env.* , *.key , id_rsa* , *.log , .DS_Store , files > 1 MB
USAGE
}

die()  { echo "${SCRIPT_NAME}: $*" >&2; exit 1; }
warn() { echo "${SCRIPT_NAME}: $*" >&2; }
info() { echo "$*"; }

# --- Argument parsing -------------------------------------------------------

SLUG=""
MERGE_STYLE="squash"      # squash | no-ff
YES=0
YES_RISK=0
CLEANUP=0
TARGET=""
WORKER_BRANCH_OVERRIDE=""
DRY_RUN=0
MSG_OVERRIDE=""
FORCE_DIRTY_BASE=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help)         usage; exit 0 ;;
    --no-ff)           MERGE_STYLE="no-ff"; shift ;;
    --yes)             YES=1; shift ;;
    --yes-risk)        YES_RISK=1; shift ;;
    --cleanup)         CLEANUP=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --force-dirty-base) FORCE_DIRTY_BASE=1; shift ;;
    --target)          TARGET="${2:-}"; shift 2 ;;
    --target=*)        TARGET="${1#*=}"; shift ;;
    --branch)          WORKER_BRANCH_OVERRIDE="${2:-}"; shift 2 ;;
    --branch=*)        WORKER_BRANCH_OVERRIDE="${1#*=}"; shift ;;
    --message)         MSG_OVERRIDE="${2:-}"; shift 2 ;;
    --message=*)       MSG_OVERRIDE="${1#*=}"; shift ;;
    --)                shift; break ;;
    -*)                die "unknown flag: $1" ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      else
        die "unexpected positional argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$SLUG" ]] || { usage >&2; die "missing <slug> argument"; }

# --- Locate base repo -------------------------------------------------------

BASE_REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"

if [[ "$BASE_REPO" == *"/.worktrees/dispatch-"* ]] \
  || [[ "$BASE_REPO" == *"/.local/share/sib/worktrees/"* ]]; then
  die "must be run from the base repo, not from inside a worker worktree (cwd=$BASE_REPO)"
fi

# --- Resolve worker branch --------------------------------------------------

resolve_worker_branch() {
  if [[ -n "$WORKER_BRANCH_OVERRIDE" ]]; then
    git -C "$BASE_REPO" show-ref --verify --quiet "refs/heads/$WORKER_BRANCH_OVERRIDE" \
      || die "worker branch override '$WORKER_BRANCH_OVERRIDE' does not exist"
    printf '%s\n' "$WORKER_BRANCH_OVERRIDE"
    return
  fi

  local matches count
  matches=$(git -C "$BASE_REPO" for-each-ref --format='%(refname:short)' \
    "refs/heads/dispatch/${SLUG}-*" \
    "refs/heads/sib/${SLUG}" \
    "refs/heads/sib/${SLUG}-*")
  count=$(printf '%s' "$matches" | grep -c '^' || true)

  if (( count == 0 )); then
    die "no worker branch found for slug '${SLUG}' (searched refs/heads/dispatch/${SLUG}-*, refs/heads/sib/${SLUG}, refs/heads/sib/${SLUG}-*)"
  fi
  if (( count > 1 )); then
    warn "multiple worker branches matched slug '${SLUG}':"
    printf '%s\n' "$matches" | sed 's/^/  - /' >&2
    die "pass --branch <name> to disambiguate"
  fi
  printf '%s\n' "$matches"
}

WORKER_BRANCH="$(resolve_worker_branch)"

# --- Locate worker worktree -------------------------------------------------

worker_worktree_path() {
  git -C "$BASE_REPO" worktree list --porcelain | awk -v b="refs/heads/${WORKER_BRANCH}" '
    $1=="worktree" { wt=$2 }
    $1=="branch" && $2==b { print wt; exit }
  '
}
WORKER_WT="$(worker_worktree_path)"

# --- Compute merge-base + ahead count --------------------------------------

MERGE_BASE="$(git -C "$BASE_REPO" merge-base "$WORKER_BRANCH" HEAD 2>/dev/null)" \
  || die "could not find merge-base between $WORKER_BRANCH and HEAD"

AHEAD_COUNT=$(git -C "$BASE_REPO" rev-list --count "${MERGE_BASE}..${WORKER_BRANCH}")
(( AHEAD_COUNT > 0 )) || die "worker branch '$WORKER_BRANCH' has no commits ahead of merge-base"

# --- Resolve base branch ----------------------------------------------------

CURRENT_HEAD="$(git -C "$BASE_REPO" rev-parse --abbrev-ref HEAD)"
[[ "$CURRENT_HEAD" == "HEAD" ]] && die "base is in detached HEAD; checkout a branch first or pass --target <branch>"

BASE_BRANCH="${TARGET:-$CURRENT_HEAD}"

if [[ "$BASE_BRANCH" != "$CURRENT_HEAD" ]]; then
  die "--target '$BASE_BRANCH' differs from current branch '$CURRENT_HEAD'; checkout the target branch first"
fi

# Refuse on dirty base unless overridden. Exclude `.worktrees/` via pathspec
# so the check is robust even if the repo doesn't gitignore worktrees (from
# Codex synth: more robust than gitignore-reliant detection).
if (( FORCE_DIRTY_BASE == 0 )); then
  if [[ -n "$(git -C "$BASE_REPO" status --porcelain -- . ':(exclude).worktrees')" ]]; then
    die "base working tree is dirty; commit/stash first or pass --force-dirty-base"
  fi
fi

# --- Inspect commits + changed files ---------------------------------------

WIP_LOG=$(git -C "$BASE_REPO" log --oneline --grep="^wip(${SLUG}):" "${MERGE_BASE}..${WORKER_BRANCH}" 2>/dev/null || true)
WIP_COUNT=$(printf '%s' "$WIP_LOG" | grep -c '^' || true)

CHANGED_FILES_RAW=$(git -C "$BASE_REPO" diff --name-status "${MERGE_BASE}...${WORKER_BRANCH}")
CHANGED_FILES=$(printf '%s\n' "$CHANGED_FILES_RAW" | awk 'NF{print $NF}')
CHANGED_FILE_COUNT=$(printf '%s' "$CHANGED_FILES" | grep -c '^' || true)

# --- Risk scan --------------------------------------------------------------

scan_risks() {
  local f size base
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    base="${f##*/}"
    case "$base" in
      .env|.env.*) printf '  - %s (matches: .env*)\n' "$f" ;;
      *.key)       printf '  - %s (matches: *.key)\n' "$f" ;;
      id_rsa*)     printf '  - %s (matches: id_rsa*)\n' "$f" ;;
      *.log)       printf '  - %s (matches: *.log)\n' "$f" ;;
      .DS_Store)   printf '  - %s (matches: .DS_Store)\n' "$f" ;;
    esac
    size=$(git -C "$BASE_REPO" cat-file -s "${WORKER_BRANCH}:${f}" 2>/dev/null || echo 0)
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 1048576 )); then
      printf '  - %s (size: %d bytes > 1MB)\n' "$f" "$size"
    fi
  done <<< "$CHANGED_FILES"
}

RISKS="$(scan_risks)"

# --- Derive commit message --------------------------------------------------

derive_message() {
  if [[ -n "$MSG_OVERRIDE" ]]; then
    printf '%s\n' "$MSG_OVERRIDE"
    return
  fi
  local subject
  subject=$(git -C "$BASE_REPO" log --format='%s' --invert-grep --grep="^wip(${SLUG}):" "${MERGE_BASE}..${WORKER_BRANCH}" 2>/dev/null | tail -1)
  if [[ -z "$subject" ]]; then
    subject="chore(${SLUG}): integrate worker branch"
  fi
  printf '%s (from %s)\n' "$subject" "$WORKER_BRANCH"
}

COMMIT_MSG="$(derive_message)"

# --- Plan -------------------------------------------------------------------

cat <<EOF
agent-promote plan
  slug:            ${SLUG}
  worker branch:   ${WORKER_BRANCH}
  worker worktree: ${WORKER_WT:-<none registered>}
  base branch:     ${BASE_BRANCH}
  base repo:       ${BASE_REPO}
  merge-base:      ${MERGE_BASE}
  commits ahead:   ${AHEAD_COUNT} (wip: ${WIP_COUNT})
  files changed:   ${CHANGED_FILE_COUNT}
  merge style:     ${MERGE_STYLE}
  commit msg:      ${COMMIT_MSG}
EOF

if [[ -n "$RISKS" ]]; then
  echo ""
  echo "Risk-pattern matches:"
  printf '%s\n' "$RISKS"
fi

if (( DRY_RUN == 1 )); then
  echo ""
  echo "(dry-run — no changes applied)"
  exit 0
fi

# --- Risk confirmation ------------------------------------------------------

if [[ -n "$RISKS" && "$YES_RISK" -eq 0 ]]; then
  if (( YES == 1 )); then
    die "risk-pattern files detected; pass --yes-risk to auto-accept"
  fi
  if [[ -t 0 ]]; then
    read -rp "Proceed despite risk-pattern matches? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "aborted by user (risk scan)"
  else
    die "risk-pattern files detected and stdin is not a TTY; pass --yes-risk to auto-accept"
  fi
fi

# --- Step 5: squash wips on worker branch (cosmetic for --squash mode,
#             meaningful for --no-ff). Skip if any non-wip commit exists
#             so logical commits survive the squash. ---------------------

echo ""
echo "Applying:"

squash_wips_on_worker() {
  if [[ -z "$WORKER_WT" || ! -d "$WORKER_WT" ]]; then
    warn "  step 5: worker worktree missing; skipping wip squash"
    return
  fi
  if [[ -n "$(git -C "$WORKER_WT" status --porcelain)" ]]; then
    die "worker worktree '$WORKER_WT' is dirty; commit or discard changes first"
  fi
  local non_wip
  non_wip=$(git -C "$WORKER_WT" log --format='%H' --invert-grep --grep="^wip(${SLUG}):" "${MERGE_BASE}..HEAD" 2>/dev/null | grep -c '^' || true)
  if (( non_wip > 0 )); then
    info "  step 5: worker branch has ${non_wip} non-wip commit(s); leaving history intact"
    return
  fi
  if (( AHEAD_COUNT <= 1 )); then
    info "  step 5: single commit on worker branch; no squash needed"
    return
  fi
  info "  step 5: collapsing ${AHEAD_COUNT} wip commits on ${WORKER_BRANCH}"
  git -C "$WORKER_WT" reset --soft "$MERGE_BASE" >/dev/null
  git -C "$WORKER_WT" commit -m "wip(${SLUG}): collapsed ${AHEAD_COUNT} turn-end commits" >/dev/null
}
squash_wips_on_worker

# --- Step 7: merge into base ----------------------------------------------

if [[ "$MERGE_STYLE" == "squash" ]]; then
  info "  step 7: git merge --squash ${WORKER_BRANCH} → ${BASE_BRANCH}"
  if ! git -C "$BASE_REPO" merge --squash "$WORKER_BRANCH" >/dev/null; then
    die "merge --squash failed (conflicts); resolve manually then re-run"
  fi
  if ! git -C "$BASE_REPO" commit -m "$COMMIT_MSG" >/dev/null; then
    die "commit after squash failed; resolve and commit manually"
  fi
else
  info "  step 7: git merge --no-ff ${WORKER_BRANCH} → ${BASE_BRANCH}"
  if ! git -C "$BASE_REPO" merge --no-ff -m "$COMMIT_MSG" "$WORKER_BRANCH" >/dev/null; then
    die "merge --no-ff failed (conflicts); resolve manually then re-run"
  fi
fi

NEW_SHA="$(git -C "$BASE_REPO" rev-parse HEAD)"

echo ""
echo "Promotion complete:"
echo "  base branch:   ${BASE_BRANCH}"
echo "  new commit:    ${NEW_SHA}"
echo "  files merged:  ${CHANGED_FILE_COUNT}"
echo "  wips squashed: ${WIP_COUNT}"

# --- Optional cleanup -------------------------------------------------------

if (( CLEANUP == 1 )); then
  echo ""
  echo "Cleanup:"
  if [[ -n "$WORKER_WT" && -d "$WORKER_WT" ]]; then
    echo "  removing worktree: ${WORKER_WT}"
    git -C "$BASE_REPO" worktree remove --force "$WORKER_WT" \
      || warn "worktree remove failed (clean up manually if needed)"
  fi
  echo "  deleting branch:   ${WORKER_BRANCH}"
  git -C "$BASE_REPO" branch -D "$WORKER_BRANCH" >/dev/null \
    || warn "branch delete failed (clean up manually if needed)"
fi

exit 0
