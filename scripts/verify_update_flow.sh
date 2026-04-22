#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST="$ROOT/docs/appcast.xml"
VERSION=""
DMG_PATH=""
SKIP_DMG=0
REQUIRE_NOTARIZED=0

usage() {
  cat >&2 <<'USAGE'
usage: scripts/verify_update_flow.sh [options]

Validates the Sparkle appcast and, when a DMG is available, the update artifact
Sparkle will install.

Options:
  --version <version>       Require the latest appcast item to match this version.
  --appcast <path>          Appcast XML path. Defaults to docs/appcast.xml.
  --dmg <path>              DMG path. Defaults to dist-release/Muesli-<version>.dmg.
  --skip-dmg                Only validate appcast metadata. Suitable for CI.
  --require-notarized       Also require Gatekeeper/stapler checks for DMG and app.
  -h, --help                Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:?missing value for --version}"
      shift 2
      ;;
    --appcast)
      APPCAST="${2:?missing value for --appcast}"
      shift 2
      ;;
    --dmg)
      DMG_PATH="${2:?missing value for --dmg}"
      shift 2
      ;;
    --skip-dmg)
      SKIP_DMG=1
      shift
      ;;
    --require-notarized)
      REQUIRE_NOTARIZED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "$APPCAST" ]]; then
  echo "ERROR: appcast not found: $APPCAST" >&2
  exit 1
fi

APPCAST_METADATA="$(python3 - "$APPCAST" "$VERSION" <<'PY'
import base64
import re
import shlex
import sys
import xml.etree.ElementTree as ET

appcast_path = sys.argv[1]
expected_version = sys.argv[2]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"

try:
    tree = ET.parse(appcast_path)
except ET.ParseError as exc:
    raise SystemExit(f"ERROR: appcast XML is not well-formed: {exc}")

root = tree.getroot()
channel = root.find("channel")
if channel is None:
    raise SystemExit("ERROR: appcast is missing channel")

items = channel.findall("item")
if not items:
    raise SystemExit("ERROR: appcast has no update items")

latest = items[0]
version = latest.findtext(f"{{{sparkle_ns}}}version")
short_version = latest.findtext(f"{{{sparkle_ns}}}shortVersionString")
enclosure = latest.find("enclosure")

if not version:
    raise SystemExit("ERROR: latest appcast item is missing sparkle:version")
if not short_version:
    raise SystemExit("ERROR: latest appcast item is missing sparkle:shortVersionString")
if version != short_version:
    raise SystemExit(f"ERROR: latest appcast version mismatch: {version} != {short_version}")
if expected_version and version != expected_version:
    raise SystemExit(f"ERROR: latest appcast version is {version}, expected {expected_version}")
if enclosure is None:
    raise SystemExit("ERROR: latest appcast item is missing enclosure")

url = enclosure.attrib.get("url", "")
length = enclosure.attrib.get("length", "")
signature = enclosure.attrib.get(f"{{{sparkle_ns}}}edSignature", "")

expected_url = f"https://github.com/pHequals7/muesli/releases/download/v{version}/Muesli-{version}.dmg"
if url != expected_url:
    raise SystemExit(f"ERROR: latest appcast URL is {url!r}, expected {expected_url!r}")

try:
    length_int = int(length)
except ValueError:
    raise SystemExit(f"ERROR: latest appcast enclosure length is not an integer: {length!r}")
if length_int <= 0:
    raise SystemExit("ERROR: latest appcast enclosure length must be positive")

try:
    decoded_signature = base64.b64decode(signature, validate=True)
except Exception as exc:
    raise SystemExit(f"ERROR: latest appcast edSignature is not valid base64: {exc}")
if len(decoded_signature) != 64:
    raise SystemExit(f"ERROR: latest appcast edSignature is {len(decoded_signature)} bytes, expected 64")

delta_attr = f"{{{sparkle_ns}}}deltaFrom"
delta_enclosures = [
    node.attrib.get("url", "(missing url)")
    for node in root.iter("enclosure")
    if delta_attr in node.attrib
]
if delta_enclosures:
    raise SystemExit(
        "ERROR: appcast contains delta enclosures, but release deltas are not hosted: "
        + ", ".join(delta_enclosures)
    )

if not re.fullmatch(r"[0-9][0-9A-Za-z.\-]*", version):
    raise SystemExit(f"ERROR: unexpected version format: {version!r}")

for key, value in {
    "APPCAST_VERSION": version,
    "APPCAST_URL": url,
    "APPCAST_LENGTH": str(length_int),
    "APPCAST_SIGNATURE": signature,
}.items():
    print(f"{key}={shlex.quote(value)}")
PY
)"
eval "$APPCAST_METADATA"

echo "Appcast OK: v${APPCAST_VERSION}"

if [[ "$SKIP_DMG" == "1" ]]; then
  echo "DMG checks skipped."
  exit 0
fi

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$ROOT/dist-release/Muesli-${APPCAST_VERSION}.dmg"
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: DMG not found: $DMG_PATH" >&2
  echo "       Use --skip-dmg for CI metadata-only validation." >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: DMG validation requires macOS." >&2
  exit 1
