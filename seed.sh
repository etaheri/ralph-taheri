#!/usr/bin/env bash
# seed.sh — Convert a PRD into GitHub Issues or Linear issues
#
# Creates vertical-slice (tracer bullet) issues from a PRD markdown file.
# Issues are created in dependency order so real issue numbers can be referenced.
#
# Usage:
#   ./seed.sh --backend github --prd path/to/prd.md
#   ./seed.sh --backend linear --prd path/to/prd.md --team ENG
#
# Attribution:
#   Inspired by mattpocock/skills/prd-to-issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---
BACKEND="github"
PRD_FILE=""
LINEAR_TEAM=""
RALPH_LABEL="${RALPH_LABEL:-ralph-taheri}"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --prd)
      PRD_FILE="$2"
      shift 2
      ;;
    --team)
      LINEAR_TEAM="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 --backend github|linear --prd <path> [--team <key>]"
      echo ""
      echo "Options:"
      echo "  --backend github|linear   Issue backend (default: github)"
      echo "  --prd <path>              Path to PRD markdown file (required)"
      echo "  --team <key>              Linear team key (required for linear backend)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# --- Validation ---
if [[ -z "$PRD_FILE" ]]; then
  echo "Error: --prd is required" >&2
  exit 1
fi

if [[ ! -f "$PRD_FILE" ]]; then
  echo "Error: PRD file not found: $PRD_FILE" >&2
  exit 1
fi

if [[ "$BACKEND" == "linear" ]]; then
  if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    echo "Error: LINEAR_API_KEY must be set for Linear backend" >&2
    exit 1
  fi
  if [[ -z "$LINEAR_TEAM" && -z "${LINEAR_TEAM_KEY:-}" ]]; then
    echo "Error: --team is required for Linear backend" >&2
    exit 1
  fi
  LINEAR_TEAM="${LINEAR_TEAM:-$LINEAR_TEAM_KEY}"
fi

# Check for required tools
if ! command -v claude &>/dev/null; then
  echo "Error: claude CLI is required but not installed" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed" >&2
  exit 1
fi

if [[ "$BACKEND" == "github" ]] && ! command -v gh &>/dev/null; then
  echo "Error: gh CLI is required for GitHub backend" >&2
  exit 1
fi

# --- Read PRD ---
PRD_CONTENT=$(cat "$PRD_FILE")

echo "=== ralph-taheri seed ==="
echo "Backend: $BACKEND"
echo "PRD: $PRD_FILE"
echo ""
echo "Analyzing PRD and generating vertical-slice issues..."
echo ""

# --- Generate issues via Claude ---
CONVERSION_PROMPT=$(cat <<'PROMPT_EOF'
You are an expert at breaking down Product Requirements Documents into implementable issues using the vertical slice (tracer bullet) methodology.

Given the PRD below, create a set of issues that:

1. **Use vertical slices** — Each issue represents a thin end-to-end cut through all layers of the system (UI → API → DB → etc.), NOT horizontal slices of a single layer.
2. **Are independently demoable** — Each slice can be demonstrated and verified on its own.
3. **Have clear dependencies** — If slice B depends on slice A being done first, note it explicitly.
4. **Are ordered by dependency** — Blockers come before the issues they block.

Output ONLY valid JSON — no markdown, no explanation, just the JSON array.

Each issue should have this structure:
```json
{
  "title": "Short descriptive title",
  "description": "## What to build\nConcise description of this vertical slice.\n\n## Acceptance criteria\n- [ ] Criterion 1\n- [ ] Criterion 2\n- [ ] Typecheck passes\n\n## Blocked by\nNone - can start immediately",
  "priority": 1,
  "labels": ["ralph-taheri"],
  "depends_on_index": []
}
```

Priority: 1 = urgent, 2 = high, 3 = medium, 4 = low
`depends_on_index`: array of 0-based indices of issues in THIS array that must be completed first.

Rules:
- Start with the thinnest possible end-to-end slice (the "walking skeleton")
- Each subsequent slice adds one meaningful piece of functionality
- Include a final "polish and integration test" slice
- Keep it to 4-12 issues for most PRDs
- Every issue must have at least 2 acceptance criteria
- Include "Typecheck passes" as a criterion where applicable

Here is the PRD:

PROMPT_EOF
)

