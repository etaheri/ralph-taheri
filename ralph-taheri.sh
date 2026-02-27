#!/usr/bin/env bash
# ralph-taheri — Autonomous AI agent loop using GitHub Issues or Linear
#
# Usage:
#   ./ralph-taheri.sh                              # GitHub Issues, 10 iterations
#   ./ralph-taheri.sh --backend linear             # Linear, 10 iterations
#   ./ralph-taheri.sh --backend github 20          # GitHub Issues, 20 iterations
#   ./ralph-taheri.sh --backend linear --verify 10 # Linear + agent-browser verification
#   ./ralph-taheri.sh --push 10                    # Push after each successful iteration
#
# Attribution:
#   Based on snarktank/ralph (MIT) — https://github.com/snarktank/ralph

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
BACKEND="github"
MAX_ITERATIONS=10
MAX_TURNS=75
VERIFY=false
PUSH=false
PROGRESS_FILE="progress.txt"

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
    --push)
      PUSH=true
      shift
      ;;
    --max-turns)
      MAX_TURNS="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--backend github|linear] [--verify] [--push] [--max-turns N] [max_iterations]"
      echo ""
      echo "Options:"
      echo "  --backend github|linear   Issue backend (default: github)"
      echo "  --verify                  Enable agent-browser verification"
      echo "  --push                    Push after each successful iteration"
      echo "  --max-turns N             Max Claude tool calls per issue (default: 75)"
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

# --- Trap handler for clean shutdown ---
CLAUDE_PID=""
cleanup() {
  echo ""
  log "Interrupted — cleaning up..."
  if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null
    wait "$CLAUDE_PID" 2>/dev/null || true
    log "Killed Claude process ($CLAUDE_PID)"
  fi
  exit 130
}
trap cleanup INT TERM

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

# --- Initialize progress.txt if it doesn't exist ---
if [[ ! -f "$PROGRESS_FILE" ]]; then
  cat > "$PROGRESS_FILE" <<'PROGRESS_INIT'
## Codebase Patterns
<!-- Add reusable patterns here as you discover them across iterations -->
<!-- Example: Always use `IF NOT EXISTS` for migrations -->
<!-- Example: Run `pnpm typecheck` before committing -->

---

# Ralph Progress Log
PROGRESS_INIT
  log "Initialized progress.txt"
fi

# --- Read CLAUDE.md template ---
CLAUDE_TEMPLATE="${SCRIPT_DIR}/CLAUDE.md"
if [[ ! -f "$CLAUDE_TEMPLATE" ]]; then
  echo "Error: CLAUDE.md not found at $CLAUDE_TEMPLATE" >&2
  exit 1
fi

# --- Initialize project board (GitHub only) ---
if [[ "$BACKEND" == "github" ]]; then
  if project_init "ralph-taheri" 2>/dev/null; then
    log "Project board ready: #$_PROJECT_NUMBER"
  else
    log "Project board not available (optional — run: gh auth refresh -s project)"
  fi
fi

# --- Main loop ---
log "Starting ralph-taheri agent loop"
log "Backend: $(backend_name)"
log "Max iterations: $MAX_ITERATIONS"
log "Max turns per issue: $MAX_TURNS"
log "Verification: $VERIFY"
log "Push: $PUSH"
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

  # Build the prompt by reading CLAUDE.md fresh each iteration
  # (in case Claude updated project CLAUDE.md files in prior iterations)
  PROMPT=$(cat "$CLAUDE_TEMPLATE")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$ISSUE_ID|${ISSUE_ID}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$ISSUE_IDENTIFIER|${ISSUE_IDENTIFIER}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$ISSUE_TITLE|${ISSUE_TITLE}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$IS_LAST_ISSUE|${IS_LAST_ISSUE}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$BACKEND|${BACKEND}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$ITERATION|${iteration}|g")
  PROMPT=$(echo "$PROMPT" | sed "s|\\\$MAX_ITERATIONS|${MAX_ITERATIONS}|g")

  # Export environment variables for Claude to access
  export RALPH_ISSUE_BODY="$ISSUE_BODY"
  export RALPH_ISSUE_AC="$ISSUE_ACCEPTANCE_CRITERIA"
  export RALPH_ISSUE_ID="$ISSUE_ID"
  export RALPH_ISSUE_IDENTIFIER="$ISSUE_IDENTIFIER"
  export RALPH_ISSUE_TITLE="$ISSUE_TITLE"
  export RALPH_IS_LAST_ISSUE="$IS_LAST_ISSUE"
  export RALPH_BACKEND="$BACKEND"
  export RALPH_ITERATION="$iteration"
  export RALPH_MAX_ITERATIONS="$MAX_ITERATIONS"

  # Run Claude Code with the prompt
  log "Spawning Claude Code session..."
  log_progress "Started: $ISSUE_IDENTIFIER - $ISSUE_TITLE (iteration $iteration)"

  CLAUDE_OUTPUT_FILE=$(mktemp)
  CLAUDE_EXIT_CODE=0
  claude --print --dangerously-skip-permissions --max-turns "$MAX_TURNS" "$PROMPT

