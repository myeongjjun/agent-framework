#!/bin/bash
# codex-auto-handoff.sh
# Auto-generate handoff entry (v1.0.0 format) and delegate to Codex CLI
#
# Usage:
#   ./codex-auto-handoff.sh [OPTIONS] "task description"
#
# This script:
#   1. Collects current project context (git status, files, etc.)
#   2. Creates a handoff entry in .agent/entry-*.md (v1.0.0 format)
#   3. Delegates to Codex with the generated context
#
# Example:
#   ./codex-auto-handoff.sh "Refactor authentication system"
#   ./codex-auto-handoff.sh --objective "Add search feature" "Implement search API"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DEFAULT_MODEL="gpt-5.4"
DEFAULT_SANDBOX="workspace-write"
DEFAULT_REASONING="high"

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] "task description"

Auto-generate handoff entry (v1.0.0 format) and delegate to Codex CLI.

OPTIONS:
  -h, --help                  Show this help message
  -o, --objective TEXT        Primary objective (default: inferred from task)
  -c, --constraints TEXT      Constraints/decisions (comma-separated or quoted list)
  --completed TEXT            Work already completed (comma-separated)
  -m, --model MODEL           Codex model (default: gpt-5.4)
  -s, --sandbox MODE          Sandbox mode (default: workspace-write)
  -r, --reasoning LEVEL       Reasoning effort (default: xhigh)
  --read-only                 Use read-only sandbox
  --skip-entry                Skip entry creation, just run codex
  --dry-run                   Show generated entry without executing

EXAMPLES:
  # Basic usage - auto-generate entry and delegate
  $(basename "$0") "Implement JWT authentication"

  # With explicit objective and constraints
  $(basename "$0") \\
    --objective "Add authentication" \\
    --constraints "Do not modify tests/, Keep API compatible" \\
    "Implement JWT auth in src/auth/"

  # Mark work already completed
  $(basename "$0") \\
    --completed "Designed API, Created models" \\
    "Implement the authentication endpoints"

  # Read-only analysis
  $(basename "$0") --read-only "Review security of auth system"

  # Dry run - see entry without executing
  $(basename "$0") --dry-run "Test task"

NOTES:
  - Creates .agent/entry-YYYYMMDD-HHMMSS-KST.md (v1.0.0 6-section format)
  - Collects git status, changed files, branch info
  - Updates .agent/LATEST.md pointer
  - Task description becomes Next Steps section

EOF
  exit 0
}

# Parse arguments
OBJECTIVE=""
CONSTRAINTS=""
COMPLETED=""
MODEL="$DEFAULT_MODEL"
SANDBOX="$DEFAULT_SANDBOX"
REASONING="$DEFAULT_REASONING"
SKIP_ENTRY=false
DRY_RUN=false
TASK=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      ;;
    -o|--objective)
      OBJECTIVE="$2"
      shift 2
      ;;
    -c|--constraints)
      CONSTRAINTS="$2"
      shift 2
      ;;
    --completed)
      COMPLETED="$2"
      shift 2
      ;;
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    -s|--sandbox)
      SANDBOX="$2"
      shift 2
      ;;
    -r|--reasoning)
      REASONING="$2"
      shift 2
      ;;
    --read-only)
      SANDBOX="read-only"
      shift
      ;;
    --skip-entry)
      SKIP_ENTRY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      echo -e "${RED}Error: Unknown option $1${NC}" >&2
      exit 1
      ;;
    *)
      TASK="$1"
      shift
      ;;
  esac
done

# Validate
if [ -z "$TASK" ]; then
  echo -e "${RED}Error: Task description required${NC}" >&2
  exit 1
fi

# Find project root (git root or current directory)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$PROJECT_ROOT"

# Create .agent directory
mkdir -p .agent

# Collect project context
echo -e "${BLUE}Collecting project context...${NC}"

# Git info (optional - v1.0.0 supports non-git projects)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  GIT_INFO="${BRANCH}@${HEAD}"
  CHANGED_FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null | sort -u)
  CHANGED_COUNT=$(echo "$CHANGED_FILES" | grep -c . || echo "0")
else
  GIT_INFO="N/A"
  CHANGED_FILES=""
  CHANGED_COUNT="0"
fi

# Timestamp
TIMESTAMP=$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S)
DATE_READABLE=$(TZ=Asia/Seoul date +"%Y-%m-%d %H:%M")

# Entry filename
ENTRY_FILE="entry-${TIMESTAMP}-KST.md"

# Default objective from task if not specified
if [ -z "$OBJECTIVE" ]; then
  OBJECTIVE="$TASK"
fi

