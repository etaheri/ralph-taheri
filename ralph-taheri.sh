#!/usr/bin/env bash
# ralph-taheri — Autonomous AI agent loop using GitHub Issues or Linear
#
# Usage:
#   ./ralph-taheri.sh                              # GitHub Issues, 10 iterations
#   ./ralph-taheri.sh --backend linear             # Linear, 10 iterations
#   ./ralph-taheri.sh --backend github 20          # GitHub Issues, 20 iterations
#   ./ralph-taheri.sh --backend linear --verify 10 # Linear + agent-browser verification
#
# Attribution:
#   Based on snarktank/ralph (MIT) — https://github.com/snarktank/ralph

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
BACKEND="github"
MAX_ITERATIONS=10
VERIFY=false
PROGRESS_FILE="${SCRIPT_DIR}/progress.txt"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --verify)
      VERIFY=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--backend github|linear] [--verify] [max_iterations]"
      echo ""
      echo "Options:"
      echo "  --backend github|linear   Issue backend (default: github)"
      echo "  --verify                  Enable agent-browser verification"
      echo "  max_iterations            Max loop iterations (default: 10)"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Unknown argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# --- Validate backend ---
case "$BACKEND" in
  github)
    source "${SCRIPT_DIR}/lib/github.sh"
    ;;
  linear)
    source "${SCRIPT_DIR}/lib/linear.sh"
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
      echo "Error: LINEAR_API_KEY must be set for Linear backend" >&2
      exit 1
    fi
    if [[ -z "${LINEAR_TEAM_KEY:-}" ]]; then
      echo "Error: LINEAR_TEAM_KEY must be set for Linear backend" >&2
      exit 1
    fi
    ;;
  *)
    echo "Error: Unknown backend '$BACKEND'. Use 'github' or 'linear'." >&2
    exit 1
    ;;
esac

if [[ "$VERIFY" == "true" ]]; then
  source "${SCRIPT_DIR}/lib/verify.sh"
fi

# --- Logging helpers ---
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $*"
}

log_progress() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $*" >> "$PROGRESS_FILE"
}

# --- Read CLAUDE.md template ---
CLAUDE_TEMPLATE="${SCRIPT_DIR}/CLAUDE.md"
if [[ ! -f "$CLAUDE_TEMPLATE" ]]; then
  echo "Error: CLAUDE.md not found at $CLAUDE_TEMPLATE" >&2
  exit 1
fi

# --- Main loop ---
log "Starting ralph-taheri agent loop"
log "Backend: $(backend_name)"
log "Max iterations: $MAX_ITERATIONS"
log "Verification: $VERIFY"
log "---"

iteration=0
completed=0
failed=0

while [[ $iteration -lt $MAX_ITERATIONS ]]; do
  iteration=$((iteration + 1))

  log "=== Iteration $iteration / $MAX_ITERATIONS ==="

  # Check how many issues remain
  remaining=$(count_remaining)
  log "Issues remaining: $remaining"

  if [[ "$remaining" -eq 0 ]]; then
    log "All issues completed! Exiting loop."
    break
  fi

  # Get next issue
  log "Fetching next issue..."
  issue_json=$(get_next_issue)

  if [[ -z "$issue_json" ]]; then
    log "No actionable issues found (all may be blocked). Exiting."
    break
  fi

  # Extract issue fields based on backend
  if [[ "$BACKEND" == "github" ]]; then
    ISSUE_ID=$(echo "$issue_json" | jq -r '.number')
    ISSUE_TITLE=$(echo "$issue_json" | jq -r '.title')
    ISSUE_BODY=$(echo "$issue_json" | jq -r '.body // ""')
    ISSUE_IDENTIFIER="#${ISSUE_ID}"
  else
    ISSUE_ID=$(echo "$issue_json" | jq -r '.id')
    ISSUE_IDENTIFIER=$(echo "$issue_json" | jq -r '.identifier')
    ISSUE_TITLE=$(echo "$issue_json" | jq -r '.title')
    ISSUE_BODY=$(echo "$issue_json" | jq -r '.description // ""')
  fi

  ISSUE_ACCEPTANCE_CRITERIA=$(extract_acceptance_criteria "$ISSUE_BODY")

  log "Working on: $ISSUE_IDENTIFIER - $ISSUE_TITLE"

  # Mark as in-progress
  mark_in_progress "$ISSUE_ID"
  log "Marked $ISSUE_IDENTIFIER as in-progress"

  # Determine if this is the last issue
  IS_LAST_ISSUE="false"
  if [[ "$remaining" -eq 1 ]]; then
    IS_LAST_ISSUE="true"
  fi

  # Build the prompt by injecting issue details into CLAUDE.md
  PROMPT=$(cat "$CLAUDE_TEMPLATE")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$ISSUE_ID|${ISSUE_ID}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$ISSUE_IDENTIFIER|${ISSUE_IDENTIFIER}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$ISSUE_TITLE|${ISSUE_TITLE}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$IS_LAST_ISSUE|${IS_LAST_ISSUE}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$BACKEND|${BACKEND}|g")

  # For body and acceptance criteria, use environment variables instead of sed
  # (they may contain special characters)
  export RALPH_ISSUE_BODY="$ISSUE_BODY"
  export RALPH_ISSUE_AC="$ISSUE_ACCEPTANCE_CRITERIA"
  export RALPH_ISSUE_ID="$ISSUE_ID"
  export RALPH_ISSUE_IDENTIFIER="$ISSUE_IDENTIFIER"
  export RALPH_ISSUE_TITLE="$ISSUE_TITLE"
  export RALPH_IS_LAST_ISSUE="$IS_LAST_ISSUE"
  export RALPH_BACKEND="$BACKEND"

  # Run Claude Code with the prompt
  log "Spawning Claude Code session..."
  log_progress "Started: $ISSUE_IDENTIFIER - $ISSUE_TITLE"

  CLAUDE_EXIT_CODE=0
  claude --print --dangerously-skip-permissions "$PROMPT

