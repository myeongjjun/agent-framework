#!/bin/bash
# codex-with-context.sh
# Delegate task to Codex CLI with context from latest handoff entry (v1.0.0 format)
#
# Usage:
#   ./codex-with-context.sh "task description"
#   ./codex-with-context.sh --help
#
# Prerequisites:
#   - Handoff entry exists in .agent/entry-*.md (v1.0.0 format)
#   - Codex CLI installed and authenticated
#
# Example:
#   # First, create handoff entry via Claude Code:
#   /handoff
#
#   # Then delegate to Codex with context:
#   ./codex-with-context.sh "Implement the authentication changes"

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DEFAULT_MODEL="gpt-5.4"
DEFAULT_SANDBOX="workspace-write"
DEFAULT_REASONING="high"

# Help message
show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] "task description"

Delegate task to Codex CLI with context from latest handoff entry (v1.0.0 format).

OPTIONS:
  -h, --help              Show this help message
  -e, --entry FILE        Use specific handoff entry file (default: latest)
  -m, --model MODEL       Codex model to use (default: gpt-5.4)
  -s, --sandbox MODE      Sandbox mode (default: workspace-write)
  -r, --reasoning LEVEL   Reasoning effort (default: xhigh)
  --read-only             Use read-only sandbox (alias for -s read-only)
  --inline                Include entry content inline in prompt
  --reference             Reference entry by path (let Codex read it)
  --dry-run               Show what would be executed without running

EXAMPLES:
  # Use latest handoff entry
  $(basename "$0") "Implement authentication changes"

  # Use specific entry file
  $(basename "$0") -e .agent/entry-20251223-143000-KST.md "Continue work"

  # Read-only analysis (no file modifications)
  $(basename "$0") --read-only "Review the implementation"

  # Reference entry by path (smaller prompt)
  $(basename "$0") --reference "Continue from handoff entry"

  # Dry run (see command without executing)
  $(basename "$0") --dry-run "Test task"

NOTES:
  - Handoff entry must exist (create with /handoff in Claude Code)
  - Entry should follow handoff v1.0.0 (6-section) format
  - Task description is appended to context from entry
  - Codex will follow Next Steps section from entry
  - Codex must respect Decisions Made (including constraints) from entry

EOF
  exit 0
}

# Parse arguments
ENTRY_FILE=""
MODEL="$DEFAULT_MODEL"
SANDBOX="$DEFAULT_SANDBOX"
REASONING="$DEFAULT_REASONING"
INLINE_MODE=true
DRY_RUN=false
TASK=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      ;;
    -e|--entry)
      ENTRY_FILE="$2"
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
    --inline)
      INLINE_MODE=true
      shift
      ;;
    --reference)
      INLINE_MODE=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      echo -e "${RED}Error: Unknown option $1${NC}" >&2
      echo "Use --help for usage information"
      exit 1
      ;;
    *)
      TASK="$1"
      shift
      ;;
  esac
done

# Validate task
if [ -z "$TASK" ]; then
  echo -e "${RED}Error: Task description required${NC}" >&2
  echo "Usage: $(basename "$0") [OPTIONS] \"task description\""
  echo "Use --help for more information"
  exit 1
fi

# Find project root
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$PROJECT_ROOT"

# Find handoff entry
if [ -z "$ENTRY_FILE" ]; then
  # Find latest entry (check .agent/ first, then .ai/ for backward compatibility)
  ENTRY_FILE=$(ls -t .agent/entry-*.md 2>/dev/null | head -1 || echo "")

  if [ -z "$ENTRY_FILE" ]; then
    # Check legacy .ai/ directory
    ENTRY_FILE=$(ls -t .ai/entry-*.md 2>/dev/null | head -1 || echo "")
  fi

  if [ -z "$ENTRY_FILE" ]; then
    echo -e "${RED}Error: No handoff entry found${NC}" >&2
    echo ""
    echo "Solutions:"
    echo "  1. Create handoff entry via Claude Code: /handoff"
    echo "  2. Manually create .agent/entry-YYYYMMDD-HHMMSS-KST.md"
    echo "  3. Specify entry file: $(basename "$0") -e path/to/entry.md \"task\""
    exit 1
  fi

  echo -e "${GREEN}Found latest handoff entry:${NC} $ENTRY_FILE"
else
  # Validate specified entry file
  if [ ! -f "$ENTRY_FILE" ]; then
    echo -e "${RED}Error: Entry file not found: $ENTRY_FILE${NC}" >&2
    exit 1
  fi

  echo -e "${GREEN}Using specified handoff entry:${NC} $ENTRY_FILE"
fi

# Check entry size
ENTRY_SIZE=$(wc -c < "$ENTRY_FILE")
MAX_SIZE=8192  # ~2000 tokens

if [ "$ENTRY_SIZE" -gt "$MAX_SIZE" ]; then
  echo -e "${YELLOW}Warning: Handoff entry is large (${ENTRY_SIZE} bytes > ${MAX_SIZE} bytes)${NC}"
  echo "Consider summarizing or using --reference mode"
fi

# Build codex command
if [ "$INLINE_MODE" = true ]; then
  # Inline mode: include entry content in prompt
  ENTRY_CONTENT=$(cat "$ENTRY_FILE")

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

else
  # Reference mode: let Codex read the file
  PROMPT="Read the handoff entry at ${ENTRY_FILE} for full context.

Task: ${TASK}

IMPORTANT:
- Follow Next Steps section from the entry in order
- Respect Decisions Made strictly (including constraints)
- If anything is unclear, make best-effort assumptions and document them

After completion:
- Summarize what was done
- Report any issues or blockers"
fi

# Construct command
CMD=(
  codex exec
  -m "$MODEL"
  -s "$SANDBOX"
  -c "model_reasoning_effort=$REASONING"
  "$PROMPT"
)

# Show what will be executed
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Model: $MODEL"
echo "  Sandbox: $SANDBOX"
echo "  Reasoning: $REASONING"
echo "  Entry: $ENTRY_FILE"
echo "  Mode: $([ "$INLINE_MODE" = true ] && echo "inline" || echo "reference")"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}Dry run - would execute:${NC}"
  echo ""
  printf '%s ' "${CMD[@]}"
  echo ""
  echo ""
  echo -e "${YELLOW}Prompt preview (first 500 chars):${NC}"
  echo "$PROMPT" | head -c 500
  echo "..."
  echo ""
  exit 0
fi

# Execute
echo -e "${GREEN}Executing Codex...${NC}"
echo ""

"${CMD[@]}"

# Save result indicator
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
  echo -e "${GREEN}Codex completed successfully${NC}"
else
  echo -e "${RED}Codex exited with code $EXIT_CODE${NC}"
fi

exit $EXIT_CODE
