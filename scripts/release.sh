#!/usr/bin/env bash
set -euo pipefail

# End-to-end release pipeline:
#   1. Build and sign the app (hardened runtime + entitlements)
#   2. Create a signed DMG
#   3. Notarize the DMG with Apple
#   4. Staple the ticket
#   5. Create GitHub release and upload DMG
#
# Prerequisites:
#   - Developer ID cert in keychain
#   - Notary profile stored: xcrun notarytool store-credentials MuesliNotary
#   - gh CLI authenticated
#
# Usage: ./scripts/release.sh [version]
#   e.g.: ./scripts/release.sh 0.5.0
#   If no version given, auto-increments patch from latest GitHub release.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_NAME="${MUESLI_NOTARY_PROFILE:-MuesliNotary}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)}"
APP_DIR="/Applications/Muesli.app"
OUTPUT_DIR="$ROOT/dist-release"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  # Auto-increment: get latest release tag, bump patch version
  LATEST_TAG=$(gh release list --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
  if [[ -n "$LATEST_TAG" ]]; then
    LATEST_VERSION="${LATEST_TAG#v}"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_VERSION"
    # Strip any pre-release suffix from patch (e.g., "0-beta.1" → "0")
    PATCH="${PATCH%%[-+]*}"
    PATCH=$((PATCH + 1))
    VERSION="${MAJOR}.${MINOR}.${PATCH}"
    echo "Auto-incremented version: ${LATEST_TAG} → v${VERSION}"
  else
    VERSION="0.1.0"
    echo "No previous releases found, starting at v${VERSION}"
  fi
  echo ""
  read -p "Release as v${VERSION}? [Y/n] " confirm
  if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
    read -p "Enter version: " VERSION
  fi
fi

echo "=== Muesli Release v${VERSION} ==="
echo ""

# --- Step 0: Update version in build script ---
echo "[0/6] Setting version to ${VERSION}..."
sed -i '' "/CFBundleVersion<\/key>/{n;s/<string>[^<]*<\/string>/<string>${VERSION}<\/string>/;}" "$ROOT/scripts/build_native_app.sh"
sed -i '' "/CFBundleShortVersionString<\/key>/{n;s/<string>[^<]*<\/string>/<string>${VERSION}<\/string>/;}" "$ROOT/scripts/build_native_app.sh"

# --- Step 1: Run tests ---
echo "[1/6] Running tests..."
swift test --package-path "$ROOT/native/MuesliNative"
echo "  Tests passed."

# --- Step 2: Build and sign ---
echo "[2/6] Building and signing..."
echo "y" | "$ROOT/scripts/build_native_app.sh" > /dev/null 2>&1
echo "  Installed to $APP_DIR"

# Verify signature
FLAGS=$(codesign -dvvv "$APP_DIR" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)')
echo "  Signature: $FLAGS"

# --- Step 3: Notarize app bundle ---
echo "[3/8] Notarizing app bundle with Apple (this may take several minutes)..."
APP_ZIP="$OUTPUT_DIR/Muesli-app-${VERSION}.zip"
ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"
NOTARY_OUTPUT=$(xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$PROFILE_NAME" \
  --wait 2>&1)
echo "$NOTARY_OUTPUT"
rm -f "$APP_ZIP"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo "  App notarization accepted."
else
  echo "  App notarization FAILED. Fetching log..."
  SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE_NAME" 2>&1
  exit 1
fi

# --- Step 4: Staple app bundle ---
echo "[4/8] Stapling notarization ticket to app bundle..."
xcrun stapler staple "$APP_DIR"
echo "  App stapled."

# --- Step 5: Create DMG from stapled app ---
echo "[5/8] Creating DMG from stapled app..."
"$ROOT/scripts/create_dmg.sh" "$APP_DIR" "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/Muesli-${VERSION}.dmg"

# --- Step 6: Notarize DMG ---
echo "[6/8] Notarizing DMG with Apple..."
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$PROFILE_NAME" \
  --wait 2>&1)
echo "$NOTARY_OUTPUT"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo "  DMG notarization accepted."
else
  echo "  DMG notarization FAILED. Fetching log..."
  SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE_NAME" 2>&1
  exit 1
fi

# --- Step 7: Staple DMG ---
echo "[7/8] Stapling notarization ticket to DMG..."
xcrun stapler staple "$DMG_PATH"
echo "  DMG stapled."

# Verify by mounting DMG and checking the app INSIDE it (simulates user experience)
echo "  Verifying app inside DMG..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse 2>&1 | grep "/Volumes" | awk -F'\t' '{print $NF}')
if [[ -z "$MOUNT_POINT" ]]; then
  echo "  ERROR: Could not mount DMG for verification"
  exit 1
fi

SPCTL_RESULT=$(spctl -a -vv "$MOUNT_POINT/Muesli.app" 2>&1)
echo "  $SPCTL_RESULT"

STAPLE_RESULT=$(xcrun stapler validate "$MOUNT_POINT/Muesli.app" 2>&1)
echo "  $STAPLE_RESULT"

hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null

if ! echo "$SPCTL_RESULT" | grep -q "accepted"; then
  echo ""
  echo "  RELEASE ABORTED: App inside DMG was REJECTED by Gatekeeper."
  echo "  The app bundle was not properly stapled before DMG creation."
  exit 1
fi

if ! echo "$STAPLE_RESULT" | grep -q "worked"; then
  echo ""
  echo "  RELEASE ABORTED: App inside DMG does not have a valid staple."
  exit 1
fi

echo "  Verified: app inside DMG is accepted by Gatekeeper and stapled."
echo ""

# --- Step 8: Generate appcast ---
echo "[8/9] Generating appcast..."
GENERATE_APPCAST="$ROOT/native/MuesliNative/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ -x "$GENERATE_APPCAST" ]]; then
  "$GENERATE_APPCAST" "$OUTPUT_DIR" -o "$ROOT/docs/appcast.xml"
  echo "  Appcast updated at docs/appcast.xml"
else
  echo "  Warning: generate_appcast not found — update docs/appcast.xml manually"
fi

# --- Step 9: GitHub Release ---
echo "[9/9] Creating GitHub release v${VERSION}..."
TAG="v${VERSION}"

git add docs/appcast.xml
git commit -m "Update appcast for v${VERSION}" --allow-empty
git tag -a "$TAG" -m "Release ${VERSION}"
git push origin main "$TAG"

gh release create "$TAG" \
  --title "Muesli ${VERSION}" \
  --notes "$(cat <<EOF
## Muesli ${VERSION}

Native macOS app — dictation + meeting transcription on Apple Silicon.

### Install
1. Download \`Muesli-${VERSION}.dmg\`
2. Open the DMG and drag Muesli to Applications
3. Launch from Applications

Signed, notarized, and stapled by Apple.
EOF
)" \
  "$DMG_PATH"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo ""
echo "=== Release complete ==="
echo "  Version: ${VERSION}"
echo "  DMG: $DMG_PATH"
echo "  Release: $RELEASE_URL"