## Issue Details

**Issue:** $ISSUE_IDENTIFIER - $ISSUE_TITLE

**Description:**
$ISSUE_BODY

**Acceptance Criteria:**
$ISSUE_ACCEPTANCE_CRITERIA

---

Implement this issue now. Follow the instructions in the prompt above." 2>&1 | tee -a "$PROGRESS_FILE" || CLAUDE_EXIT_CODE=$?

  if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
    log "Claude Code exited with code $CLAUDE_EXIT_CODE"
    failed=$((failed + 1))
    log_progress "Failed: $ISSUE_IDENTIFIER - Claude exited with code $CLAUDE_EXIT_CODE"
    continue
  fi

  # Optional verification step
  if [[ "$VERIFY" == "true" ]]; then
    log "Running verification..."

    # Extract verification URL from issue body if present
    VERIFY_URL=$(echo "$ISSUE_BODY" | grep -oiE 'verify[- ]?url:\s*\S+' | head -1 | sed 's/[Vv]erify[- ]*[Uu][Rr][Ll]:\s*//' || true)
    VERIFY_SELECTORS=$(echo "$ISSUE_BODY" | grep -oiE 'verify[- ]?selectors?:\s*.+' | head -1 | sed 's/[Vv]erify[- ]*[Ss]electors*:\s*//' || true)

    if ! run_verification "$VERIFY_URL" "$VERIFY_SELECTORS"; then
      log "Verification FAILED for $ISSUE_IDENTIFIER"
      log "Reverting last commit..."
      git reset --soft HEAD~1 2>/dev/null || true
      failed=$((failed + 1))
      log_progress "Verification failed: $ISSUE_IDENTIFIER"

      # Re-mark as todo so it can be retried
      if [[ "$BACKEND" == "github" ]]; then
        gh issue edit "$ISSUE_ID" --add-label "todo" --remove-label "in-progress" 2>/dev/null || true
      fi
      continue
    fi

    log "Verification passed for $ISSUE_IDENTIFIER"
  fi

  # Close the issue
  commit_msg=$(format_commit_message "$ISSUE_IDENTIFIER" "$ISSUE_TITLE")
  mark_done "$ISSUE_ID" "Completed by ralph-taheri (iteration $iteration). Commit: $commit_msg"
  completed=$((completed + 1))

  log "Closed $ISSUE_IDENTIFIER"
  log_progress "Completed: $ISSUE_IDENTIFIER - $ISSUE_TITLE"
  log "---"
done

# --- Summary ---
log ""
log "========================================="
log "ralph-taheri loop complete"
log "========================================="
log "Iterations: $iteration / $MAX_ITERATIONS"
log "Completed:  $completed"
log "Failed:     $failed"
log "Remaining:  $(count_remaining)"
log "========================================="
