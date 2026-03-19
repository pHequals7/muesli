#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/native/MuesliNative"
DIST_DIR="$ROOT/dist-native"
INSTALL_DIR="${MUESLI_INSTALL_DIR:-/Applications}"
BUILD_CONFIG="${1:-release}"
APP_BINARY="MuesliNativeApp"
CLI_BINARY="muesli-cli"
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
SKIP_SIGN="${MUESLI_SKIP_SIGN:-0}"

mkdir -p "$DIST_DIR"

set +e
swift build --package-path "$PACKAGE_DIR" -c "$BUILD_CONFIG" --product "$APP_BINARY"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "Swift build failed." >&2
  exit $status
fi

set +e
swift build --package-path "$PACKAGE_DIR" -c "$BUILD_CONFIG" --product "$CLI_BINARY"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "Swift CLI build failed." >&2
  exit $status
fi

BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$BUILD_CONFIG" --show-bin-path)"
APP_BIN="$BIN_DIR/$APP_BINARY"
CLI_BIN="$BIN_DIR/$CLI_BINARY"

rm -rf "$STAGED_APP_DIR"
mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"

cp "$APP_BIN" "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
cp "$CLI_BIN" "$STAGED_APP_DIR/Contents/MacOS/$CLI_BINARY"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/$CLI_BINARY"

# Bundle Sparkle framework (rpath is @loader_path, so it goes next to the binary)
SPARKLE_FW="$BIN_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  ditto "$SPARKLE_FW" "$STAGED_APP_DIR/Contents/MacOS/Sparkle.framework"
fi

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
  <string>0.5.5</string>
  <key>CFBundleShortVersionString</key>
  <string>0.5.5</string>
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
  <key>SUFeedURL</key>
  <string>https://pHequals7.github.io/muesli/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>${MUESLI_SPARKLE_EDKEY:-ok9CQBJ3f0MJ2GXuGBubc6VyeWyb5exmqP2b9DceqH4=}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
</dict>
</plist>
PLIST

# Replace existing app (no prompt — that's what this script is for)
if [[ -d "$APP_DIR" ]]; then
  echo "Replacing $APP_DIR"
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_DIR"
ditto "$STAGED_APP_DIR" "$APP_DIR"

if [[ "$SKIP_SIGN" != "1" ]]; then
  if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    echo "Signing identity not found: $SIGN_IDENTITY" >&2
    exit 1
  fi

  # Sign all nested binaries inside Sparkle framework (required for notarization)
  if [[ -d "$APP_DIR/Contents/MacOS/Sparkle.framework" ]]; then
    # Deep-sign every executable inside Sparkle (Updater.app, Autoupdate, XPC services)
    find "$APP_DIR/Contents/MacOS/Sparkle.framework" -type f -perm +111 | while read -r binary; do
      # Skip non-Mach-O files (e.g., shell scripts, plists)
      if file "$binary" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp \
          --sign "$SIGN_IDENTITY" "$binary"
      fi
    done
    # Sign the XPC bundles
    find "$APP_DIR/Contents/MacOS/Sparkle.framework" -name "*.xpc" -type d | while read -r xpc; do
      codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$xpc"
    done
    # Sign the Updater.app bundle
    find "$APP_DIR/Contents/MacOS/Sparkle.framework" -name "*.app" -type d | while read -r app; do
      codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$app"
    done
    # Sign the framework bundle itself
    codesign --force --options runtime --timestamp \
      --sign "$SIGN_IDENTITY" \
      "$APP_DIR/Contents/MacOS/Sparkle.framework"
  fi

  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR/Contents/MacOS/muesli-cli"

  # Sign the app bundle with hardened runtime, secure timestamp, and entitlements
  ENTITLEMENTS="$ROOT/scripts/Muesli.entitlements"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"

  # Deep-verify entire bundle — fail fast if any component has an invalid signature
  echo "Verifying deep signature..."
  if ! codesign --verify --deep --strict "$APP_DIR" 2>&1; then
    echo "ERROR: Deep signature verification failed" >&2
    exit 1
  fi
  echo "  Deep signature valid."
else
  echo "Skipping codesign because MUESLI_SKIP_SIGN=1"
fi

rm -rf "$STAGED_APP_DIR"

echo "Installed $APP_DIR ($(du -sh "$APP_DIR" | cut -f1))"
