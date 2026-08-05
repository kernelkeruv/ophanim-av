#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_DIR="$HOME/dev/bodycam-ai"
VENV_PYTHON="$APP_DIR/.venv/bin/python"
DERIVED="/path/to/bodycam-ai-derived"
DATABASE="$DERIVED/catalog.sqlite3"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bodycam-ai"

EXPECTED_SHA256='d65d8b9ef17c14f10dbc51427115aee5b8f3da1a00628782efb575ce48704979'
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DATABASE_BACKUP="$DERIVED/catalog-before-v4-${TIMESTAMP}.sqlite3"

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for required in \
    "$VENV_PYTHON" \
    "$DATABASE"
do
    [[ -e "$required" ]] ||
        fail "Required path does not exist: $required"
done

UPGRADE_SCRIPT="$(
    find "$HOME/Downloads" \
        -maxdepth 1 \
        -type f \
        -name 'upgrade-bodycam-ai-v4.sh*' \
        -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    head -n 1 |
    cut -d' ' -f2-
)"

[[ -n "$UPGRADE_SCRIPT" && -f "$UPGRADE_SCRIPT" ]] ||
    fail "upgrade-bodycam-ai-v4.sh was not found in ~/Downloads"

ACTUAL_SHA256="$(sha256sum "$UPGRADE_SCRIPT" | awk '{print $1}')"

[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] ||
    fail "Upgrade script SHA-256 does not match the verified V4 script"

printf '[1/8] Closing the BODYCAM review player...\n'
pkill -f "$APP_DIR/player.py" 2>/dev/null || true

printf '[2/8] Preventing the timer and rescan queue from restarting the indexer...\n'
systemctl --user stop bodycam-ai-index.timer 2>/dev/null || true
systemctl --user stop bodycam-ai-rescan.service 2>/dev/null || true

printf '[3/8] Stopping the active indexing process cleanly...\n'
systemctl --user stop --no-block bodycam-ai-index.service 2>/dev/null || true

for ((attempt = 1; attempt <= 60; attempt++)); do
    if ! systemctl --user is-active --quiet bodycam-ai-index.service; then
        break
    fi

    printf '\rWaiting for indexer shutdown: %02d/60 seconds' "$attempt"
    sleep 1
done

printf '\n'

if systemctl --user is-active --quiet bodycam-ai-index.service; then
    printf 'Indexer did not stop within 60 seconds; sending SIGTERM...\n'

    systemctl --user kill \
        --kill-who=all \
        --signal=TERM \
        bodycam-ai-index.service 2>/dev/null || true

    sleep 10
fi

if systemctl --user is-active --quiet bodycam-ai-index.service; then
    printf 'Indexer still active; forcing termination...\n'

    systemctl --user kill \
        --kill-who=all \
        --signal=KILL \
        bodycam-ai-index.service 2>/dev/null || true

    sleep 3
fi

systemctl --user is-active --quiet bodycam-ai-index.service &&
    fail "Could not stop bodycam-ai-index.service"

systemctl --user reset-failed bodycam-ai-index.service 2>/dev/null || true

printf '[4/8] Checkpointing and backing up the SQLite catalog...\n'

"$VENV_PYTHON" - "$DATABASE" "$DATABASE_BACKUP" <<'PYTHON_BACKUP'
from pathlib import Path
import sqlite3
import sys

database = Path(sys.argv[1])
backup = Path(sys.argv[2])

source = sqlite3.connect(database, timeout=120)
source.execute("PRAGMA busy_timeout=120000")
source.execute("PRAGMA wal_checkpoint(TRUNCATE)")

integrity = source.execute("PRAGMA integrity_check").fetchone()[0]
if integrity != "ok":
    raise SystemExit(f"Catalog integrity check failed: {integrity}")

destination = sqlite3.connect(backup)
source.backup(destination)
destination.commit()
destination.close()
source.close()

print(f"Catalog integrity: {integrity}")
print(f"Catalog backup: {backup}")
PYTHON_BACKUP

chmod 600 "$DATABASE_BACKUP"

printf '[5/8] Running the verified V4 upgrade without a competing database writer...\n'
install -m 0700 -- "$UPGRADE_SCRIPT" /tmp/upgrade-bodycam-ai-v4.sh
bash /tmp/upgrade-bodycam-ai-v4.sh

printf '[6/8] Verifying the migration and Python code...\n'

"$VENV_PYTHON" - "$DATABASE" <<'PYTHON_VERIFY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1], timeout=120)
connection.execute("PRAGMA busy_timeout=120000")

integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
if integrity != "ok":
    raise SystemExit(f"Catalog integrity check failed: {integrity}")

table = connection.execute(
    """
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
      AND name = 'media_aliases'
    """
).fetchone()

index = connection.execute(
    """
    SELECT name
    FROM sqlite_master
    WHERE type = 'index'
      AND name = 'idx_media_aliases_sha256'
    """
).fetchone()

if table is None:
    raise SystemExit("media_aliases table was not created")

if index is None:
    raise SystemExit("idx_media_aliases_sha256 index was not created")

print("Catalog integrity: ok")
print("Duplicate-alias table: present")
print("Duplicate SHA-256 index: present")

connection.close()
PYTHON_VERIFY

"$VENV_PYTHON" -m py_compile \
    "$APP_DIR/player.py" \
    "$APP_DIR/bodycam_ai.py"

printf '[7/8] Restarting the timer and indexing service...\n'
systemctl --user daemon-reload
systemctl --user enable --now bodycam-ai-index.timer
systemctl --user start --no-block bodycam-ai-index.service

printf '[8/8] Reporting the repaired state...\n'

sleep 3

printf '\nCatalog status:\n'
sqlite3 -header -column "$DATABASE" '
SELECT
    status,
    COUNT(*) AS files,
    ROUND(COALESCE(SUM(duration), 0) / 3600.0, 2) AS hours
FROM media
GROUP BY status
ORDER BY status;
'

printf '\nMigration objects:\n'
sqlite3 -header -column "$DATABASE" '
SELECT type, name
FROM sqlite_master
WHERE name IN (
    "media_aliases",
    "idx_media_aliases_sha256"
)
ORDER BY type, name;
'

printf '\nService state:\n'
systemctl --user status \
    bodycam-ai-index.service \
    bodycam-ai-index.timer \
    --no-pager \
    --full \
    || true

printf '\n[OK] BODYCAM AI V4 installation completed.\n'
printf 'Database backup:\n  %s\n' "$DATABASE_BACKUP"
printf '\nThe upgraded player should already be open.\n'
printf 'Otherwise run:\n  bodycam-player\n'
