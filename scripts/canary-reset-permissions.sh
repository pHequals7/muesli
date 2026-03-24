#!/usr/bin/env bash
set -euo pipefail

# Reset macOS TCC permissions for the Canary app bundle without touching its data.
#
# Usage:
#   ./scripts/canary-reset-permissions.sh
#   ./scripts/canary-reset-permissions.sh --bundle-id com.muesli.canary
#   ./scripts/canary-reset-permissions.sh --dry-run

BUNDLE_ID="${MUESLI_CANARY_BUNDLE_ID:-com.muesli.canary}"
APP_PROCESS_NAME="${MUESLI_CANARY_PROCESS_NAME:-MuesliCanary}"
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
Reset macOS privacy permissions for the Canary app bundle.

Options:
  --bundle-id ID      Override the bundle identifier to reset.
  --process-name NAME Override the process name checked before reset.
  --dry-run           Print the reset command without executing it.
  --force             Continue even if the app appears to be running.
  --help              Show this help text.
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run_or_echo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id)
      [[ $# -ge 2 ]] || die "--bundle-id requires a value."
      BUNDLE_ID="$2"
      shift 2
      ;;
    --process-name)
      [[ $# -ge 2 ]] || die "--process-name requires a value."
      APP_PROCESS_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

command -v tccutil >/dev/null 2>&1 || die "tccutil is required but was not found."

if [[ "$FORCE" -ne 1 ]]; then
  if pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1; then
    die "$APP_PROCESS_NAME appears to be running. Quit it first or rerun with --force."
  fi
fi

log "Resetting macOS privacy permissions."
log "  Bundle ID: $BUNDLE_ID"
log "  Scope:     All TCC permissions for this bundle"

run_or_echo tccutil reset All "$BUNDLE_ID"

log ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry run complete. No permissions were changed."
else
  log "Reset complete."
  log "Next manual steps:"
  log "  1. Launch MuesliCanary."
  log "  2. Re-grant Microphone, Screen Recording, Accessibility, Calendar, and Input Monitoring if prompted."
  log "  3. If macOS opens System Settings, finish the toggle there before retrying the feature."
fi