fi

file_size() {
  stat -f '%z' "$1"
}

DMG_LENGTH="$(file_size "$DMG_PATH")"
if [[ "$DMG_LENGTH" != "$APPCAST_LENGTH" ]]; then
  echo "ERROR: DMG size $DMG_LENGTH does not match appcast length $APPCAST_LENGTH" >&2
  exit 1
fi
echo "DMG length OK: $DMG_LENGTH bytes"

MOUNT_POINT=""
SWIFT_VERIFY_FILE=""
cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  if [[ -n "$SWIFT_VERIFY_FILE" && -f "$SWIFT_VERIFY_FILE" ]]; then
    rm -f "$SWIFT_VERIFY_FILE"
  fi
}
trap cleanup EXIT

MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly 2>&1 | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
if [[ -z "$MOUNT_POINT" ]]; then
  echo "ERROR: Could not mount DMG: $DMG_PATH" >&2
  exit 1
fi

APP_PATH="$MOUNT_POINT/Muesli.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: mounted DMG does not contain Muesli.app" >&2
  exit 1
fi

BUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")"
PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"

if [[ "$BUNDLE_SHORT_VERSION" != "$APPCAST_VERSION" || "$BUNDLE_VERSION" != "$APPCAST_VERSION" ]]; then
  echo "ERROR: app bundle version ${BUNDLE_SHORT_VERSION}/${BUNDLE_VERSION} does not match appcast ${APPCAST_VERSION}" >&2
  exit 1
fi

if [[ "$FEED_URL" != "https://pHequals7.github.io/muesli/appcast.xml" ]]; then
  echo "ERROR: app bundle SUFeedURL is $FEED_URL" >&2
  exit 1
fi

if [[ -z "$PUBLIC_ED_KEY" ]]; then
  echo "ERROR: app bundle is missing SUPublicEDKey" >&2
  exit 1
fi
echo "Bundle metadata OK."

SWIFT_VERIFY_FILE="$(mktemp -t muesli-ed25519-verify.XXXXXX.swift)"
cat > "$SWIFT_VERIFY_FILE" <<'SWIFT'
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fatalError("usage: verifier <public-key-base64> <signature-base64> <file>")
}

guard let publicKeyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    fatalError("invalid base64 input")
}

let fileURL = URL(fileURLWithPath: CommandLine.arguments[3])
let payload = try Data(contentsOf: fileURL, options: .mappedIfSafe)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

if !publicKey.isValidSignature(signature, for: payload) {
    fputs("ERROR: appcast edSignature does not verify against app SUPublicEDKey\n", stderr)
    exit(1)
}
SWIFT

swift "$SWIFT_VERIFY_FILE" "$PUBLIC_ED_KEY" "$APPCAST_SIGNATURE" "$DMG_PATH"
echo "Sparkle EdDSA signature OK."

if ! APP_CODESIGN_RESULT="$(codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1)"; then
  echo "$APP_CODESIGN_RESULT" >&2
  exit 1
fi
echo "App code signature OK."

DMG_FLAGS="$(codesign -dvvv "$DMG_PATH" 2>&1 || true)"
if ! echo "$DMG_FLAGS" | grep -q "runtime"; then
  echo "ERROR: DMG is missing hardened runtime flag." >&2
  exit 1
fi
echo "DMG hardened runtime OK."

if [[ "$REQUIRE_NOTARIZED" == "1" ]]; then
  APP_SPCTL_RESULT="$(spctl -a -vv "$APP_PATH" 2>&1)"
  echo "$APP_SPCTL_RESULT"
  if ! echo "$APP_SPCTL_RESULT" | grep -q "accepted"; then
    echo "ERROR: app inside DMG was rejected by Gatekeeper." >&2
    exit 1
  fi

  APP_STAPLE_RESULT="$(xcrun stapler validate "$APP_PATH" 2>&1)"
  echo "$APP_STAPLE_RESULT"
  if ! echo "$APP_STAPLE_RESULT" | grep -q "worked"; then
    echo "ERROR: app inside DMG does not have a valid staple." >&2
    exit 1
  fi

  DMG_SPCTL_RESULT="$(spctl -a -vv -t open --context context:primary-signature "$DMG_PATH" 2>&1)"
  echo "$DMG_SPCTL_RESULT"
  if ! echo "$DMG_SPCTL_RESULT" | grep -q "accepted"; then
    echo "ERROR: DMG was rejected by Gatekeeper." >&2
    exit 1
  fi

  DMG_STAPLE_RESULT="$(xcrun stapler validate "$DMG_PATH" 2>&1)"
  echo "$DMG_STAPLE_RESULT"
  if ! echo "$DMG_STAPLE_RESULT" | grep -q "worked"; then
    echo "ERROR: DMG does not have a valid staple." >&2
    exit 1
  fi
  echo "Notarization/staple checks OK."
fi

echo "Update flow verification passed for v${APPCAST_VERSION}."