## Issue Details

**Issue:** $ISSUE_IDENTIFIER - $ISSUE_TITLE

**Description:**
$ISSUE_BODY

**Acceptance Criteria:**
$ISSUE_ACCEPTANCE_CRITERIA

---

Implement this issue now. Follow the instructions in the prompt above." 2>&1 | tee "$CLAUDE_OUTPUT_FILE" &
  CLAUDE_PID=$!

  # Monitor output for completion signals — kill Claude early if it says it's done
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    if grep -qE "ISSUE_COMPLETE|COMPLETE|BLOCKED" "$CLAUDE_OUTPUT_FILE" 2>/dev/null; then
      log "Detected completion signal — stopping Claude session"
      kill "$CLAUDE_PID" 2>/dev/null
      wait "$CLAUDE_PID" 2>/dev/null || true
      break
    fi
    sleep 2
  done
  wait "$CLAUDE_PID" 2>/dev/null || CLAUDE_EXIT_CODE=$?
  CLAUDE_PID=""

  CLAUDE_OUTPUT=$(cat "$CLAUDE_OUTPUT_FILE")
  rm -f "$CLAUDE_OUTPUT_FILE"

  if [[ $CLAUDE_EXIT_CODE -ne 0 ]]; then
    log "Claude Code exited with code $CLAUDE_EXIT_CODE"
    failed=$((failed + 1))
    log_progress "Failed: $ISSUE_IDENTIFIER - Claude exited with code $CLAUDE_EXIT_CODE"
    continue
  fi

  # Check for blocked signal
  if echo "$CLAUDE_OUTPUT" | grep -q "<promise>BLOCKED</promise>"; then
    log "Claude reported BLOCKED for $ISSUE_IDENTIFIER"
    failed=$((failed + 1))
    log_progress "Blocked: $ISSUE_IDENTIFIER - Claude reported blocked"

    # Re-mark as blocked so it can be retried later
    if [[ "$BACKEND" == "github" ]]; then
      _ensure_label "blocked" "d93f0b"
      gh issue edit "$ISSUE_ID" --add-label "blocked" --remove-label "in-progress" 2>/dev/null || true
      project_move_issue "$ISSUE_ID" "todo"
    fi
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
        gh issue edit "$ISSUE_ID" --remove-label "in-progress" 2>/dev/null || true
        project_move_issue "$ISSUE_ID" "todo"
      fi
      continue
    fi

    log "Verification passed for $ISSUE_IDENTIFIER"
  fi

  # Close the issue
  commit_msg=$(format_commit_message "$ISSUE_IDENTIFIER" "$ISSUE_TITLE")
  mark_done "$ISSUE_ID" "Completed by ralph-taheri (iteration $iteration/$MAX_ITERATIONS). Commit: $commit_msg"
  completed=$((completed + 1))

  log "Closed $ISSUE_IDENTIFIER"
  log_progress "Completed: $ISSUE_IDENTIFIER - $ISSUE_TITLE"

  # Push if requested
  if [[ "$PUSH" == "true" ]]; then
    log "Pushing changes..."
    git push 2>/dev/null || {
      log "Warning: git push failed (no remote configured or auth issue)"
    }
  fi

  log "---"

  # Check for full completion signal
  if echo "$CLAUDE_OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    log "Claude signaled all work is COMPLETE"
    break
  fi

  sleep 2
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