ISSUES_JSON=$(echo "${CONVERSION_PROMPT}

${PRD_CONTENT}" | claude --print 2>/dev/null)

# Try to extract JSON from the response (Claude might wrap it in markdown)
ISSUES_JSON=$(echo "$ISSUES_JSON" | sed -n '/^\[/,/^\]/p')

if [[ -z "$ISSUES_JSON" ]] || ! echo "$ISSUES_JSON" | jq '.' &>/dev/null; then
  echo "Error: Failed to parse Claude's output as JSON" >&2
  echo "Raw output:" >&2
  echo "$ISSUES_JSON" >&2
  exit 1
fi

ISSUE_COUNT=$(echo "$ISSUES_JSON" | jq 'length')
echo "Generated $ISSUE_COUNT issues"
echo ""

# --- Initialize project board (GitHub only) ---
if [[ "$BACKEND" == "github" ]]; then
  source "${SCRIPT_DIR}/lib/github.sh"
  echo "Setting up GitHub Project board..."
  if project_init "ralph-taheri"; then
    echo "Project board ready: #$_PROJECT_NUMBER"
    echo "View kanban: gh project view $_PROJECT_NUMBER --owner $(_get_owner) --web"
  else
    echo "Project board not available (optional — run: gh auth refresh -s project)"
  fi
  echo ""
fi

# --- Create issues ---
# We need to create them in order so we can map dependency indices to real issue numbers
declare -a CREATED_IDS=()

for ((i = 0; i < ISSUE_COUNT; i++)); do
  issue=$(echo "$ISSUES_JSON" | jq ".[$i]")
  title=$(echo "$issue" | jq -r '.title')
  description=$(echo "$issue" | jq -r '.description')
  priority=$(echo "$issue" | jq -r '.priority // 3')
  labels=$(echo "$issue" | jq -r '.labels // ["ralph-taheri"] | join(",")')
  depends_on=$(echo "$issue" | jq -c '.depends_on_index // []')

  # Resolve dependency indices to real issue IDs
  blocked_by_text=""
  dep_count=$(echo "$depends_on" | jq 'length')
  if [[ $dep_count -gt 0 ]]; then
    blocked_by_text="## Blocked by"
    for ((j = 0; j < dep_count; j++)); do
      dep_idx=$(echo "$depends_on" | jq ".[$j]")
      if [[ $dep_idx -lt ${#CREATED_IDS[@]} ]]; then
        dep_id="${CREATED_IDS[$dep_idx]}"
        if [[ "$BACKEND" == "github" ]]; then
          blocked_by_text="${blocked_by_text}
- #${dep_id}"
        else
          blocked_by_text="${blocked_by_text}
- ${dep_id}"
        fi
      fi
    done

    # Replace the "Blocked by" section in description
    if echo "$description" | grep -q "## Blocked by"; then
      description=$(echo "$description" | sed '/## Blocked by/,$d')
      description="${description}
${blocked_by_text}"
    else
      description="${description}

${blocked_by_text}"
    fi
  fi

  echo "Creating issue $((i + 1))/$ISSUE_COUNT: $title"

  if [[ "$BACKEND" == "github" ]]; then
    # Create GitHub issue
    priority_label="P${priority}"

    created=$(gh issue create \
      --title "$title" \
      --body "$description" \
      --label "$RALPH_LABEL" \
      --label "$priority_label" \
      2>/dev/null)

    # Extract issue number from URL
    issue_number=$(echo "$created" | grep -oE '[0-9]+$')
    CREATED_IDS+=("$issue_number")
    echo "  Created: #$issue_number"

    # Add to project board
    project_add_issue "$issue_number" >/dev/null 2>&1 || true

  elif [[ "$BACKEND" == "linear" ]]; then
    source "${SCRIPT_DIR}/lib/linear.sh"

    team_id=$(get_team_id)

    # Get the backlog/unstarted state
    state_id=$(get_state_id "backlog")
    if [[ -z "$state_id" ]]; then
      state_id=$(get_state_id "unstarted")
    fi

    # Create the issue
    result=$(linear_query '
      mutation($title: String!, $description: String!, $teamId: String!, $priority: Int!, $stateId: String!) {
        issueCreate(input: {
          title: $title
          description: $description
          teamId: $teamId
          priority: $priority
          stateId: $stateId
        }) {
          success
          issue {
            id
            identifier
          }
        }
      }
    ' "$(jq -n \
        --arg t "$title" \
        --arg d "$description" \
        --arg tid "$team_id" \
        --argjson p "$priority" \
        --arg sid "$state_id" \
        '{title: $t, description: $d, teamId: $tid, priority: $p, stateId: $sid}')")

    issue_id=$(echo "$result" | jq -r '.data.issueCreate.issue.id')
    issue_identifier=$(echo "$result" | jq -r '.data.issueCreate.issue.identifier')
    CREATED_IDS+=("$issue_identifier")
    echo "  Created: $issue_identifier"

    # Add ralph-taheri label
    # First, find or create the label
    label_result=$(linear_query '
      query($teamId: String!, $name: String!) {
        issueLabels(filter: { team: { id: { eq: $teamId } }, name: { eq: $name } }) {
          nodes { id }
        }
      }
    ' "$(jq -n --arg tid "$team_id" --arg n "$RALPH_LABEL" '{teamId: $tid, name: $n}')")

    label_id=$(echo "$label_result" | jq -r '.data.issueLabels.nodes[0].id // empty')

    if [[ -z "$label_id" ]]; then
      # Create the label
      label_create=$(linear_query '
        mutation($teamId: String!, $name: String!) {
          issueLabelCreate(input: { teamId: $teamId, name: $name, color: "#6B7280" }) {
            success
            issueLabel { id }
          }
        }
      ' "$(jq -n --arg tid "$team_id" --arg n "$RALPH_LABEL" '{teamId: $tid, name: $n}')")

      label_id=$(echo "$label_create" | jq -r '.data.issueLabelCreate.issueLabel.id')
    fi

    # Add label to issue
    if [[ -n "$label_id" ]]; then
      linear_query '
        mutation($id: String!, $labelIds: [String!]!) {
          issueUpdate(id: $id, input: { labelIds: $labelIds }) {
            success
          }
        }
      ' "$(jq -n --arg id "$issue_id" --arg lid "$label_id" '{id: $id, labelIds: [$lid]}')" > /dev/null
    fi

    # Set up dependency relations for Linear
    if [[ $dep_count -gt 0 ]]; then
      for ((j = 0; j < dep_count; j++)); do
        dep_idx=$(echo "$depends_on" | jq ".[$j]")
        if [[ $dep_idx -lt ${#CREATED_IDS[@]} ]]; then
          dep_identifier="${CREATED_IDS[$dep_idx]}"
          # Look up the issue ID from the identifier
          dep_result=$(linear_query '
            query($identifier: String!) {
              issueSearch(filter: { identifier: { eq: $identifier } }) {
                nodes { id }
              }
            }
          ' "$(jq -n --arg id "$dep_identifier" '{identifier: $id}')")

          dep_issue_id=$(echo "$dep_result" | jq -r '.data.issueSearch.nodes[0].id // empty')

          if [[ -n "$dep_issue_id" ]]; then
            linear_query '
              mutation($issueId: String!, $relatedIssueId: String!, $type: IssueRelationType!) {
                issueRelationCreate(input: { issueId: $issueId, relatedIssueId: $relatedIssueId, type: $type }) {
                  success
                }
              }
            ' "$(jq -n --arg id "$issue_id" --arg rid "$dep_issue_id" '{issueId: $id, relatedIssueId: $rid, type: "blocks"}')" > /dev/null
          fi
        fi
      done
    fi
  fi
done

# --- Summary ---
echo ""
echo "=== Seed complete ==="
echo "Created $ISSUE_COUNT issues in $([ "$BACKEND" == "github" ] && echo "GitHub Issues" || echo "Linear")"
echo ""
echo "Dependency graph:"
for ((i = 0; i < ISSUE_COUNT; i++)); do
  issue=$(echo "$ISSUES_JSON" | jq ".[$i]")
  title=$(echo "$issue" | jq -r '.title')
  depends_on=$(echo "$issue" | jq -c '.depends_on_index // []')
  dep_count=$(echo "$depends_on" | jq 'length')

  echo -n "  ${CREATED_IDS[$i]}: $title"
  if [[ $dep_count -gt 0 ]]; then
    deps=""
    for ((j = 0; j < dep_count; j++)); do
      dep_idx=$(echo "$depends_on" | jq ".[$j]")
      if [[ $dep_idx -lt ${#CREATED_IDS[@]} ]]; then
        deps="${deps} ${CREATED_IDS[$dep_idx]}"
      fi
    done
    echo " (blocked by:$deps)"
  else
    echo " (no dependencies)"
  fi
done

echo ""
if [[ "$BACKEND" == "github" && -n "$_PROJECT_NUMBER" ]]; then
  echo "View kanban board:"
  echo "  gh project view $_PROJECT_NUMBER --owner $(_get_owner) --web"
  echo ""
fi
echo "Run the agent loop:"
if [[ "$BACKEND" == "github" ]]; then
  echo "  ./ralph-taheri.sh --backend github $ISSUE_COUNT"
else
  echo "  ./ralph-taheri.sh --backend linear $ISSUE_COUNT"
fi
