#!/usr/bin/env bash
# Linear backend for ralph-taheri
# Wraps Linear's GraphQL API via curl + jq

set -euo pipefail

LINEAR_API_URL="https://api.linear.app/graphql"
RALPH_LABEL="${RALPH_LABEL:-ralph-taheri}"

# Cache for workflow state IDs
_LINEAR_STATE_CACHE=""

# Base GraphQL query helper
linear_query() {
  local query="$1"
  local variables="${2:-{}}"

  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    echo "Error: LINEAR_API_KEY environment variable is not set" >&2
    return 1
  fi

  local payload
  payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')

  curl -s -X POST "$LINEAR_API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: $LINEAR_API_KEY" \
    -d "$payload"
}

# Fetch and cache the team's workflow state IDs
get_workflow_states() {
  if [[ -n "$_LINEAR_STATE_CACHE" ]]; then
    echo "$_LINEAR_STATE_CACHE"
    return 0
  fi

  local team_key="${LINEAR_TEAM_KEY:?LINEAR_TEAM_KEY must be set}"

  local result
  result=$(linear_query '
    query($teamKey: String!) {
      teams(filter: { key: { eq: $teamKey } }) {
        nodes {
          id
          states {
            nodes {
              id
              name
              type
            }
          }
        }
      }
    }
  ' "$(jq -n --arg k "$team_key" '{teamKey: $k}')")

  _LINEAR_STATE_CACHE=$(echo "$result" | jq -c '.data.teams.nodes[0].states.nodes')
  echo "$_LINEAR_STATE_CACHE"
}

# Get a specific state ID by type (unstarted, started, completed, cancelled)
get_state_id() {
  local state_type="$1"
  local states
  states=$(get_workflow_states)
  echo "$states" | jq -r --arg t "$state_type" '[.[] | select(.type == $t)][0].id // empty'
}

# Get a specific state ID by name
get_state_id_by_name() {
  local state_name="$1"
  local states
  states=$(get_workflow_states)
  echo "$states" | jq -r --arg n "$state_name" '[.[] | select(.name == $n)][0].id // empty'
}

# Get the team ID
get_team_id() {
  local team_key="${LINEAR_TEAM_KEY:?LINEAR_TEAM_KEY must be set}"

  local result
  result=$(linear_query '
    query($teamKey: String!) {
      teams(filter: { key: { eq: $teamKey } }) {
        nodes { id }
      }
    }
  ' "$(jq -n --arg k "$team_key" '{teamKey: $k}')")

  echo "$result" | jq -r '.data.teams.nodes[0].id // empty'
}

# Get the next issue: unstarted/backlog, labeled ralph-taheri, ordered by priority
get_next_issue() {
  local team_key="${LINEAR_TEAM_KEY:?LINEAR_TEAM_KEY must be set}"

  local result
  result=$(linear_query '
    query($teamKey: String!, $label: String!) {
      issues(
        filter: {
          team: { key: { eq: $teamKey } }
          labels: { name: { eq: $label } }
          state: { type: { in: ["unstarted", "backlog"] } }
        }
        orderBy: priority
        first: 20
      ) {
        nodes {
          id
          identifier
          title
          description
          priority
          state { name type }
          labels { nodes { name } }
          relations {
            nodes {
              type
              relatedIssue {
                id
                identifier
                state { type }
              }
            }
          }
        }
      }
    }
  ' "$(jq -n --arg k "$team_key" --arg l "$RALPH_LABEL" '{teamKey: $k, label: $l}')")

  local issues
  issues=$(echo "$result" | jq -c '.data.issues.nodes // []')

  if [[ "$issues" == "[]" || "$issues" == "null" ]]; then
    echo ""
    return 0
  fi

  # Find first non-blocked issue
  local count
  count=$(echo "$issues" | jq 'length')

  for ((i = 0; i < count; i++)); do
    local issue
    issue=$(echo "$issues" | jq ".[$i]")

    # Check if blocked by any open issue
    local blocked=false
    local blockers
    blockers=$(echo "$issue" | jq -c '[.relations.nodes[] | select(.type == "blocks") | .relatedIssue | select(.state.type != "completed" and .state.type != "cancelled")]')

    if [[ $(echo "$blockers" | jq 'length') -gt 0 ]]; then
      blocked=true
    fi

    # Also check description for "Blocked by" text references
    local desc
    desc=$(echo "$issue" | jq -r '.description // ""')
    if echo "$desc" | grep -qiE "blocked by [A-Z]+-[0-9]+"; then
      local text_blockers
      text_blockers=$(echo "$desc" | grep -oiE "[A-Z]+-[0-9]+" | sort -u)
      for blocker_id in $text_blockers; do
        local blocker_state
        blocker_state=$(linear_query '
          query($id: String!) {
            issueSearch(filter: { identifier: { eq: $id } }) {
              nodes { state { type } }
            }
          }
        ' "$(jq -n --arg id "$blocker_id" '{id: $id}')" | jq -r '.data.issueSearch.nodes[0].state.type // "completed"')

        if [[ "$blocker_state" != "completed" && "$blocker_state" != "cancelled" ]]; then
          blocked=true
          break
        fi
      done
    fi

    if [[ "$blocked" == "false" ]]; then
      echo "$issue" | jq -c '{id: .id, identifier: .identifier, title: .title, description: .description, priority: .priority}'
      return 0
    fi
  done

  echo ""
  return 0
}

# Get full details for a specific issue
get_issue_details() {
  local issue_id="$1"

  local result
  result=$(linear_query '
    query($id: String!) {
      issue(id: $id) {
        id
        identifier
        title
        description
        priority
        state { name type }
        labels { nodes { name } }
        comments {
          nodes {
            body
            createdAt
          }
        }
      }
    }
  ' "$(jq -n --arg id "$issue_id" '{id: $id}')")

  echo "$result" | jq -c '.data.issue'
}

# Mark an issue as in-progress
mark_in_progress() {
  local issue_id="$1"

  local in_progress_id
  in_progress_id=$(get_state_id_by_name "In Progress")
  if [[ -z "$in_progress_id" ]]; then
    in_progress_id=$(get_state_id "started")
  fi

  if [[ -z "$in_progress_id" ]]; then
    echo "Warning: Could not find In Progress state" >&2
    return 0
  fi

  linear_query '
    mutation($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
      }
    }
  ' "$(jq -n --arg id "$issue_id" --arg s "$in_progress_id" '{id: $id, stateId: $s}')" > /dev/null
}

# Close an issue with a completion comment
mark_done() {
  local issue_id="$1"
  local comment="${2:-Completed by ralph-taheri agent loop.}"

  local done_id
  done_id=$(get_state_id "completed")

  if [[ -z "$done_id" ]]; then
    echo "Warning: Could not find Done state" >&2
    return 1
  fi

  # Update state to Done
  linear_query '
    mutation($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
      }
    }
  ' "$(jq -n --arg id "$issue_id" --arg s "$done_id" '{id: $id, stateId: $s}')" > /dev/null

  # Add completion comment
  linear_query '
    mutation($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) {
        success
      }
    }
  ' "$(jq -n --arg id "$issue_id" --arg b "$comment" '{issueId: $id, body: $b}')" > /dev/null
}

# Count remaining open issues
count_remaining() {
  local team_key="${LINEAR_TEAM_KEY:?LINEAR_TEAM_KEY must be set}"

  local result
  result=$(linear_query '
    query($teamKey: String!, $label: String!) {
      issues(
        filter: {
          team: { key: { eq: $teamKey } }
          labels: { name: { eq: $label } }
          state: { type: { in: ["unstarted", "backlog"] } }
        }
      ) {
        nodes { id }
      }
    }
  ' "$(jq -n --arg k "$team_key" --arg l "$RALPH_LABEL" '{teamKey: $k, label: $l}')")

  echo "$result" | jq '.data.issues.nodes | length'
}

# Get the issue backend name (for logging)
backend_name() {
  echo "Linear"
}

# Format a commit message for this backend
format_commit_message() {
  local issue_identifier="$1"
  local title="$2"
  echo "feat: ${issue_identifier} - ${title}"
}

# Extract acceptance criteria from issue description
extract_acceptance_criteria() {
  local body="$1"
  echo "$body" | sed -n '/^## Acceptance [Cc]riteria/,/^## /p' | sed '1d;$d' | sed '/^$/d'
}
