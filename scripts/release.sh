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
# Usage: ./scripts/release.sh <version>
#   e.g.: ./scripts/release.sh 0.4.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_NAME="${MUESLI_NOTARY_PROFILE:-MuesliNotary}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)}"
APP_DIR="/Applications/Muesli.app"
OUTPUT_DIR="$ROOT/dist-release"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./scripts/release.sh <version>" >&2
  echo "  e.g.: ./scripts/release.sh 0.4.0" >&2
  exit 1
fi

echo "=== Muesli Release v${VERSION} ==="
echo ""

# --- Step 0: Update version in build script ---
echo "[0/6] Setting version to ${VERSION}..."
sed -i '' "s/CFBundleVersion<\/key>.*<string>[^<]*<\/string>/CFBundleVersion<\/key>\n  <string>${VERSION}<\/string>/" "$ROOT/scripts/build_native_app.sh"
sed -i '' "s/CFBundleShortVersionString<\/key>.*<string>[^<]*<\/string>/CFBundleShortVersionString<\/key>\n  <string>${VERSION}<\/string>/" "$ROOT/scripts/build_native_app.sh"

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

# --- Step 3: Notarize ---
echo "[3/7] Creating DMG..."
"$ROOT/scripts/create_dmg.sh" "$APP_DIR" "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/Muesli-${VERSION}.dmg"

# --- Step 4: Notarize DMG ---
echo "[4/7] Notarizing DMG with Apple (this may take several minutes)..."
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$PROFILE_NAME" \
  --wait 2>&1)
echo "$NOTARY_OUTPUT"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo "  Notarization accepted."
else
  echo "  Notarization FAILED. Fetching log..."
  SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE_NAME" 2>&1
  exit 1
fi

# --- Step 5: Staple DMG ---
echo "[5/7] Stapling notarization ticket to DMG..."
xcrun stapler staple "$DMG_PATH"
echo "  Stapled."

# Verify DMG and app bundle state
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH" 2>&1 | head -2
spctl -a -vv "$APP_DIR" 2>&1 | head -2
echo ""

# --- Step 6: Generate appcast ---
echo "[6/7] Generating appcast..."
GENERATE_APPCAST="$ROOT/native/MuesliNative/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ -x "$GENERATE_APPCAST" ]]; then
  "$GENERATE_APPCAST" "$OUTPUT_DIR" -o "$ROOT/site/appcast.xml"
  echo "  Appcast updated at site/appcast.xml"
else
  echo "  Warning: generate_appcast not found — update site/appcast.xml manually"
fi

# --- Step 7: GitHub Release ---
echo "[7/7] Creating GitHub release v${VERSION}..."
TAG="v${VERSION}"

git add site/appcast.xml
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
