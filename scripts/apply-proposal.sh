#!/usr/bin/env bash

set -euo pipefail

PROPOSAL_DIR="${HOME}/.claude/logs/proposals"

usage() {
  cat <<'EOF'
Usage: ./scripts/apply-proposal.sh <command> [args]

Commands:
  list                 Show proposal titles with current status
  show <file>          Display a proposal file
  mark <file> <status> Update the proposal status footer
  history              Show applied proposals with dates and release tags
  -h, --help           Show this help message

Status values:
  new | approved | applied | rejected

Optional environment variables for `mark`:
  PROPOSAL_TAG   Release tag to record (for example: agent-v1.2.3)
  PROPOSAL_DATE  Override the recorded date (default: today)
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

trim() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

ensure_proposal_dir() {
  [[ -d "$PROPOSAL_DIR" ]] || die "Proposal directory not found: ${PROPOSAL_DIR}"
}

resolve_proposal_file() {
  local raw_path="$1"

  if [[ -f "$raw_path" ]]; then
    printf '%s\n' "$raw_path"
    return 0
  fi

  if [[ -f "${PROPOSAL_DIR}/${raw_path}" ]]; then
    printf '%s\n' "${PROPOSAL_DIR}/${raw_path}"
    return 0
  fi

  die "Proposal file not found: ${raw_path}"
}

extract_proposal_titles() {
  local file="$1"

  grep -E '^## (Improvement )?Proposal([^:]*)?:[[:space:]]*.+$' "$file" \
    | sed -E 's/^## (Improvement )?Proposal([^:]*)?:[[:space:]]*//' \
    || true
}

latest_status_comment() {
  local file="$1"
  grep -E '<!--[[:space:]]*status:' "$file" | tail -1 || true
}

extract_comment_field() {
  local comment="$1"
  local field="$2"
  local regex=""

  case "$field" in
    status) regex='status:[[:space:]]*([^,>]+)' ;;
    tag) regex='tag:[[:space:]]*([^,>]+)' ;;
    date) regex='date:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2})' ;;
    *) die "Unsupported comment field: ${field}" ;;
  esac

  if [[ "$comment" =~ $regex ]]; then
    trim "${BASH_REMATCH[1]}"
  fi
}

proposal_metadata() {
  local file="$1"
  local comment
  local status
  local tag
  local date

  comment="$(latest_status_comment "$file")"
  status="$(extract_comment_field "$comment" status)"
  tag="$(extract_comment_field "$comment" tag)"
  date="$(extract_comment_field "$comment" date)"

  if [[ -z "$status" ]]; then
    status="new"
  fi

  printf '%s|%s|%s\n' "$status" "$tag" "$date"
}

validate_status() {
  case "$1" in
    new|approved|applied|rejected)
      ;;
    *)
      die "Invalid status: $1 (expected: new, approved, applied, rejected)"
      ;;
  esac
}

list_proposals() {
  ensure_proposal_dir

  shopt -s nullglob
  local files=("${PROPOSAL_DIR}"/*.md)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No proposal files found in ${PROPOSAL_DIR}"
    return 0
  fi

  printf '%-16s %-24s %s\n' "Status" "File" "Title"
  printf '%-16s %-24s %s\n' "------" "----" "-----"

  local file
  local status
  local tag
  local date
  local titles=()
  local title
  for file in "${files[@]}"; do
    IFS='|' read -r status tag date <<<"$(proposal_metadata "$file")"
    mapfile -t titles < <(extract_proposal_titles "$file")

    if [[ ${#titles[@]} -eq 0 ]]; then
      titles=("$(basename "$file")")
    fi

    for title in "${titles[@]}"; do
      printf '%-16s %-24s %s\n' "$status" "$(basename "$file")" "$title"
    done
  done
}

show_proposal() {
  local file="$1"
  sed -n '1,999p' "$file"
}

mark_proposal() {
  local file="$1"
  local status="$2"
  local existing_status
  local existing_tag
  local existing_date
  local tag
  local date
  local tmp_file
  local comment

  validate_status "$status"
  IFS='|' read -r existing_status existing_tag existing_date <<<"$(proposal_metadata "$file")"

  tag="${PROPOSAL_TAG:-$existing_tag}"
  date="${PROPOSAL_DATE:-$(date '+%F')}"

  if [[ "$status" != "applied" && -z "${PROPOSAL_TAG:-}" ]]; then
    tag="$existing_tag"
  fi

  tmp_file="$(mktemp)"
  awk '!/<!--[[:space:]]*status:/' "$file" >"$tmp_file"
  mv "$tmp_file" "$file"

  if [[ -n "$tag" ]]; then
    comment="<!-- status: ${status}, tag: ${tag}, date: ${date} -->"
  else
    comment="<!-- status: ${status}, date: ${date} -->"
  fi

  printf '\n%s\n' "$comment" >>"$file"
  echo "Updated $(basename "$file"): ${status}"
}

show_history() {
  ensure_proposal_dir

  shopt -s nullglob
  local files=("${PROPOSAL_DIR}"/*.md)
  shopt -u nullglob

  local rows=()
  local file
  local status
  local tag
  local date
  local titles=()
  local title
  for file in "${files[@]}"; do
    IFS='|' read -r status tag date <<<"$(proposal_metadata "$file")"
    [[ "$status" == "applied" ]] || continue

    mapfile -t titles < <(extract_proposal_titles "$file")
    if [[ ${#titles[@]} -eq 0 ]]; then
      titles=("$(basename "$file")")
    fi

    for title in "${titles[@]}"; do
      rows+=("${date:-unknown}"$'\t'"${tag:--}"$'\t'"$(basename "$file")"$'\t'"${title}")
    done
  done

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No applied proposals found."
    return 0
  fi

  printf '%-12s %-18s %-24s %s\n' "Date" "Tag" "File" "Title"
  printf '%-12s %-18s %-24s %s\n' "----" "---" "----" "-----"

  local row
  local row_date
  local row_tag
  local row_file
  local row_title
  while IFS=$'\t' read -r row_date row_tag row_file row_title; do
    printf '%-12s %-18s %-24s %s\n' "$row_date" "$row_tag" "$row_file" "$row_title"
  done < <(printf '%s\n' "${rows[@]}" | sort -r)
}

main() {
  local command="${1:-}"

  case "$command" in
    list)
      list_proposals
      ;;
    show)
      [[ -n "${2:-}" ]] || die "show requires a file path"
      show_proposal "$(resolve_proposal_file "$2")"
      ;;
    mark)
      [[ -n "${2:-}" ]] || die "mark requires a file path"
      [[ -n "${3:-}" ]] || die "mark requires a status"
      mark_proposal "$(resolve_proposal_file "$2")" "$3"
      ;;
    history)
      show_history
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      die "Unknown command: ${command}"
      ;;
  esac
}

main "$@"
