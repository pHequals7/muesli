#!/usr/bin/env bash
set -euo pipefail

# Safely seed MuesliDev from production data without touching production files.
#
# Default behavior:
# - Reads from ~/Library/Application Support/Muesli
# - Writes to ~/Library/Application Support/MuesliDev
# - Stages the current dev support dir first so unrelated dev-only files are preserved
# - Overlays production muesli.db / sidecars and config.json into the staged temp directory
# - Validates the staged files
# - Backs up the current dev support dir
# - Swaps the staged directory into place
#
# Usage:
#   ./scripts/dev-seed-from-prod.sh
#   ./scripts/dev-seed-from-prod.sh --db-only
#   ./scripts/dev-seed-from-prod.sh --prod-dir "/path/to/Muesli" --dev-dir "/path/to/MuesliDev"
#   ./scripts/dev-seed-from-prod.sh --dry-run

PROD_SUPPORT_DIR="${MUESLI_PROD_SUPPORT_DIR:-$HOME/Library/Application Support/Muesli}"
DEV_SUPPORT_DIR="${MUESLI_DEV_SUPPORT_DIR:-$HOME/Library/Application Support/MuesliDev}"
COPY_CONFIG=1
DRY_RUN=0
FORCE=0
SWAPPED_OLD_DEV=0
SEEDED_DEV=0

