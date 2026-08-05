#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_DIR="$HOME/dev/bodycam-ai"
CONFIG_DIR="$HOME/.config/bodycam-ai"
STATE_DIR="$HOME/.local/state/bodycam-ai"
BIN_DIR="$HOME/.local/bin"

CONFIG_FILE="$CONFIG_DIR/config.env"
RUNTIME_FILE="$APP_DIR/runtime-env.sh"
PLAYER_FILE="$BIN_DIR/bodycam-player"
INDEX_FILE="$BIN_DIR/bodycam-index"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$APP_DIR/backups/runtime-path-fix-$TIMESTAMP"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for required_file in \
    "$CONFIG_FILE" \
    "$RUNTIME_FILE" \
    "$APP_DIR/player.py" \
    "$APP_DIR/bodycam_ai.py"
do
    [[ -f "$required_file" ]] ||
        die "Required file not found: $required_file"
done

mkdir -p "$BACKUP_DIR" "$STATE_DIR" "$BIN_DIR"
chmod 700 "$BACKUP_DIR" "$STATE_DIR" "$BIN_DIR"

printf '[1/7] Backing up current launchers...\n'

cp -a -- "$CONFIG_FILE" "$BACKUP_DIR/config.env"
cp -a -- "$RUNTIME_FILE" "$BACKUP_DIR/runtime-env.sh"

[[ -f "$PLAYER_FILE" ]] &&
    cp -a -- "$PLAYER_FILE" "$BACKUP_DIR/bodycam-player"

[[ -f "$INDEX_FILE" ]] &&
    cp -a -- "$INDEX_FILE" "$BACKUP_DIR/bodycam-index"

printf '[2/7] Exporting variables loaded from config.env...\n'

python3.13 - "$RUNTIME_FILE" "$CONFIG_FILE" <<'PYTHON_PATCH'
from pathlib import Path
import sys

runtime_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])

text = runtime_path.read_text(encoding="utf-8")
source_line = f'source "{config_path}"'
exported_block = f'''set -a
{source_line}
set +a'''

if exported_block not in text:
    if source_line not in text:
        raise SystemExit(
            f"Could not locate expected source statement: {source_line}"
        )

    text = text.replace(source_line, exported_block, 1)
    runtime_path.write_text(text, encoding="utf-8")
PYTHON_PATCH

printf '[3/7] Rebuilding bodycam-player launcher...\n'

cat > "$PLAYER_FILE" <<'PLAYER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="$HOME/dev/bodycam-ai"
STATE_DIR="$HOME/.local/state/bodycam-ai"

source "$APP_DIR/runtime-env.sh"

export \
    BODYCAM_SOURCE \
    BODYCAM_DERIVED \
    WHISPER_MODEL \
    YOLO_MODEL \
    YOLO_STRIDE \
    ENABLE_DIARIZATION \
    HF_TOKEN_FILE

export QT_QPA_PLATFORM=xcb

DATABASE="$BODYCAM_DERIVED/catalog.sqlite3"

if [[ ! -f "$DATABASE" ]]; then
    printf 'ERROR: BODYCAM catalog does not exist:\n  %s\n' "$DATABASE" >&2
    exit 2
fi

mkdir -p "$STATE_DIR"

exec "$APP_DIR/.venv/bin/python" \
    "$APP_DIR/player.py" \
    "$@"
PLAYER_EOF

printf '[4/7] Rebuilding bodycam-index launcher...\n'

cat > "$INDEX_FILE" <<'INDEX_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="$HOME/dev/bodycam-ai"
STATE_DIR="$HOME/.local/state/bodycam-ai"

source "$APP_DIR/runtime-env.sh"

export \
    BODYCAM_SOURCE \
    BODYCAM_DERIVED \
    WHISPER_MODEL \
    YOLO_MODEL \
    YOLO_STRIDE \
    ENABLE_DIARIZATION \
    HF_TOKEN_FILE

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

LOCK_FILE="$STATE_DIR/index.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    printf 'BODYCAM indexing is already running.\n'
    printf 'Use these commands instead:\n'
    printf '  bodycam-status\n'
    printf '  bodycam-log\n'
    exit 0
fi

exec "$APP_DIR/.venv/bin/python" \
    "$APP_DIR/bodycam_ai.py" \
    --source "$BODYCAM_SOURCE" \
    --derived "$BODYCAM_DERIVED" \
    "$@"
INDEX_EOF

chmod 700 "$RUNTIME_FILE" "$PLAYER_FILE" "$INDEX_FILE"

printf '[5/7] Validating shell syntax and exported paths...\n'

bash -n "$RUNTIME_FILE"
bash -n "$PLAYER_FILE"
bash -n "$INDEX_FILE"

RUNTIME_REPORT="$(
    bash -c '
        set -Eeuo pipefail
        source "$HOME/dev/bodycam-ai/runtime-env.sh"
        printf "BODYCAM_SOURCE=%s\n" "$BODYCAM_SOURCE"
        printf "BODYCAM_DERIVED=%s\n" "$BODYCAM_DERIVED"
        env | grep "^BODYCAM_DERIVED="
    '
)"

printf '%s\n' "$RUNTIME_REPORT"

BODYCAM_DERIVED="$(
    bash -c '
        source "$HOME/dev/bodycam-ai/runtime-env.sh"
        printf "%s" "$BODYCAM_DERIVED"
    '
)"

DATABASE="$BODYCAM_DERIVED/catalog.sqlite3"

[[ "$BODYCAM_DERIVED" == \
    "/path/to/bodycam-ai-derived" ]] ||
    die "Unexpected derived directory: $BODYCAM_DERIVED"

[[ -f "$DATABASE" ]] ||
    die "Catalog is still missing: $DATABASE"

printf '[6/7] Checking catalog...\n'

sqlite3 -header -column "$DATABASE" '
SELECT
    status,
    COUNT(*) AS files,
    ROUND(COALESCE(SUM(duration), 0) / 3600.0, 2) AS hours
FROM media
GROUP BY status
ORDER BY status;
'

printf '\nCatalog location:\n  %s\n' "$DATABASE"
printf 'Catalog size:\n'
du -h "$DATABASE" "$DATABASE-wal" 2>/dev/null || true

printf '[7/7] Opening BODYCAM AI Review Player...\n'

PLAYER_LOG="$STATE_DIR/player.log"

nohup "$PLAYER_FILE" \
    >"$PLAYER_LOG" \
    2>&1 &

PLAYER_PID=$!

sleep 3

if kill -0 "$PLAYER_PID" 2>/dev/null; then
    printf '\n[OK] Player launched with PID %s.\n' "$PLAYER_PID"
else
    printf '\nERROR: Player exited during startup.\n' >&2
    printf 'Player log:\n' >&2
    cat "$PLAYER_LOG" >&2 || true
    exit 1
fi

printf 'Player log:\n  %s\n' "$PLAYER_LOG"
printf 'Backup directory:\n  %s\n' "$BACKUP_DIR"
printf '\nCurrent indexing remains active and was not interrupted.\n'
