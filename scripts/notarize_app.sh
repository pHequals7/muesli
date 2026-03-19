#!/usr/bin/env bash
set -euo pipefail

# Troubleshooting helper only.
# Official releases must go through scripts/release.sh so GitHub Releases remains
# the single binary source of truth and the appcast stays in sync with releases.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-/Applications/Muesli.app}"
PROFILE_NAME="${MUESLI_NOTARY_PROFILE:-MuesliNotary}"
ARTIFACT_DIR="${ROOT}/dist-notary"
ZIP_PATH="${ARTIFACT_DIR}/$(basename "${APP_PATH%.app}")-notarize.zip"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "Developer ID Application"; then
  echo "No Developer ID Application signing identity found in keychain." >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
rm -f "$ZIP_PATH"

echo "Creating notarization archive..."
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Submitting archive to Apple notarization service with profile '$PROFILE_NAME'..."
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$PROFILE_NAME" \
  --wait

echo "Stapling notarization ticket to app..."
xcrun stapler staple "$APP_PATH"

echo "Validating stapled ticket..."
xcrun stapler validate "$APP_PATH"

echo "Verifying Gatekeeper acceptance..."
spctl -a -vv "$APP_PATH"

echo "Notarization complete for $APP_PATH"
