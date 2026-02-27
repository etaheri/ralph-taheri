#!/usr/bin/env bash
# GitHub Issues backend for ralph-taheri
# Wraps the `gh` CLI for issue management

set -euo pipefail

RALPH_LABEL="${RALPH_LABEL:-ralph-taheri}"

# Get the next open issue labeled for ralph-taheri, sorted by priority
# Priority: P0 > P1 > P2 > P3 > unlabeled
# Among same priority, pick the lowest issue number (oldest first)
# Skips issues that have a "Blocked by #X" where #X is still open
get_next_issue() {
  local issues
  issues=$(gh issue list \
    --label "$RALPH_LABEL" \
    --state open \
    --json number,title,labels,body \
    --limit 50 2>/dev/null) || { echo ""; return 1; }

  if [[ -z "$issues" || "$issues" == "[]" ]]; then
    echo ""
    return 0
  fi

  # Sort by priority label (P0 first), then by issue number (lowest first)
  # Filter out issues blocked by still-open issues
  local sorted
  sorted=$(echo "$issues" | jq -r '
    # Add a priority score based on labels
    [.[] | . + {
      priority_score: (
        if (.labels | map(.name) | index("P0")) then 0
        elif (.labels | map(.name) | index("P1")) then 1
        elif (.labels | map(.name) | index("P2")) then 2
        elif (.labels | map(.name) | index("P3")) then 3
        else 4
        end
      )
    }]
    | sort_by(.priority_score, .number)
  ')

  # Check each issue for blocking dependencies
  local count
  count=$(echo "$sorted" | jq 'length')

  for ((i = 0; i < count; i++)); do
    local issue
    issue=$(echo "$sorted" | jq ".[$i]")

    local body
    body=$(echo "$issue" | jq -r '.body // ""')

    # Check for "Blocked by #N" patterns
    local blocked=false
    if echo "$body" | grep -qiE "blocked by #[0-9]+"; then
      local blockers
      blockers=$(echo "$body" | grep -oiE "#[0-9]+" | grep -oE "[0-9]+" | sort -u)

      for blocker_num in $blockers; do
        local blocker_state
        blocker_state=$(gh issue view "$blocker_num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [[ "$blocker_state" == "OPEN" ]]; then
          blocked=true
          break
        fi
      done
    fi

    if [[ "$blocked" == "false" ]]; then
      echo "$issue" | jq -c '.'
      return 0
    fi
  done

  # All issues are blocked
  echo ""
  return 0
}

# Get full details for a specific issue
get_issue_details() {
  local number="$1"
  gh issue view "$number" \
    --json number,title,body,labels,assignees,milestone \
    2>/dev/null || { echo ""; return 1; }
}

# Mark an issue as in-progress
mark_in_progress() {
  local number="$1"
  gh issue edit "$number" \
    --add-label "in-progress" \
    --remove-label "todo" 2>/dev/null || true
}

# Close an issue with a completion comment
mark_done() {
  local number="$1"
  local comment="${2:-Completed by ralph-taheri agent loop.}"

  gh issue close "$number" \
    --comment "$comment" 2>/dev/null || { echo "Failed to close issue #$number" >&2; return 1; }

  # Clean up the in-progress label
  gh issue edit "$number" \
    --remove-label "in-progress" 2>/dev/null || true
}

# Count remaining open issues labeled for ralph-taheri
count_remaining() {
  local count
  count=$(gh issue list \
    --label "$RALPH_LABEL" \
    --state open \
    --json number \
    --limit 100 2>/dev/null | jq 'length') || { echo "0"; return 1; }
  echo "$count"
}

# Get the issue backend name (for logging)
backend_name() {
  echo "GitHub Issues"
}

# Format a commit message for this backend
format_commit_message() {
  local issue_number="$1"
  local title="$2"
  echo "feat: #${issue_number} - ${title}"
}

# Extract acceptance criteria from issue body
extract_acceptance_criteria() {
  local body="$1"
  # Look for content under "## Acceptance criteria" heading
  echo "$body" | sed -n '/^## Acceptance [Cc]riteria/,/^## /p' | sed '1d;$d' | sed '/^$/d'
}
