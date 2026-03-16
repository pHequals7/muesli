#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/native/MuesliNative"
DIST_DIR="$ROOT/dist-native"
INSTALL_DIR="${MUESLI_INSTALL_DIR:-/Applications}"
BUILD_CONFIG="${1:-release}"
APP_BINARY="MuesliNativeApp"
APP_NAME="${MUESLI_APP_NAME:-Muesli}"
APP_DISPLAY_NAME="${MUESLI_DISPLAY_NAME:-$APP_NAME}"
APP_BUNDLE_NAME="${MUESLI_APP_BUNDLE_NAME:-$APP_NAME.app}"
APP_EXECUTABLE_NAME="${MUESLI_EXECUTABLE_NAME:-Muesli}"
APP_SUPPORT_DIR_NAME="${MUESLI_SUPPORT_DIR_NAME:-$APP_DISPLAY_NAME}"
BUNDLE_ID="${MUESLI_BUNDLE_ID:-com.muesli.app}"
STAGED_APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME"
APP_DIR="$INSTALL_DIR/$APP_BUNDLE_NAME"
DEFAULT_SIGN_IDENTITY="Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"

mkdir -p "$DIST_DIR"

set +e
swift build --package-path "$PACKAGE_DIR" -c "$BUILD_CONFIG" --product "$APP_BINARY"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "Swift build failed." >&2
  exit $status
fi

BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$BUILD_CONFIG" --show-bin-path)"
APP_BIN="$BIN_DIR/$APP_BINARY"

rm -rf "$STAGED_APP_DIR"
mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"

cp "$APP_BIN" "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"

# Bundle assets
cp "$ROOT/assets/menu_m_template.png" "$STAGED_APP_DIR/Contents/Resources/menu_m_template.png"
cp "$ROOT/assets/muesli.icns" "$STAGED_APP_DIR/Contents/Resources/muesli.icns"
if [[ -d "$ROOT/assets/fonts" ]]; then
  ditto "$ROOT/assets/fonts" "$STAGED_APP_DIR/Contents/Resources/fonts"
fi

cat > "$STAGED_APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>0.3.0</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.0</string>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>muesli.icns</string>
  <key>MuesliSupportDirectoryName</key>
  <string>$APP_SUPPORT_DIR_NAME</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>$APP_DISPLAY_NAME records microphone audio for dictation.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>$APP_DISPLAY_NAME monitors keyboard events to trigger push-to-talk dictation.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>$APP_DISPLAY_NAME captures system audio during meeting recordings.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>$APP_DISPLAY_NAME reads calendar events to help with meeting recordings.</string>
</dict>
</plist>
PLIST

# Confirm before overwriting existing app
if [[ -d "$APP_DIR" ]]; then
  echo "Warning: $APP_DIR already exists and will be replaced."
  read -p "Continue? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted. Staged app at: $STAGED_APP_DIR"
    exit 0
  fi
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_DIR"
ditto "$STAGED_APP_DIR" "$APP_DIR"

if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  echo "Signing identity not found: $SIGN_IDENTITY" >&2
  exit 1
fi

# Sign with hardened runtime, secure timestamp, and entitlements for notarization
ENTITLEMENTS="$ROOT/scripts/Muesli.entitlements"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP_DIR"

rm -rf "$STAGED_APP_DIR"

echo "Installed $APP_DIR ($(du -sh "$APP_DIR" | cut -f1))"