usage() {
  cat <<'EOF'
Safely seed MuesliDev from production data.

Options:
  --prod-dir PATH   Override the production support directory.
  --dev-dir PATH    Override the dev support directory.
  --db-only         Copy only muesli.db, not config.json.
  --dry-run         Print the planned actions without modifying files.
  --force           Continue even if Muesli or MuesliDev appears to be running.
  --help            Show this help text.
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

require_safe_support_dir() {
  local label="$1"
  local path="$2"
  local home_support
  home_support="$(resolve_path "$HOME/Library/Application Support")"

  [[ -n "$path" ]] || die "$label path resolved to empty string."
  [[ "$path" != "/" ]] || die "$label path cannot be /."
  [[ "$path" == "$home_support"/* ]] || die "$label path must live under $home_support."
}

running_processes() {
  ps ax -o pid=,comm= | awk '$2 == "Muesli" || $2 == "MuesliDev" { print }'
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

validate_sqlite_db() {
  local db_path="$1"
  python3 - "$db_path" <<'PY'
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(path)
try:
    result = conn.execute("PRAGMA quick_check").fetchone()
finally:
    conn.close()

if not result or result[0].lower() != "ok":
    raise SystemExit(f"SQLite quick_check failed for {path}: {result!r}")
PY
}

validate_json_file() {
  local json_path="$1"
  python3 - "$json_path" <<'PY'
import json
import sys
from pathlib import Path

json.loads(Path(sys.argv[1]).read_text())
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod-dir)
      [[ $# -ge 2 ]] || die "--prod-dir requires a path."
      PROD_SUPPORT_DIR="$2"
      shift 2
      ;;
    --dev-dir)
      [[ $# -ge 2 ]] || die "--dev-dir requires a path."
      DEV_SUPPORT_DIR="$2"
      shift 2
      ;;
    --db-only)
      COPY_CONFIG=0
      shift
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

PROD_SUPPORT_DIR="$(resolve_path "$PROD_SUPPORT_DIR")"
DEV_SUPPORT_DIR="$(resolve_path "$DEV_SUPPORT_DIR")"

require_safe_support_dir "Production support directory" "$PROD_SUPPORT_DIR"
require_safe_support_dir "Dev support directory" "$DEV_SUPPORT_DIR"
[[ "$PROD_SUPPORT_DIR" != "$DEV_SUPPORT_DIR" ]] || die "Production and dev support directories must differ."

PROD_DB="$PROD_SUPPORT_DIR/muesli.db"
PROD_DB_SHM="$PROD_SUPPORT_DIR/muesli.db-shm"
PROD_DB_WAL="$PROD_SUPPORT_DIR/muesli.db-wal"
PROD_CONFIG="$PROD_SUPPORT_DIR/config.json"
DEV_PARENT="$(dirname "$DEV_SUPPORT_DIR")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${DEV_SUPPORT_DIR}.backup.${TIMESTAMP}"
ROLLOVER_DIR="${DEV_SUPPORT_DIR}.swap.${TIMESTAMP}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  STAGE_DIR="${DEV_PARENT}/muesli-dev-seed-stage.${TIMESTAMP}"
else
  mkdir -p "$DEV_PARENT"
  STAGE_DIR="$(mktemp -d "${DEV_PARENT}/muesli-dev-seed-stage.XXXXXX")"
fi

cleanup() {
  if [[ -d "$STAGE_DIR" ]]; then
    rm -rf "$STAGE_DIR"
  fi
  if [[ "$SWAPPED_OLD_DEV" -eq 1 && "$SEEDED_DEV" -eq 0 && -d "$ROLLOVER_DIR" && ! -e "$DEV_SUPPORT_DIR" ]]; then
    mv "$ROLLOVER_DIR" "$DEV_SUPPORT_DIR"
  fi
}

trap cleanup EXIT

if [[ "$FORCE" -ne 1 ]]; then
  if running="$(running_processes)" && [[ -n "$running" ]]; then
    printf 'Refusing to seed while Muesli or MuesliDev is running:\n%s\n' "$running" >&2
    die "Quit both apps or rerun with --force."
  fi
fi

[[ -f "$PROD_DB" ]] || die "Production database not found at $PROD_DB."
if [[ "$COPY_CONFIG" -eq 1 && ! -f "$PROD_CONFIG" ]]; then
  log "Warning: production config.json was not found at $PROD_CONFIG. Continuing with DB only."
  COPY_CONFIG=0
fi

log "Seeding dev data with professional safety guards."
log "  Production: $PROD_SUPPORT_DIR"
log "  Dev:        $DEV_SUPPORT_DIR"
log "  Backup:     $BACKUP_DIR"
log "  Mode:       $([[ "$COPY_CONFIG" -eq 1 ]] && echo 'db + config' || echo 'db only')"

run_or_echo mkdir -p "$STAGE_DIR"
if [[ -d "$DEV_SUPPORT_DIR" ]]; then
  run_or_echo ditto "$DEV_SUPPORT_DIR" "$STAGE_DIR"
fi
run_or_echo ditto "$PROD_DB" "$STAGE_DIR/muesli.db"
if [[ -f "$PROD_DB_SHM" ]]; then
  run_or_echo ditto "$PROD_DB_SHM" "$STAGE_DIR/muesli.db-shm"
fi
if [[ -f "$PROD_DB_WAL" ]]; then
  run_or_echo ditto "$PROD_DB_WAL" "$STAGE_DIR/muesli.db-wal"
fi
if [[ "$COPY_CONFIG" -eq 1 ]]; then
  run_or_echo ditto "$PROD_CONFIG" "$STAGE_DIR/config.json"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  validate_sqlite_db "$STAGE_DIR/muesli.db"
  if [[ -f "$STAGE_DIR/config.json" ]]; then
    validate_json_file "$STAGE_DIR/config.json"
  fi
fi

if [[ -d "$DEV_SUPPORT_DIR" ]]; then
  run_or_echo ditto "$DEV_SUPPORT_DIR" "$BACKUP_DIR"
  run_or_echo mv "$DEV_SUPPORT_DIR" "$ROLLOVER_DIR"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    SWAPPED_OLD_DEV=1
  fi
fi

run_or_echo mv "$STAGE_DIR" "$DEV_SUPPORT_DIR"
if [[ "$DRY_RUN" -eq 0 ]]; then
  SEEDED_DEV=1
fi

if [[ -d "$ROLLOVER_DIR" ]]; then
  run_or_echo rm -rf "$ROLLOVER_DIR"
fi

trap - EXIT
cleanup

log ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry run complete. No files were modified."
else
  log "Seed complete."
  if [[ -d "$BACKUP_DIR" ]]; then
    log "To restore the previous dev state:"
    log "  rm -rf \"$DEV_SUPPORT_DIR\""
    log "  ditto \"$BACKUP_DIR\" \"$DEV_SUPPORT_DIR\""
  else
    log "No previous dev support directory existed, so no backup was needed."
  fi
fi
