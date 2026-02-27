#!/usr/bin/env bash
# GitHub Issues backend for ralph-taheri
# Wraps the `gh` CLI for issue management + GitHub Projects V2 kanban

set -euo pipefail

RALPH_LABEL="${RALPH_LABEL:-ralph-taheri}"

# --- GitHub Projects V2 ---
# Cached project metadata (set by project_init)
_PROJECT_NUMBER=""
_PROJECT_ID=""
_PROJECT_OWNER=""
_STATUS_FIELD_ID=""
_STATUS_TODO_ID=""
_STATUS_IN_PROGRESS_ID=""
_STATUS_DONE_ID=""

# Detect the repo owner (user or org) for project commands
_get_owner() {
  if [[ -n "$_PROJECT_OWNER" ]]; then
    echo "$_PROJECT_OWNER"
    return
  fi
  _PROJECT_OWNER=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null || echo "")
  echo "$_PROJECT_OWNER"
}

# Find an existing ralph-taheri project or create one
# Sets _PROJECT_NUMBER and _PROJECT_ID
project_find_or_create() {
  local title="${1:-ralph-taheri}"
  local owner
  owner=$(_get_owner)

  if [[ -z "$owner" ]]; then
    echo "Warning: Could not determine repo owner, skipping project board" >&2
    return 1
  fi

  # Search for existing project
  local existing
  existing=$(gh project list --owner "$owner" --format json --limit 50 2>/dev/null | \
    jq -r --arg t "$title" '.projects[] | select(.title == $t) | "\(.number) \(.id)"' 2>/dev/null | head -1) || true

  if [[ -n "$existing" ]]; then
    _PROJECT_NUMBER=$(echo "$existing" | awk '{print $1}')
    _PROJECT_ID=$(echo "$existing" | awk '{print $2}')
    echo "Found existing project: #$_PROJECT_NUMBER" >&2
  else
    # Create new project
    local result
    result=$(gh project create --owner "$owner" --title "$title" --format json 2>/dev/null) || {
      echo "Warning: Could not create project board (may need 'project' scope: gh auth refresh -s project)" >&2
      return 1
    }
    _PROJECT_NUMBER=$(echo "$result" | jq -r '.number')
    _PROJECT_ID=$(echo "$result" | jq -r '.id')
    echo "Created project board: #$_PROJECT_NUMBER" >&2

    # Link project to the current repo
    gh project link "$_PROJECT_NUMBER" --owner "$owner" --repo "$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" 2>/dev/null || true
  fi

  # Cache the Status field and its options
  _cache_status_field
}

# Cache the Status field ID and option IDs (Todo, In Progress, Done)
_cache_status_field() {
  local owner
  owner=$(_get_owner)

  if [[ -z "$_PROJECT_NUMBER" ]]; then
    return 1
  fi

  local fields
  fields=$(gh project field-list "$_PROJECT_NUMBER" --owner "$owner" --format json 2>/dev/null) || return 1

  # The Status field is a SingleSelectField with name "Status"
  _STATUS_FIELD_ID=$(echo "$fields" | jq -r '.fields[] | select(.name == "Status") | .id' 2>/dev/null)

  if [[ -z "$_STATUS_FIELD_ID" ]]; then
    echo "Warning: No Status field found on project board" >&2
    return 1
  fi

  # Get option IDs for each status
  local options
  options=$(echo "$fields" | jq -c '.fields[] | select(.name == "Status") | .options // []' 2>/dev/null)

  _STATUS_TODO_ID=$(echo "$options" | jq -r '.[] | select(.name == "Todo") | .id' 2>/dev/null || true)
  _STATUS_IN_PROGRESS_ID=$(echo "$options" | jq -r '.[] | select(.name == "In Progress") | .id' 2>/dev/null || true)
  _STATUS_DONE_ID=$(echo "$options" | jq -r '.[] | select(.name == "Done") | .id' 2>/dev/null || true)
}

# Initialize the project board (call once at startup)
# Returns 0 if project board is available, 1 if not
project_init() {
  local title="${1:-ralph-taheri}"
  project_find_or_create "$title" 2>/dev/null
}

# Add an issue to the project board and set it to Todo
project_add_issue() {
  local issue_number="$1"
  local owner
  owner=$(_get_owner)

  if [[ -z "$_PROJECT_NUMBER" || -z "$owner" ]]; then
    return 0  # silently skip if no project
  fi

  local repo_url
  repo_url=$(gh repo view --json url --jq '.url' 2>/dev/null)

  local result
  result=$(gh project item-add "$_PROJECT_NUMBER" \
    --owner "$owner" \
    --url "${repo_url}/issues/${issue_number}" \
    --format json 2>/dev/null) || {
    echo "Warning: Could not add issue #$issue_number to project board" >&2
    return 0
  }

  local item_id
  item_id=$(echo "$result" | jq -r '.id')

  # Set status to Todo if we have the option ID
  if [[ -n "$_STATUS_TODO_ID" && -n "$item_id" && -n "$_PROJECT_ID" ]]; then
    gh project item-edit \
      --project-id "$_PROJECT_ID" \
      --id "$item_id" \
      --field-id "$_STATUS_FIELD_ID" \
      --single-select-option-id "$_STATUS_TODO_ID" 2>/dev/null || true
  fi

  echo "$item_id"
}

# Move an issue to a status column on the project board
# status: "todo" | "in_progress" | "done"
project_move_issue() {
  local issue_number="$1"
  local status="$2"
  local owner
  owner=$(_get_owner)

  if [[ -z "$_PROJECT_NUMBER" || -z "$_PROJECT_ID" || -z "$owner" ]]; then
    return 0  # silently skip if no project
  fi

  # Find the item ID for this issue in the project
  local items
  items=$(gh project item-list "$_PROJECT_NUMBER" --owner "$owner" --format json --limit 100 2>/dev/null) || return 0

  local item_id
  item_id=$(echo "$items" | jq -r --arg num "$issue_number" \
    '.items[] | select(.content.number == ($num | tonumber)) | .id' 2>/dev/null | head -1) || true

  if [[ -z "$item_id" ]]; then
    # Issue not on board yet, try adding it
    item_id=$(project_add_issue "$issue_number")
  fi

  if [[ -z "$item_id" ]]; then
    return 0
  fi

  # Pick the right option ID
  local option_id=""
  case "$status" in
    todo)        option_id="$_STATUS_TODO_ID" ;;
    in_progress) option_id="$_STATUS_IN_PROGRESS_ID" ;;
    done)        option_id="$_STATUS_DONE_ID" ;;
  esac

  if [[ -n "$option_id" && -n "$_STATUS_FIELD_ID" ]]; then
    gh project item-edit \
      --project-id "$_PROJECT_ID" \
      --id "$item_id" \
      --field-id "$_STATUS_FIELD_ID" \
      --single-select-option-id "$option_id" 2>/dev/null || true
  fi
}

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

# Mark an issue as in-progress (label + project board)
mark_in_progress() {
  local number="$1"
  gh issue edit "$number" \
    --add-label "in-progress" \
    --remove-label "todo" 2>/dev/null || true
  project_move_issue "$number" "in_progress"
}

# Close an issue with a completion comment (label + project board)
mark_done() {
  local number="$1"
  local comment="${2:-Completed by ralph-taheri agent loop.}"

  gh issue close "$number" \
    --comment "$comment" 2>/dev/null || { echo "Failed to close issue #$number" >&2; return 1; }

  # Clean up the in-progress label
  gh issue edit "$number" \
    --remove-label "in-progress" 2>/dev/null || true

  project_move_issue "$number" "done"
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
