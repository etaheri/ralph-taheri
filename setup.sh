#!/usr/bin/env bash
# setup.sh — Check and install dependencies for ralph-taheri
#
# Usage:
#   ./setup.sh              # Check all dependencies
#   ./setup.sh --install    # Attempt to install missing dependencies

set -euo pipefail

INSTALL=false
ERRORS=0
WARNINGS=0

if [[ "${1:-}" == "--install" ]]; then
  INSTALL=true
fi

echo "=== ralph-taheri dependency check ==="
echo ""

# Helper to check a command
check_cmd() {
  local cmd="$1"
  local required="$2"
  local description="$3"
  local install_cmd="${4:-}"

  if command -v "$cmd" &>/dev/null; then
    local version
    version=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
    echo "  [OK] $cmd — $version"
    return 0
  else
    if [[ "$required" == "required" ]]; then
      echo "  [MISSING] $cmd — $description (REQUIRED)"
      ERRORS=$((ERRORS + 1))
    else
      echo "  [MISSING] $cmd — $description (optional)"
      WARNINGS=$((WARNINGS + 1))
    fi

    if [[ "$INSTALL" == "true" && -n "$install_cmd" ]]; then
      echo "    Installing $cmd..."
      if eval "$install_cmd" 2>/dev/null; then
        echo "    [OK] $cmd installed successfully"
        return 0
      else
        echo "    [FAIL] Could not install $cmd automatically"
        return 1
      fi
    fi

    return 1
  fi
}

echo "Core dependencies:"
check_cmd "jq" "required" "JSON processor" "brew install jq || sudo apt-get install -y jq"
check_cmd "claude" "required" "Claude CLI" ""
echo ""

echo "GitHub backend:"
check_cmd "gh" "optional" "GitHub CLI" "brew install gh || sudo apt-get install -y gh"

# Check gh auth status
if command -v gh &>/dev/null; then
  if gh auth status &>/dev/null; then
    echo "  [OK] gh — authenticated"
  else
    echo "  [WARNING] gh — not authenticated (run: gh auth login)"
    WARNINGS=$((WARNINGS + 1))
  fi
fi
echo ""

echo "Linear backend:"
if [[ -n "${LINEAR_API_KEY:-}" ]]; then
  echo "  [OK] LINEAR_API_KEY — set"
else
  echo "  [INFO] LINEAR_API_KEY — not set (required only for Linear backend)"
fi

if [[ -n "${LINEAR_TEAM_KEY:-}" ]]; then
  echo "  [OK] LINEAR_TEAM_KEY — set"
else
  echo "  [INFO] LINEAR_TEAM_KEY — not set (required only for Linear backend)"
fi

check_cmd "curl" "optional" "HTTP client" ""
echo ""

echo "Verification (optional):"
check_cmd "agent-browser" "optional" "Vercel agent-browser for UI verification" "npm install -g @anthropic-ai/agent-browser 2>/dev/null || npm install -g agent-browser 2>/dev/null"
echo ""

echo "Version control:"
check_cmd "git" "required" "Git" ""
echo ""

# --- Summary ---
echo "=== Summary ==="
if [[ $ERRORS -gt 0 ]]; then
  echo "  $ERRORS required dependencies missing"
  echo "  Run with --install to attempt automatic installation"
  echo "  Or install manually and re-run this script"
  exit 1
elif [[ $WARNINGS -gt 0 ]]; then
  echo "  All required dependencies present"
  echo "  $WARNINGS optional dependencies missing (some features may not work)"
  exit 0
else
  echo "  All dependencies present. Ready to go!"
  exit 0
fi
