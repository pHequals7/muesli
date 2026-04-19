#!/usr/bin/env bash
set -euo pipefail

# Builds and launches an isolated "MuesliDev" app for end-to-end testing.
#
# - Separate bundle ID (com.muesli.dev) — won't interfere with production Muesli
# - Separate data directory (~/Library/Application Support/MuesliDev/)
# - Fresh config and database each time (use --clean to wipe)
# - Signed with Developer ID (Accessibility permission persists across rebuilds)
# - Installs to /Applications/MuesliDev.app
#
# Usage:
#   ./scripts/dev-test.sh              # Build and launch
#   ./scripts/dev-test.sh --clean      # Wipe dev data and rebuild fresh (tests onboarding)
#   ./scripts/dev-test.sh --reset      # Reset onboarding only (keeps data)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_SUPPORT_DIR="$HOME/Library/Application Support/MuesliDev"
DEV_APP="/Applications/MuesliDev.app"
ONBOARDING_PROGRESS_FILE="$DEV_SUPPORT_DIR/onboarding-progress.json"

# Parse args
CLEAN=0
RESET=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --reset) RESET=1 ;;
  esac
done

# Kill any running dev instance
pkill -f "MuesliDev.app" 2>/dev/null || true
sleep 0.5

# Clean dev data if requested
if [[ "$CLEAN" -eq 1 ]]; then
  echo "Wiping dev data at: $DEV_SUPPORT_DIR"
  rm -rf "$DEV_SUPPORT_DIR"
fi

# Reset onboarding only if requested
if [[ "$RESET" -eq 1 ]] && [[ -f "$DEV_SUPPORT_DIR/config.json" ]]; then
  echo "Resetting onboarding flag..."
  python3 -c "
import json, os, pathlib
p = pathlib.Path('$DEV_SUPPORT_DIR/config.json')
c = json.loads(p.read_text())
c['has_completed_onboarding'] = False
mode = p.stat().st_mode & 0o777
p.write_text(json.dumps(c, indent=2) + '\n')
os.chmod(p, mode)
progress = pathlib.Path('$ONBOARDING_PROGRESS_FILE')
if progress.exists():
    progress.unlink()
    print('  Cleared transient onboarding progress')
print('  Onboarding reset (data preserved)')
"
fi

# Build with isolated identity
echo "Building MuesliDev (debug, signed)..."
MUESLI_APP_NAME=MuesliDev \
MUESLI_BUNDLE_ID=com.muesli.dev \
MUESLI_SUPPORT_DIR_NAME=MuesliDev \
MUESLI_DISPLAY_NAME=MuesliDev \
MUESLI_SPARKLE_FEED_URL="" \
"$ROOT/scripts/build_native_app.sh" debug

echo ""
echo "Launching MuesliDev..."
open "$DEV_APP"

echo ""
echo "=== Dev Test Ready ==="
echo "  App: $DEV_APP"
echo "  Data: $DEV_SUPPORT_DIR"
echo "  DB: $DEV_SUPPORT_DIR/muesli.db"
echo ""
echo "Tips:"
echo "  ./scripts/dev-test.sh --clean    # Fresh install (test onboarding)"
echo "  ./scripts/dev-test.sh --reset    # Re-run onboarding (keep data)"
echo "  pkill -f MuesliDev               # Kill dev app"