# Format constraints as Decisions Made
DECISIONS_FORMATTED=""
if [ -n "$CONSTRAINTS" ]; then
  # Split by comma and format as bullet list
  IFS=',' read -ra CONSTRAINT_ARRAY <<< "$CONSTRAINTS"
  for constraint in "${CONSTRAINT_ARRAY[@]}"; do
    constraint_trimmed=$(echo "$constraint" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    DECISIONS_FORMATTED+="- **${constraint_trimmed}**: Project constraint\n"
  done
fi
DECISIONS_FORMATTED+="- **Delegate to Codex**: Efficient execution of implementation task\n"

# Format completed work
DONE_FORMATTED=""
REMAINING_FORMATTED=""
if [ -n "$COMPLETED" ]; then
  IFS=',' read -ra COMPLETED_ARRAY <<< "$COMPLETED"
  for item in "${COMPLETED_ARRAY[@]}"; do
    item_trimmed=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    DONE_FORMATTED+="- [x] ${item_trimmed}\n"
  done
else
  DONE_FORMATTED="- (Starting from beginning)\n"
fi

# Format changed files for Key files
KEY_FILES_FORMATTED=""
if [ "$CHANGED_COUNT" -gt 0 ] && [ "$CHANGED_COUNT" -lt 10 ]; then
  while IFS= read -r file; do
    [ -n "$file" ] && KEY_FILES_FORMATTED+="- \`$file\`: modified\n"
  done <<< "$CHANGED_FILES"
else
  KEY_FILES_FORMATTED="- (See git status for details)\n"
fi

# Get Codex CLI version
CLI_VERSION=$(codex --version 2>/dev/null | head -1 || echo "unknown")

# Generate handoff entry (v1.0.0 format - 6 sections)
echo -e "${BLUE}Generating handoff entry (v1.0.0 format)...${NC}"

ENTRY_CONTENT="# Handoff — ${DATE_READABLE} KST

## Session

| Key | Value |
|-----|-------|
| ID | N/A |
| Agent | Codex ${CLI_VERSION} |
| Project | ${PROJECT_ROOT} |
| Git | ${GIT_INFO} |
| Duration | auto-generated |
| Tokens | N/A |
| Trigger | user_request |

## Conversation Context

> Auto-generated handoff for Codex delegation.

### Topic Flow

1. **Task request**: User requested delegation to Codex

### Decisions Made

${DECISIONS_FORMATTED}

### Clarifications

- (None - auto-generated entry)

## Objective

**Goal**: ${OBJECTIVE}

**Done**:
${DONE_FORMATTED}

**Remaining**:
- [ ] ${TASK}
- [ ] Run verification commands
- [ ] Report completion summary

## Current State

**Last action**: Auto-generated handoff entry for Codex delegation

**Blockers**:
- None

**Key files**:
${KEY_FILES_FORMATTED}

## Next Steps

1. ${TASK}
   - Expected: Task completed successfully
2. Run verification commands (build, test, type-check as applicable)
   - Expected: All checks pass
3. Report completion summary
   - Expected: Clear summary of changes made

## Takeover

\`\`\`bash
# For Codex
codex \"Read .agent/${ENTRY_FILE} and continue. Follow Next Steps section.\"

# For Claude Code
claude \"Read .agent/${ENTRY_FILE} and continue. Follow Next Steps section.\"
\`\`\`
"

# Dry run - show entry and exit
if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}Dry run - generated entry (v1.0.0 format):${NC}"
  echo ""
  echo -e "$ENTRY_CONTENT"
  echo ""
  echo -e "${YELLOW}Would save to: .agent/$ENTRY_FILE${NC}"
  exit 0
fi

# Save entry file
if [ "$SKIP_ENTRY" = false ]; then
  echo -e "$ENTRY_CONTENT" > ".agent/$ENTRY_FILE"
  echo -e "${GREEN}Created handoff entry: .agent/$ENTRY_FILE${NC}"

  # Update LATEST.md
  cat > .agent/LATEST.md <<EOF
# Latest Handoff

- **Entry**: ${ENTRY_FILE}
- **Time**: ${DATE_READABLE} KST
- **From**: Codex ${CLI_VERSION}
- **Objective**: ${OBJECTIVE}
- **Next**: ${TASK}
EOF

  echo -e "${GREEN}Updated .agent/LATEST.md${NC}"
fi

# Delegate to Codex
echo ""
echo -e "${BLUE}Delegating to Codex...${NC}"
echo "  Model: $MODEL"
echo "  Sandbox: $SANDBOX"
echo "  Reasoning: $REASONING"
echo ""

PROMPT="Context from Claude Code:

${ENTRY_CONTENT}

---

Task: ${TASK}

IMPORTANT:
- Follow Next Steps section from the context in order
- Respect Decisions Made strictly (including constraints)
- If anything is unclear, make best-effort assumptions and document them

After completion:
- Summarize what was done
- Report any issues or blockers encountered"

codex exec -m "$MODEL" -s "$SANDBOX" \
  -c "model_reasoning_effort=$REASONING" \
  "$PROMPT"

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}Codex completed successfully${NC}"
  echo -e "${BLUE}Entry saved at: .agent/$ENTRY_FILE${NC}"
else
  echo -e "${RED}Codex exited with code $EXIT_CODE${NC}"
  echo -e "${YELLOW}Entry saved at: .agent/$ENTRY_FILE (for debugging)${NC}"
fi

exit $EXIT_CODE
