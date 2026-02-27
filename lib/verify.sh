#!/usr/bin/env bash
# agent-browser verification helpers for ralph-taheri
# Uses Vercel's agent-browser for visual verification of UI changes

set -euo pipefail

VERIFY_SNAPSHOT_DIR="${VERIFY_SNAPSHOT_DIR:-.ralph-taheri-snapshots}"

# Check if agent-browser is available
verify_available() {
  command -v agent-browser &>/dev/null
}

# Open a URL in agent-browser and take a baseline snapshot
verify_start() {
  local url="$1"
  local snapshot_name="${2:-baseline}"

  if ! verify_available; then
    echo "Warning: agent-browser not installed, skipping verification" >&2
    return 1
  fi

  mkdir -p "$VERIFY_SNAPSHOT_DIR"

  echo "Opening $url in agent-browser..." >&2
  agent-browser open "$url" 2>/dev/null || {
    echo "Failed to open $url in agent-browser" >&2
    return 1
  }

  # Wait for page to load
  sleep 2

  # Take baseline screenshot
  local snapshot_path="${VERIFY_SNAPSHOT_DIR}/${snapshot_name}.png"
  agent-browser screenshot "$snapshot_path" 2>/dev/null || {
    echo "Failed to take baseline screenshot" >&2
    return 1
  }

  echo "$snapshot_path"
}

# Take a screenshot at the current state
verify_screenshot() {
  local path="$1"

  if ! verify_available; then
    return 1
  fi

  agent-browser screenshot "$path" 2>/dev/null || {
    echo "Failed to take screenshot" >&2
    return 1
  }

  echo "Screenshot saved to $path" >&2
}

# Check if a CSS selector is visible on the page
verify_check() {
  local selector="$1"

  if ! verify_available; then
    return 1
  fi

  local result
  result=$(agent-browser is visible "$selector" 2>/dev/null) || {
    echo "Verification check failed for selector: $selector" >&2
    return 1
  }

  if [[ "$result" == *"true"* || "$result" == *"visible"* ]]; then
    echo "Selector '$selector' is visible" >&2
    return 0
  else
    echo "Selector '$selector' is NOT visible" >&2
    return 1
  fi
}

# Compare current page against baseline snapshot
verify_diff() {
  local baseline="${1:-${VERIFY_SNAPSHOT_DIR}/baseline.png}"
  local current="${VERIFY_SNAPSHOT_DIR}/current.png"

  if ! verify_available; then
    return 1
  fi

  # Take current screenshot
  agent-browser screenshot "$current" 2>/dev/null || {
    echo "Failed to take comparison screenshot" >&2
    return 1
  }

  # Run visual diff
  local diff_result
  diff_result=$(agent-browser diff "$baseline" "$current" 2>/dev/null) || {
    echo "Visual diff failed" >&2
    return 1
  }

  echo "$diff_result"
}

# Close the agent-browser session
verify_close() {
  if ! verify_available; then
    return 0
  fi

  agent-browser close 2>/dev/null || true

  # Clean up snapshot directory
  if [[ -d "$VERIFY_SNAPSHOT_DIR" ]]; then
    rm -rf "$VERIFY_SNAPSHOT_DIR"
  fi
}

# Run full verification flow for an issue
# Returns 0 if verification passes (or is skipped), 1 if it fails
run_verification() {
  local url="${1:-}"
  local selectors="${2:-}"

  if [[ -z "$url" ]]; then
    echo "No verification URL provided, skipping verification" >&2
    return 0
  fi

  if ! verify_available; then
    echo "agent-browser not available, skipping verification" >&2
    return 0
  fi

  echo "=== Starting verification ===" >&2
  echo "URL: $url" >&2

  # Open and take baseline
  local baseline
  baseline=$(verify_start "$url" "baseline") || {
    echo "Failed to start verification, skipping" >&2
    verify_close
    return 0
  }

  # Check specific selectors if provided
  if [[ -n "$selectors" ]]; then
    IFS=',' read -ra selector_array <<< "$selectors"
    for selector in "${selector_array[@]}"; do
      selector=$(echo "$selector" | xargs) # trim whitespace
      if ! verify_check "$selector"; then
        echo "VERIFICATION FAILED: selector '$selector' not visible" >&2
        verify_close
        return 1
      fi
    done
  fi

  # Take final screenshot for the record
  verify_screenshot "${VERIFY_SNAPSHOT_DIR}/final.png" || true

  echo "=== Verification passed ===" >&2
  verify_close
  return 0
}
