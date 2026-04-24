#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for test-meeting-hook.sh." >&2
  exit 1
fi

OUTPUT_DIR="${MUESLI_HOOK_TEST_DIR:-$HOME/Desktop/MuesliHookTest}"
mkdir -p "$OUTPUT_DIR"

PAYLOAD_FILE="$(mktemp "$OUTPUT_DIR/payload.XXXXXX.json")"
cat > "$PAYLOAD_FILE"

PARSED_LINE="$(
  python3 - "$PAYLOAD_FILE" <<'PY'
import json
import sys

payload_path = sys.argv[1]
with open(payload_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

print(f"{payload.get('id', '')}\t{payload.get('completedAt', '')}")
PY
)"

IFS=$'\t' read -r MEETING_ID COMPLETED_AT <<< "$PARSED_LINE"

if [[ -z "$MEETING_ID" ]]; then
  echo "Hook payload did not include a meeting id." >&2
  exit 1
fi

if [[ -x "/Applications/MuesliDev.app/Contents/MacOS/muesli-cli" ]]; then
  CLI_BIN="/Applications/MuesliDev.app/Contents/MacOS/muesli-cli"
elif [[ -x "/Applications/Muesli.app/Contents/MacOS/muesli-cli" ]]; then
  CLI_BIN="/Applications/Muesli.app/Contents/MacOS/muesli-cli"
elif command -v muesli-cli >/dev/null 2>&1; then
  CLI_BIN="$(command -v muesli-cli)"
else
  echo "Could not find muesli-cli." >&2
  exit 1
fi

MEETING_JSON="$OUTPUT_DIR/meeting-$MEETING_ID.json"
EVENT_JSON="$OUTPUT_DIR/last-event.json"
SUMMARY_TXT="$OUTPUT_DIR/last-run.txt"

cp "$PAYLOAD_FILE" "$EVENT_JSON"
"$CLI_BIN" meetings get "$MEETING_ID" > "$MEETING_JSON"

cat > "$SUMMARY_TXT" <<EOF
Meeting hook test ran successfully.

Meeting ID: $MEETING_ID
Completed At: $COMPLETED_AT
CLI: $CLI_BIN
Payload: $EVENT_JSON
Meeting JSON: $MEETING_JSON
Ran At: $(date)
EOF

rm -f "$PAYLOAD_FILE"
