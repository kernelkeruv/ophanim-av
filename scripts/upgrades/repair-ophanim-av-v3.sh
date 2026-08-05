#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_DIR="$HOME/dev/ophanim-av"
CONFIG_DIR="$HOME/.config/ophanim-av"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ophanim-av"
BIN_DIR="$HOME/.local/bin"
DERIVED="/path/to/ophanim-av-derived"
DB="$DERIVED/catalog.sqlite3"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$APP_DIR/backups/clickable-transcript-vision-v3-$TIMESTAMP"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for required in \
    "$APP_DIR/ophanim_av.py" \
    "$APP_DIR/player.py" \
    "$APP_DIR/.venv/bin/python" \
    "$APP_DIR/runtime-env.sh" \
    "$DB"
do
    [[ -e "$required" ]] || fail "Missing required path: $required"
done

printf '[1/10] Stopping the current indexer and player...\n'
systemctl --user stop ophanim-av-index.timer ophanim-av-index.service 2>/dev/null || true
pkill -f "$APP_DIR/player.py" 2>/dev/null || true
sleep 2

printf '[1A/10] Installing the tracker dependency before runtime startup...\n'
"$APP_DIR/.venv/bin/python" -m pip install --upgrade "lap>=0.5.12"

printf '[1B/10] Applying RTX 3060 memory-safe runtime configuration...\n'
"$APP_DIR/.venv/bin/python" - "$CONFIG_DIR/config.env" "$APP_DIR/runtime-env.sh" <<'PY_RUNTIME'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
runtime_path = Path(sys.argv[2])
config = config_path.read_text(encoding="utf-8")
values = {
    "WHISPER_MODEL": "large-v3",
    "WHISPER_COMPUTE_TYPE": "int8_float16",
    "WHISPER_CPU_COMPUTE_TYPE": "int8",
    "WHISPER_LANGUAGE": "en",
    "YOLO_MODEL": "yolo11s.pt",
    "YOLO_STRIDE": "3",
    "YOLO_IMGSZ": "640",
    "YOLO_HALF": "1",
}
for key, value in values.items():
    line = f'{key}="{value}"'
    pattern = rf'(?m)^{re.escape(key)}=.*$'
    if re.search(pattern, config):
        config = re.sub(pattern, line, config)
    else:
        config += ("" if config.endswith("\n") else "\n") + line + "\n"
config_path.write_text(config, encoding="utf-8")

runtime = runtime_path.read_text(encoding="utf-8")
source_match = re.search(r'(?m)^source "[^"]+/config\.env"$', runtime)
if source_match and "set -a\n" + source_match.group(0) + "\nset +a" not in runtime:
    runtime = runtime.replace(
        source_match.group(0),
        "set -a\n" + source_match.group(0) + "\nset +a",
        1,
    )
for line in (
    "export UV_LINK_MODE=copy",
    "export CT2_CUDA_ALLOCATOR=cuda_malloc_async",
    "export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True",
    "export CUDA_MODULE_LOADING=LAZY",
):
    if line not in runtime:
        runtime += ("" if runtime.endswith("\n") else "\n") + line + "\n"
runtime_path.write_text(runtime, encoding="utf-8")
PY_RUNTIME
chmod 0600 "$CONFIG_DIR/config.env"
chmod 0700 "$APP_DIR/runtime-env.sh"

printf '[2/10] Backing up application code and SQLite catalog...\n'
install -d -m 0700 "$BACKUP" "$STATE_DIR" "$BIN_DIR"
cp -a -- "$APP_DIR/ophanim_av.py" "$BACKUP/ophanim_av.py"
cp -a -- "$APP_DIR/player.py" "$BACKUP/player.py"
cp -a -- "$APP_DIR/runtime-env.sh" "$BACKUP/runtime-env.sh"
cp -a -- "$CONFIG_DIR/config.env" "$BACKUP/config.env"
sqlite3 "$DB" ".backup '$BACKUP/catalog.sqlite3'"

printf '[3/10] Patching the indexer for word timestamps and annotated previews...\n'
cat > "$BACKUP/patch-indexer.py" <<'PY_PATCH'
from __future__ import annotations
from pathlib import Path
import re, sys

path=Path(sys.argv[1])
text=path.read_text(encoding='utf-8')

# 1 schema
needle='''        CREATE INDEX IF NOT EXISTS idx_transcript_media_start ON transcript(media_id, start);\n        CREATE TABLE IF NOT EXISTS events ('''
replacement='''        CREATE INDEX IF NOT EXISTS idx_transcript_media_start ON transcript(media_id, start);\n        CREATE TABLE IF NOT EXISTS transcript_words (\n            id INTEGER PRIMARY KEY,\n            media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,\n            segment_start REAL NOT NULL,\n            start REAL NOT NULL,\n            end REAL NOT NULL,\n            word TEXT NOT NULL,\n            probability REAL\n        );\n        CREATE INDEX IF NOT EXISTS idx_transcript_words_media_start\n            ON transcript_words(media_id, start);\n        CREATE TABLE IF NOT EXISTS events ('''
if 'CREATE TABLE IF NOT EXISTS transcript_words' not in text:
    if needle not in text: raise SystemExit('schema anchor not found')
    text=text.replace(needle,replacement,1)

# 2 clear words
needle='''    conn.execute("DELETE FROM transcript WHERE media_id = ?", (media_id,))\n    conn.execute("DELETE FROM events WHERE media_id = ?", (media_id,))'''
replacement='''    conn.execute("DELETE FROM transcript_words WHERE media_id = ?", (media_id,))\n    conn.execute("DELETE FROM transcript WHERE media_id = ?", (media_id,))\n    conn.execute("DELETE FROM events WHERE media_id = ?", (media_id,))'''
if 'DELETE FROM transcript_words WHERE media_id' not in text:
    if needle not in text: raise SystemExit('clear anchor not found')
    text=text.replace(needle,replacement,1)

# 3 replace detect_objects
pattern=r'def detect_objects\(.*?\n\ndef add_events\('
new_func=r'''def detect_objects(
    source: Path,
    work_dir: Path,
    model_name: str,
    device: str,
    fps: float,
    stride: int,
) -> list[dict[str, Any]]:
    """Track objects and create a review proxy with synchronized boxes and motion state."""
    import cv2
    from ultralytics import YOLO

    model = YOLO(model_name)
    stride = max(1, stride)
    source_fps = max(float(fps), 1.0)
    output_fps = max(1.0, source_fps / stride)

    motion_samples_path = work_dir / "motion-samples.json"
    try:
        motion_samples = json.loads(motion_samples_path.read_text(encoding="utf-8"))
    except Exception:
        motion_samples = []
    motion_index = 0

    results = model.track(
        source=str(source),
        stream=True,
        persist=True,
        tracker="botsort.yaml",
        device=0 if device == "cuda" else "cpu",
        vid_stride=stride,
        conf=0.25,
        iou=0.5,
        verbose=False,
        save=False,
    )

    detections_path = work_dir / "objects.jsonl"
    detections_path.unlink(missing_ok=True)
    silent_preview = work_dir / "annotated-preview.silent.mp4"
    final_preview = work_dir / "annotated-preview.mp4"
    silent_preview.unlink(missing_ok=True)
    final_preview.unlink(missing_ok=True)

    writer = None
    events: list[dict[str, Any]] = []
    last_seen: dict[tuple[str, int], float] = {}

    try:
        with detections_path.open("a", encoding="utf-8") as output:
            for result_index, result in enumerate(results):
                timestamp = result_index * stride / source_fps
                annotated = result.plot()

                while (
                    motion_index + 1 < len(motion_samples)
                    and float(motion_samples[motion_index + 1].get("time", 0.0)) <= timestamp
                ):
                    motion_index += 1
                motion_score = (
                    float(motion_samples[motion_index].get("score", 0.0))
                    if motion_samples else 0.0
                )

                height, width = annotated.shape[:2]
                if writer is None:
                    writer = cv2.VideoWriter(
                        str(silent_preview),
                        cv2.VideoWriter_fourcc(*"mp4v"),
                        output_fps,
                        (width, height),
                    )
                    if not writer.isOpened():
                        raise RuntimeError(f"Could not open preview writer: {silent_preview}")

                motion_active = motion_score >= 0.025
                banner_color = (0, 0, 220) if motion_active else (45, 45, 45)
                cv2.rectangle(annotated, (0, 0), (width, 42), banner_color, -1)
                cv2.putText(
                    annotated,
                    f"{timestamp_srt(timestamp)[:-4]}  MOTION={motion_score:.3f}  "
                    f"{'ACTIVE' if motion_active else 'inactive'}",
                    (12, 29),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.72,
                    (255, 255, 255),
                    2,
                    cv2.LINE_AA,
                )
                writer.write(annotated)

                boxes = result.boxes
                if boxes is None:
                    continue
                ids = boxes.id.int().cpu().tolist() if boxes.id is not None else [-1] * len(boxes)
                classes = boxes.cls.int().cpu().tolist()
                confidences = boxes.conf.cpu().tolist()
                coordinates = boxes.xyxy.cpu().tolist()
                for track_id, class_id, confidence, xyxy in zip(ids, classes, confidences, coordinates):
                    label = str(model.names[int(class_id)])
                    record = {
                        "time": timestamp,
                        "track_id": int(track_id),
                        "class_id": int(class_id),
                        "label": label,
                        "confidence": float(confidence),
                        "xyxy": [round(float(value), 2) for value in xyxy],
                    }
                    output.write(json.dumps(record, ensure_ascii=False) + "\n")
                    key = (label, int(track_id))
                    if timestamp - last_seen.get(key, -999.0) >= 1.0:
                        events.append({
                            "start": timestamp,
                            "end": timestamp + max(1.5, stride / source_fps),
                            "kind": "object",
                            "label": label,
                            "confidence": float(confidence),
                            "metadata": record,
                        })
                        last_seen[key] = timestamp
    finally:
        if writer is not None:
            writer.release()

    if silent_preview.is_file() and silent_preview.stat().st_size:
        run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(silent_preview),
            "-i", str(source),
            "-map", "0:v:0", "-map", "1:a?",
            "-c:v", "libx264", "-preset", "fast", "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k",
            "-shortest", str(final_preview),
        ])
        silent_preview.unlink(missing_ok=True)

    json_dump(work_dir / "object-events.json", events)
    del model
    with contextlib.suppress(Exception):
        import torch
        torch.cuda.empty_cache()
    return events


def add_events('''
if 'annotated-preview.silent.mp4' not in text:
    text2,n=re.subn(pattern,lambda _m: new_func,text,flags=re.S)
    if n!=1: raise SystemExit(f'detect_objects replacement count {n}')
    text=text2

# 4 add words function
anchor='''def merge_review_intervals(events: list[dict[str, Any]], duration: float) -> list[dict[str, Any]]:'''
words_func='''def add_transcript_words(\n    conn: sqlite3.Connection,\n    media_id: int,\n    segments: Iterable[dict[str, Any]],\n) -> None:\n    rows = []\n    for segment in segments:\n        segment_start = float(segment["start"])\n        for word in segment.get("words") or []:\n            start = word.get("start")\n            end = word.get("end")\n            token = str(word.get("word") or "")\n            if start is None or end is None or not token.strip():\n                continue\n            rows.append((\n                media_id,\n                segment_start,\n                float(start),\n                float(end),\n                token,\n                word.get("probability"),\n            ))\n    conn.executemany(\n        """\n        INSERT INTO transcript_words(\n            media_id, segment_start, start, end, word, probability\n        ) VALUES (?, ?, ?, ?, ?, ?)\n        """,\n        rows,\n    )\n\n\n'''
if 'def add_transcript_words(' not in text:
    if anchor not in text: raise SystemExit('merge anchor not found')
    text=text.replace(anchor,words_func+anchor,1)

# 5 call words
needle='''        add_transcript(conn, media_id, segments)\n        all_events.extend({'''
replacement='''        add_transcript(conn, media_id, segments)\n        add_transcript_words(conn, media_id, segments)\n        all_events.extend({'''
if 'add_transcript_words(conn, media_id, segments)' not in text:
    if needle not in text: raise SystemExit('call anchor not found')
    text=text.replace(needle,replacement,1)

# 6 retry-incomplete option/filter
needle='''    parser.add_argument("--limit", type=int)\n    parser.add_argument("--skip-transcription", action="store_true")'''
replacement='''    parser.add_argument("--limit", type=int)\n    parser.add_argument(\n        "--retry-incomplete",\n        action="store_true",\n        help="Process only media currently marked failed, processing, or new",\n    )\n    parser.add_argument("--skip-transcription", action="store_true")'''
if '--retry-incomplete' not in text:
    if needle not in text: raise SystemExit('arg anchor not found')
    text=text.replace(needle,replacement,1)

needle='''    paths = discover(source)\n    if args.limit:\n        paths = paths[:args.limit]'''
replacement='''    paths = discover(source)\n    if args.retry_incomplete:\n        retry_paths = {\n            str(row[0])\n            for row in conn.execute(\n                "SELECT source_path FROM media WHERE status IN ('failed', 'processing', 'new')"\n            ).fetchall()\n        }\n        paths = [path for path in paths if str(path) in retry_paths]\n    if args.limit:\n        paths = paths[:args.limit]'''
if 'retry_paths = {' not in text:
    if needle not in text: raise SystemExit('paths anchor not found')
    text=text.replace(needle,replacement,1)

path.write_text(text,encoding='utf-8')
PY_PATCH

"$APP_DIR/.venv/bin/python" "$BACKUP/patch-indexer.py" "$APP_DIR/ophanim_av.py"

printf '[3A/10] Patching CUDA OOM fallback, quiet-audio recovery, and model cleanup...\n'
cat > "$BACKUP/patch-memory-safety.py" <<'PY_MEMORY'
from __future__ import annotations
from pathlib import Path
import re, sys

path=Path(sys.argv[1])
text=path.read_text(encoding='utf-8')

if 'def _wav_metrics(' in text and 'Whisper CUDA OOM; retrying this file on CPU' in text:
    path.write_text(text, encoding='utf-8')
    raise SystemExit(0)

# Replace transcription and sentiment with VRAM-safe implementations.
pattern=r'def transcribe\(.*?\n\ndef diarize\('
replacement=r'''def _wav_metrics(wav_path: Path) -> tuple[float, float]:
    """Return duration seconds and RMS dBFS for a PCM WAV file."""
    import math
    import wave
    import numpy as np

    with wave.open(str(wav_path), "rb") as handle:
        frames = handle.getnframes()
        rate = max(1, handle.getframerate())
        width = handle.getsampwidth()
        raw = handle.readframes(frames)
    duration = frames / rate
    if not raw or width != 2:
        return duration, -120.0
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float32)
    if samples.size == 0:
        return duration, -120.0
    rms = float(np.sqrt(np.mean(np.square(samples), dtype=np.float64)))
    if rms <= 0.0:
        return duration, -120.0
    return duration, 20.0 * math.log10(rms / 32768.0)


def _release_cuda() -> None:
    import gc
    gc.collect()
    with contextlib.suppress(Exception):
        import torch
        torch.cuda.empty_cache()
        torch.cuda.ipc_collect()


def transcribe(
    wav_path: Path,
    work_dir: Path,
    model_name: str,
    device: str,
    compute_type: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    from faster_whisper import WhisperModel

    duration, rms_dbfs = _wav_metrics(wav_path)
    language = os.environ.get("WHISPER_LANGUAGE", "en").strip() or None

    if duration < 0.50:
        logging.info(
            "Skipping Whisper for %.3f-second audio; below useful transcription threshold",
            duration,
        )
        segments: list[dict[str, Any]] = []
        metadata = {
            "language": language,
            "language_probability": None,
            "duration": duration,
            "duration_after_vad": 0.0,
            "model": model_name,
            "device": device,
            "compute_type": compute_type,
            "rms_dbfs": rms_dbfs,
            "skipped_short_audio": True,
        }
        json_dump(work_dir / "transcription-metadata.json", metadata)
        write_subtitles(work_dir, segments)
        return segments, metadata

    logging.info(
        "Loading Whisper model %s on %s with %s; audio RMS %.1f dBFS",
        model_name,
        device,
        compute_type,
        rms_dbfs,
    )
    model = None
    try:
        model = WhisperModel(
            model_name,
            device=device,
            compute_type=compute_type,
            cpu_threads=max(1, min(8, os.cpu_count() or 4)),
            num_workers=1,
        )

        def materialize(vad_filter: bool):
            segment_iter, info = model.transcribe(
                str(wav_path),
                language=language,
                beam_size=5,
                best_of=5,
                vad_filter=vad_filter,
                word_timestamps=True,
                condition_on_previous_text=True,
            )
            output: list[dict[str, Any]] = []
            for segment in segment_iter:
                words = []
                for word in segment.words or []:
                    words.append({
                        "start": word.start,
                        "end": word.end,
                        "word": word.word,
                        "probability": word.probability,
                    })
                output.append({
                    "start": float(segment.start),
                    "end": float(segment.end),
                    "text": segment.text.strip(),
                    "avg_logprob": getattr(segment, "avg_logprob", None),
                    "no_speech_prob": getattr(segment, "no_speech_prob", None),
                    "words": words,
                })
            return output, info

        segments, info = materialize(True)
        used_vad = True
        if not segments and duration >= 3.0 and rms_dbfs > -52.0:
            logging.warning(
                "VAD removed all %.1f seconds despite RMS %.1f dBFS; retrying without VAD",
                duration,
                rms_dbfs,
            )
            segments, info = materialize(False)
            used_vad = False

        metadata = {
            "language": info.language,
            "language_probability": info.language_probability,
            "duration": info.duration,
            "duration_after_vad": getattr(info, "duration_after_vad", None),
            "model": model_name,
            "device": device,
            "compute_type": compute_type,
            "rms_dbfs": rms_dbfs,
            "vad_filter": used_vad,
        }
        json_dump(work_dir / "transcription-metadata.json", metadata)
        write_subtitles(work_dir, segments)
        return segments, metadata
    finally:
        if model is not None:
            with contextlib.suppress(Exception):
                model.model.unload_model()
        model = None
        _release_cuda()


def apply_sentiment(segments: list[dict[str, Any]], device: str) -> None:
    """Run low-priority text classification on CPU to preserve GPU VRAM."""
    from transformers import pipeline

    classifier = pipeline(
        "text-classification",
        model="cardiffnlp/twitter-roberta-base-sentiment-latest",
        device=-1,
        truncation=True,
    )
    texts = [segment["text"][:500] or " " for segment in segments]
    try:
        for start in range(0, len(texts), 8):
            batch = classifier(texts[start:start + 8])
            for offset, result in enumerate(batch):
                segments[start + offset]["sentiment_label"] = str(result["label"]).lower()
                segments[start + offset]["sentiment_score"] = float(result["score"])
    finally:
        classifier = None
        _release_cuda()


def diarize('''
text2,n=re.subn(pattern,lambda _m: replacement,text,flags=re.S)
if n != 1:
    raise SystemExit(f'transcribe/apply replacement count {n}')
text=text2

# Compute type is configurable and defaults to large-v3 INT8/FP16 on GPU.
pattern=r'def gpu_device\(\) -> tuple\[str, str\]:.*?\n\ndef process_media\('
replacement=r'''def gpu_device() -> tuple[str, str]:
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda", os.environ.get("WHISPER_COMPUTE_TYPE", "int8_float16")
    except Exception:
        pass
    return "cpu", os.environ.get("WHISPER_CPU_COMPUTE_TYPE", "int8")


def process_media('''
text2,n=re.subn(pattern,lambda _m: replacement,text,flags=re.S)
if n != 1:
    raise SystemExit(f'gpu_device replacement count {n}')
text=text2

# Add lower-memory Ultralytics parameters.
needle='''        device=0 if device == "cuda" else "cpu",
        vid_stride=stride,
        conf=0.25,
        iou=0.5,
        verbose=False,
        save=False,
    )'''
replacement='''        device=0 if device == "cuda" else "cpu",
        vid_stride=stride,
        imgsz=int(os.environ.get("YOLO_IMGSZ", "640")),
        half=(device == "cuda" and os.environ.get("YOLO_HALF", "1") == "1"),
        batch=1,
        conf=0.25,
        iou=0.5,
        verbose=False,
        save=False,
    )'''
if needle not in text:
    raise SystemExit('YOLO model.track anchor not found')
text=text.replace(needle,replacement,1)

# Ensure object model cleanup executes even when iteration raises.
needle='''    finally:
        if writer is not None:
            writer.release()

    if silent_preview.is_file() and silent_preview.stat().st_size:'''
replacement='''    finally:
        if writer is not None:
            writer.release()
        results = None
        model = None
        _release_cuda()

    if silent_preview.is_file() and silent_preview.stat().st_size:'''
if needle not in text:
    raise SystemExit('object cleanup anchor not found')
text=text.replace(needle,replacement,1)

# Remove the stale duplicate cleanup after successful object analysis.
text=text.replace('''    json_dump(work_dir / "object-events.json", events)
    del model
    with contextlib.suppress(Exception):
        import torch
        torch.cuda.empty_cache()
    return events''','''    json_dump(work_dir / "object-events.json", events)
    return events''',1)

# Retry Whisper on CPU if CUDA still runs out of memory.
needle='''    if not args.skip_transcription:
        segments, _ = transcribe(wav_path, work_dir, args.whisper_model, device, compute_type)
        if not args.skip_sentiment and segments:'''
replacement='''    if not args.skip_transcription:
        try:
            segments, _ = transcribe(
                wav_path, work_dir, args.whisper_model, device, compute_type
            )
        except Exception as error:
            if device == "cuda" and "out of memory" in str(error).lower():
                logging.warning(
                    "Whisper CUDA OOM; retrying this file on CPU with int8"
                )
                _release_cuda()
                segments, _ = transcribe(
                    wav_path, work_dir, args.whisper_model, "cpu", "int8"
                )
            else:
                raise
        if not args.skip_sentiment and segments:'''
if needle not in text:
    raise SystemExit('transcription call anchor not found')
text=text.replace(needle,replacement,1)

# Retry object tracking on CPU after a CUDA OOM instead of silently losing events.
needle='''        if not args.skip_objects:
            try:
                objects = detect_objects(
                    source, work_dir, args.object_model, device,
                    fps_from_probe(probe) or 30.0, args.object_stride,
                )
                all_events.extend(objects)
            except Exception:
                logging.exception("Object tracking failed; continuing")'''
replacement='''        if not args.skip_objects:
            try:
                objects = detect_objects(
                    source, work_dir, args.object_model, device,
                    fps_from_probe(probe) or 30.0, args.object_stride,
                )
                all_events.extend(objects)
            except Exception as error:
                if device == "cuda" and "out of memory" in str(error).lower():
                    logging.warning(
                        "Object tracking CUDA OOM; retrying this file on CPU"
                    )
                    _release_cuda()
                    try:
                        objects = detect_objects(
                            source, work_dir, args.object_model, "cpu",
                            fps_from_probe(probe) or 30.0, args.object_stride,
                        )
                        all_events.extend(objects)
                    except Exception:
                        logging.exception("CPU object tracking fallback failed; continuing")
                else:
                    logging.exception("Object tracking failed; continuing")'''
if needle not in text:
    raise SystemExit('object fallback anchor not found')
text=text.replace(needle,replacement,1)

# Modern SceneDetect property; suppress the deprecation warning.
text=text.replace('start.get_seconds()', 'start.seconds')
text=text.replace('end.get_seconds()', 'end.seconds')

path.write_text(text,encoding='utf-8')

PY_MEMORY
"$APP_DIR/.venv/bin/python" "$BACKUP/patch-memory-safety.py" "$APP_DIR/ophanim_av.py"

printf '[4/10] Installing the upgraded clickable-transcript player...\n'
cat > "$APP_DIR/player.py" <<'PY_PLAYER'
#!/usr/bin/env python3
from __future__ import annotations

import html
import json
import os
import sqlite3
import sys
from bisect import bisect_right
from pathlib import Path

import vlc
from PySide6.QtCore import Qt, QTimer, QUrl
from PySide6.QtGui import QAction, QDesktopServices
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSlider,
    QSplitter,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

START_ROLE = Qt.ItemDataRole.UserRole
MEDIA_ROLE = Qt.ItemDataRole.UserRole + 1
KIND_ROLE = Qt.ItemDataRole.UserRole + 2


def format_time(seconds: float, milliseconds: bool = False) -> str:
    value = max(0.0, float(seconds))
    whole = int(value)
    hours, remainder = divmod(whole, 3600)
    minutes, secs = divmod(remainder, 60)
    if milliseconds:
        ms = int(round((value - whole) * 1000.0))
        return f"{hours:02}:{minutes:02}:{secs:02}.{ms:03}"
    return f"{hours:02}:{minutes:02}:{secs:02}"


def sql_table_exists(conn: sqlite3.Connection, name: str) -> bool:
    return conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone() is not None


class OphanimAVPlayer(QMainWindow):
    def __init__(self, db_path: Path) -> None:
        super().__init__()
        self.db_path = db_path
        self.conn = sqlite3.connect(db_path, timeout=30)
        self.conn.row_factory = sqlite3.Row
        self.current_media_id: int | None = None
        self.current_path: Path | None = None
        self.current_work_dir: Path | None = None
        self.current_status = ""
        self.current_error = ""
        self.review_intervals: list[dict] = []
        self.word_starts: list[float] = []
        self.word_records: list[sqlite3.Row | dict] = []
        self.active_word_index = -1
        self.last_catalog_signature: tuple | None = None
        self.seeking = False
        self.opened_playback_path: Path | None = None

        self.vlc_instance = vlc.Instance(
            "--no-video-title-show",
            "--quiet",
            "--avcodec-hw=any",
        )
        self.player = self.vlc_instance.media_player_new()

        self.setWindowTitle("OphanimAV Review Player")
        self.resize(1720, 980)
        self._build_ui()
        self._refresh_catalog(force=True)

        self.timer = QTimer(self)
        self.timer.setInterval(200)
        self.timer.timeout.connect(self._tick)
        self.timer.start()

        self.refresh_timer = QTimer(self)
        self.refresh_timer.setInterval(3000)
        self.refresh_timer.timeout.connect(self._refresh_catalog)
        self.refresh_timer.start()

    def _build_ui(self) -> None:
        menu = self.menuBar().addMenu("File")
        open_dir = QAction("Open source directory", self)
        open_dir.triggered.connect(self._open_source_directory)
        menu.addAction(open_dir)
        open_results = QAction("Open analysis directory", self)
        open_results.triggered.connect(self._open_analysis_directory)
        menu.addAction(open_results)

        root = QWidget(self)
        root_layout = QHBoxLayout(root)
        splitter = QSplitter(Qt.Orientation.Horizontal)
        root_layout.addWidget(splitter)
        self.setCentralWidget(root)

        left = QWidget()
        left_layout = QVBoxLayout(left)
        header = QHBoxLayout()
        header.addWidget(QLabel("Indexed media"))
        self.refresh_button = QPushButton("Refresh")
        self.refresh_button.clicked.connect(lambda: self._refresh_catalog(force=True))
        header.addWidget(self.refresh_button)
        left_layout.addLayout(header)
        self.catalog_label = QLabel("Catalog loading")
        left_layout.addWidget(self.catalog_label)
        self.media_search = QLineEdit()
        self.media_search.setPlaceholderText("Filter files or status")
        self.media_search.textChanged.connect(self._filter_media)
        left_layout.addWidget(self.media_search)
        self.media_list = QListWidget()
        self.media_list.itemDoubleClicked.connect(self._open_media_item)
        left_layout.addWidget(self.media_list)
        splitter.addWidget(left)

        center = QWidget()
        center_layout = QVBoxLayout(center)
        self.playback_label = QLabel("Open a completed item. Processing items update automatically.")
        center_layout.addWidget(self.playback_label)
        self.video_frame = QFrame()
        self.video_frame.setFrameShape(QFrame.Shape.Box)
        self.video_frame.setStyleSheet("background: black;")
        self.video_frame.setMinimumSize(760, 430)
        center_layout.addWidget(self.video_frame, 1)

        controls = QHBoxLayout()
        self.play_button = QPushButton("Play")
        self.play_button.clicked.connect(self._toggle_play)
        controls.addWidget(self.play_button)
        self.stop_button = QPushButton("Stop")
        self.stop_button.clicked.connect(self.player.stop)
        controls.addWidget(self.stop_button)
        self.position = QSlider(Qt.Orientation.Horizontal)
        self.position.setRange(0, 1000)
        self.position.sliderPressed.connect(self._slider_pressed)
        self.position.sliderReleased.connect(self._slider_released)
        controls.addWidget(self.position, 1)
        self.time_label = QLabel("00:00:00 / 00:00:00")
        controls.addWidget(self.time_label)
        self.rate = QComboBox()
        for label, value in [
            ("0.5x", 0.5), ("1.0x", 1.0), ("1.5x", 1.5),
            ("2.0x", 2.0), ("3.0x", 3.0), ("4.0x", 4.0),
        ]:
            self.rate.addItem(label, value)
        self.rate.setCurrentText("1.0x")
        self.rate.currentIndexChanged.connect(self._set_rate)
        controls.addWidget(self.rate)
        self.use_preview = QCheckBox("Show AI boxes and motion")
        self.use_preview.setChecked(True)
        self.use_preview.toggled.connect(self._reload_current_at_same_time)
        controls.addWidget(self.use_preview)
        self.auto_skip = QCheckBox("Auto-skip inactive")
        controls.addWidget(self.auto_skip)
        center_layout.addLayout(controls)
        splitter.addWidget(center)

        right = QWidget()
        right_layout = QVBoxLayout(right)
        right_layout.addWidget(QLabel("Transcript search"))
        search_row = QHBoxLayout()
        self.transcript_search = QLineEdit()
        self.transcript_search.setPlaceholderText("Search transcript")
        self.transcript_search.returnPressed.connect(self._find_transcript)
        search_row.addWidget(self.transcript_search)
        self.find_button = QPushButton("Find")
        self.find_button.clicked.connect(self._find_transcript)
        search_row.addWidget(self.find_button)
        right_layout.addLayout(search_row)
        right_layout.addWidget(QLabel("Timed transcript; click any word to seek"))
        self.transcript_view = QTextBrowser()
        self.transcript_view.setOpenLinks(False)
        self.transcript_view.anchorClicked.connect(self._seek_from_anchor)
        right_layout.addWidget(self.transcript_view, 2)

        event_header = QHBoxLayout()
        event_header.addWidget(QLabel("Analysis events"))
        self.event_filter = QComboBox()
        self.event_filter.addItems(["all", "object", "motion", "speech", "scene"])
        self.event_filter.currentTextChanged.connect(self._apply_event_filter)
        event_header.addWidget(self.event_filter)
        right_layout.addLayout(event_header)
        self.event_list = QListWidget()
        self.event_list.itemClicked.connect(self._seek_from_item)
        right_layout.addWidget(self.event_list, 1)
        splitter.addWidget(right)

        splitter.setSizes([320, 980, 520])

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._attach_video_output()

    def _attach_video_output(self) -> None:
        window_id = int(self.video_frame.winId())
        if sys.platform.startswith("linux"):
            self.player.set_xwindow(window_id)
        elif sys.platform == "win32":
            self.player.set_hwnd(window_id)
        elif sys.platform == "darwin":
            self.player.set_nsobject(window_id)

    def _catalog_signature(self) -> tuple:
        self.conn.commit()
        rows = self.conn.execute(
            "SELECT status, COUNT(*), MAX(indexed_at) FROM media GROUP BY status ORDER BY status"
        ).fetchall()
        return tuple(tuple(row) for row in rows)

    def _refresh_catalog(self, force: bool = False) -> None:
        try:
            signature = self._catalog_signature()
        except sqlite3.Error:
            return
        if not force and signature == self.last_catalog_signature:
            return
        self.last_catalog_signature = signature
        current_id = self.current_media_id
        self.media_list.clear()
        rows = self.conn.execute(
            "SELECT id, source_path, status, duration, error, work_dir FROM media ORDER BY source_path"
        ).fetchall()
        counts: dict[str, int] = {}
        selected_item = None
        for row in rows:
            counts[row["status"]] = counts.get(row["status"], 0) + 1
            path = Path(row["source_path"])
            duration = format_time(float(row["duration"] or 0.0))
            item = QListWidgetItem(
                f"[{row['status']}] {path.name}  {duration}\n{path.parent}"
            )
            item.setData(MEDIA_ROLE, int(row["id"]))
            item.setToolTip(str(row["error"] or path))
            self.media_list.addItem(item)
            if current_id == int(row["id"]):
                selected_item = item
        self.catalog_label.setText(
            "  ".join(f"{key}: {value}" for key, value in sorted(counts.items()))
            or "No indexed media"
        )
        if selected_item is not None:
            self.media_list.setCurrentItem(selected_item)
            self._refresh_current_media_if_ready()
        self._filter_media(self.media_search.text())

    def _filter_media(self, text: str) -> None:
        query = text.casefold().strip()
        for index in range(self.media_list.count()):
            item = self.media_list.item(index)
            item.setHidden(query not in item.text().casefold())

    def _open_media_item(self, item: QListWidgetItem) -> None:
        self._open_media_id(int(item.data(MEDIA_ROLE)), preserve_ms=None)

    def _open_media_id(self, media_id: int, preserve_ms: int | None) -> None:
        self.conn.commit()
        row = self.conn.execute("SELECT * FROM media WHERE id=?", (media_id,)).fetchone()
        if not row:
            return
        source_path = Path(row["source_path"])
        work_dir = Path(row["work_dir"])
        if not source_path.is_file():
            QMessageBox.critical(self, "Missing file", f"Source file no longer exists:\n{source_path}")
            return

        self.current_media_id = media_id
        self.current_path = source_path
        self.current_work_dir = work_dir
        self.current_status = str(row["status"])
        self.current_error = str(row["error"] or "")

        annotated = work_dir / "annotated-preview.mp4"
        playback_path = annotated if self.use_preview.isChecked() and annotated.is_file() else source_path
        self.opened_playback_path = playback_path
        media = self.vlc_instance.media_new(str(playback_path))
        subtitle = work_dir / "transcript.srt"
        if subtitle.is_file():
            media.add_option(f":sub-file={subtitle}")
        self.player.set_media(media)
        self._attach_video_output()
        self.player.play()
        if preserve_ms is not None:
            QTimer.singleShot(500, lambda: self.player.set_time(max(0, preserve_ms)))
        self.play_button.setText("Pause")

        if playback_path == annotated:
            self.playback_label.setText(
                "AI review preview; object boxes, track IDs, confidence, and compensated motion are burned into this derivative."
            )
        elif row["media_type"] == "video":
            self.playback_label.setText(
                f"Original video; AI preview is not ready. Status: {row['status']}"
            )
        else:
            self.playback_label.setText(f"Audio playback. Status: {row['status']}")

        self._load_transcript(media_id, work_dir)
        self._load_events(media_id, row)
        review_path = work_dir / "review-intervals.json"
        try:
            self.review_intervals = (
                json.loads(review_path.read_text(encoding="utf-8"))
                if review_path.is_file() else []
            )
        except Exception:
            self.review_intervals = []
        self.setWindowTitle(f"OphanimAV Review Player; {source_path.name}")

    def _reload_current_at_same_time(self) -> None:
        if self.current_media_id is None:
            return
        self._open_media_id(self.current_media_id, preserve_ms=max(0, self.player.get_time()))

    def _refresh_current_media_if_ready(self) -> None:
        if self.current_media_id is None:
            return
        row = self.conn.execute(
            "SELECT status, error, work_dir FROM media WHERE id=?", (self.current_media_id,)
        ).fetchone()
        if not row:
            return
        work_dir = Path(row["work_dir"])
        preview = work_dir / "annotated-preview.mp4"
        needs_reload = False
        if str(row["status"]) != self.current_status:
            needs_reload = True
        if self.use_preview.isChecked() and preview.is_file() and self.opened_playback_path != preview:
            needs_reload = True
        if needs_reload:
            self._open_media_id(self.current_media_id, preserve_ms=max(0, self.player.get_time()))

    def _load_transcript(self, media_id: int, work_dir: Path) -> None:
        self.transcript_view.clear()
        self.word_starts = []
        self.word_records = []
        self.active_word_index = -1

        words: list[sqlite3.Row | dict] = []
        if sql_table_exists(self.conn, "transcript_words"):
            words = self.conn.execute(
                """
                SELECT segment_start, start, end, word, probability
                FROM transcript_words WHERE media_id=? ORDER BY start, id
                """,
                (media_id,),
            ).fetchall()

        if not words:
            transcript_json = work_dir / "transcript.json"
            if transcript_json.is_file():
                try:
                    segments = json.loads(transcript_json.read_text(encoding="utf-8"))
                    for segment in segments:
                        for word in segment.get("words") or []:
                            if word.get("start") is None or word.get("end") is None:
                                continue
                            words.append({
                                "segment_start": float(segment.get("start", 0.0)),
                                "start": float(word["start"]),
                                "end": float(word["end"]),
                                "word": str(word.get("word") or ""),
                                "probability": word.get("probability"),
                            })
                except Exception:
                    words = []

        segments = self.conn.execute(
            """
            SELECT start, end, text, speaker, sentiment_label, sentiment_score
            FROM transcript WHERE media_id=? ORDER BY start
            """,
            (media_id,),
        ).fetchall()

        if not words and not segments:
            message = "No transcript is available yet."
            if self.current_error:
                message += f"\n\nIndexer error: {self.current_error}"
            elif self.current_status == "processing":
                message += "\n\nWhisper is still processing this item."
            self.transcript_view.setPlainText(message)
            return

        self.word_records = words
        self.word_starts = [float(row["start"]) for row in words]
        words_by_segment: dict[float, list[sqlite3.Row | dict]] = {}
        for word in words:
            words_by_segment.setdefault(float(word["segment_start"]), []).append(word)

        style = """
        <style>
          body { font-family: sans-serif; font-size: 10.5pt; }
          .segment { margin-bottom: 10px; line-height: 1.55; }
          .time { font-family: monospace; font-weight: bold; }
          .meta { color: #8f9aa8; font-size: 9pt; }
          a.word { color: #d8dee9; text-decoration: none; padding: 1px 2px; }
          a.word:hover { background: #3b4252; text-decoration: underline; }
          a.time { color: #88c0d0; text-decoration: none; }
        </style>
        """
        blocks = [style]
        for segment in segments:
            start = float(segment["start"])
            segment_words = words_by_segment.get(start, [])
            meta_parts = []
            if segment["speaker"]:
                meta_parts.append(html.escape(str(segment["speaker"])))
            if segment["sentiment_label"]:
                score = float(segment["sentiment_score"] or 0.0)
                meta_parts.append(f"{html.escape(str(segment['sentiment_label']))} {score:.2f}")
            meta = " | ".join(meta_parts)
            blocks.append('<div class="segment">')
            blocks.append(
                f'<a class="time" href="seek:{start:.3f}">[{format_time(start, True)}]</a> '
            )
            if meta:
                blocks.append(f'<span class="meta">{meta}</span><br>')
            if segment_words:
                for word in segment_words:
                    token = str(word["word"]).strip()
                    if not token:
                        continue
                    probability = word["probability"]
                    title = (
                        f"{format_time(float(word['start']), True)} to "
                        f"{format_time(float(word['end']), True)}"
                    )
                    if probability is not None:
                        title += f"; confidence {float(probability):.3f}"
                    blocks.append(
                        f' <a class="word" href="seek:{float(word["start"]):.3f}" '
                        f'title="{html.escape(title)}">{html.escape(token)}</a>'
                    )
            else:
                blocks.append(html.escape(str(segment["text"])))
            blocks.append("</div>")
        self.transcript_view.setHtml("".join(blocks))

    def _load_events(self, media_id: int, media_row: sqlite3.Row) -> None:
        self.event_list.clear()
        rows = self.conn.execute(
            """
            SELECT start, end, kind, label, confidence, metadata_json
            FROM events WHERE media_id=? ORDER BY start, kind, label
            """,
            (media_id,),
        ).fetchall()
        for row in rows:
            confidence = "" if row["confidence"] is None else f"  conf={float(row['confidence']):.2f}"
            metadata = {}
            try:
                metadata = json.loads(row["metadata_json"] or "{}")
            except Exception:
                pass
            detail = ""
            if row["kind"] == "object" and metadata:
                detail = f"  track={metadata.get('track_id', '?')}"
            item = QListWidgetItem(
                f"[{format_time(row['start'], True)} to {format_time(row['end'], True)}] "
                f"{row['kind']}: {row['label']}{detail}{confidence}"
            )
            item.setData(START_ROLE, float(row["start"]))
            item.setData(KIND_ROLE, str(row["kind"]))
            item.setToolTip(json.dumps(metadata, indent=2, ensure_ascii=False) if metadata else "")
            self.event_list.addItem(item)
        if not rows and media_row["error"]:
            item = QListWidgetItem(f"Indexer error: {media_row['error']}")
            item.setData(KIND_ROLE, "error")
            self.event_list.addItem(item)
        self._apply_event_filter(self.event_filter.currentText())

    def _apply_event_filter(self, kind: str) -> None:
        for index in range(self.event_list.count()):
            item = self.event_list.item(index)
            item_kind = str(item.data(KIND_ROLE) or "")
            item.setHidden(kind != "all" and item_kind != kind)

    def _find_transcript(self) -> None:
        query = self.transcript_search.text().strip()
        if not query:
            return
        if not self.transcript_view.find(query):
            cursor = self.transcript_view.textCursor()
            cursor.movePosition(cursor.MoveOperation.Start)
            self.transcript_view.setTextCursor(cursor)
            self.transcript_view.find(query)

    def _seek_from_anchor(self, url: QUrl) -> None:
        text = url.toString()
        if not text.startswith("seek:"):
            return
        try:
            start = float(text.split(":", 1)[1])
        except ValueError:
            return
        self.player.set_time(int(start * 1000.0))
        if not self.player.is_playing():
            self.player.play()
            self.play_button.setText("Pause")

    def _seek_from_item(self, item: QListWidgetItem) -> None:
        value = item.data(START_ROLE)
        if value is None:
            return
        self.player.set_time(int(float(value) * 1000.0))
        if not self.player.is_playing():
            self.player.play()
            self.play_button.setText("Pause")

    def _toggle_play(self) -> None:
        if self.player.is_playing():
            self.player.pause()
            self.play_button.setText("Play")
        else:
            self.player.play()
            self.play_button.setText("Pause")

    def _slider_pressed(self) -> None:
        self.seeking = True

    def _slider_released(self) -> None:
        length = max(0, self.player.get_length())
        if length:
            self.player.set_time(int(length * self.position.value() / 1000.0))
        self.seeking = False

    def _set_rate(self) -> None:
        self.player.set_rate(float(self.rate.currentData() or 1.0))

    def _tick(self) -> None:
        current_ms = max(0, self.player.get_time())
        length_ms = max(0, self.player.get_length())
        current = current_ms / 1000.0
        length = length_ms / 1000.0
        self.time_label.setText(f"{format_time(current)} / {format_time(length)}")
        if length_ms and not self.seeking:
            self.position.setValue(int(current_ms * 1000 / length_ms))
        if self.auto_skip.isChecked() and self.player.is_playing() and self.review_intervals:
            self._auto_skip(current)
        if self.word_starts:
            index = bisect_right(self.word_starts, current) - 1
            if index != self.active_word_index and 0 <= index < len(self.word_records):
                self.active_word_index = index
                word = self.word_records[index]
                self.statusBar().showMessage(
                    f"Word: {str(word['word']).strip()}  "
                    f"{format_time(float(word['start']), True)} to {format_time(float(word['end']), True)}"
                )

    def _auto_skip(self, current: float) -> None:
        for interval in self.review_intervals:
            if float(interval["start"]) <= current <= float(interval["end"]):
                return
            if float(interval["start"]) > current:
                self.player.set_time(int(float(interval["start"]) * 1000.0))
                return

    def _open_source_directory(self) -> None:
        if self.current_path:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.current_path.parent)))

    def _open_analysis_directory(self) -> None:
        if self.current_work_dir:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.current_work_dir)))

    def closeEvent(self, event) -> None:
        self.player.stop()
        self.player.release()
        self.vlc_instance.release()
        self.conn.close()
        super().closeEvent(event)


def main() -> int:
    derived = Path(os.environ.get("OPHANIM_AV_DERIVED", "./derived")).expanduser().resolve()
    db_path = derived / "catalog.sqlite3"
    if not db_path.is_file():
        print(f"Database does not exist: {db_path}", file=sys.stderr)
        return 2
    app = QApplication(sys.argv)
    window = OphanimAVPlayer(db_path)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
PY_PLAYER

chmod 0700 "$APP_DIR/ophanim_av.py" "$APP_DIR/player.py"

printf '[5/10] Migrating the catalog and backfilling existing word timestamps...\n'
"$APP_DIR/.venv/bin/python" - "$DB" <<'PY_MIGRATE'
from __future__ import annotations
import json
import sqlite3
import sys
from pathlib import Path

db = Path(sys.argv[1])
conn = sqlite3.connect(db, timeout=60)
conn.execute("PRAGMA foreign_keys=ON")
conn.executescript(
    """
    CREATE TABLE IF NOT EXISTS transcript_words (
        id INTEGER PRIMARY KEY,
        media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
        segment_start REAL NOT NULL,
        start REAL NOT NULL,
        end REAL NOT NULL,
        word TEXT NOT NULL,
        probability REAL
    );
    CREATE INDEX IF NOT EXISTS idx_transcript_words_media_start
        ON transcript_words(media_id, start);
    """
)

inserted = 0
for media_id, work_dir in conn.execute("SELECT id, work_dir FROM media ORDER BY id"):
    existing = conn.execute(
        "SELECT COUNT(*) FROM transcript_words WHERE media_id=?", (media_id,)
    ).fetchone()[0]
    if existing:
        continue
    transcript_json = Path(work_dir) / "transcript.json"
    if not transcript_json.is_file():
        continue
    try:
        segments = json.loads(transcript_json.read_text(encoding="utf-8"))
    except Exception:
        continue
    rows = []
    for segment in segments:
        segment_start = float(segment.get("start", 0.0))
        for word in segment.get("words") or []:
            start = word.get("start")
            end = word.get("end")
            token = str(word.get("word") or "")
            if start is None or end is None or not token.strip():
                continue
            rows.append((
                media_id,
                segment_start,
                float(start),
                float(end),
                token,
                word.get("probability"),
            ))
    conn.executemany(
        """
        INSERT INTO transcript_words(
            media_id, segment_start, start, end, word, probability
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    inserted += len(rows)

# Completed videos created by the old indexer need one new pass to create
# the annotated review derivative. Completed audio remains untouched.
video_rows = conn.execute(
    "SELECT id, work_dir FROM media WHERE media_type='video' AND status='complete'"
).fetchall()
requeued = 0
for media_id, work_dir in video_rows:
    if not (Path(work_dir) / "annotated-preview.mp4").is_file():
        conn.execute(
            "UPDATE media SET status='processing', error=NULL WHERE id=?", (media_id,)
        )
        requeued += 1

# Failed and interrupted rows are retried after the dependency and memory fixes.
retry_count = conn.execute(
    "SELECT COUNT(*) FROM media WHERE status IN ('failed', 'processing')"
).fetchone()[0]
conn.execute(
    "UPDATE media SET status='processing', error=NULL WHERE status IN ('failed', 'processing')"
)

conn.commit()
print(f"Backfilled word rows: {inserted}")
print(f"Completed videos requeued for annotated preview: {requeued}")
print(f"Failed or interrupted rows requeued: {retry_count}")
conn.close()
PY_MIGRATE

printf '[6/10] Installing useful maintenance commands...\n'
cat > "$BIN_DIR/ophanim-failed" <<'FAILED_CMD'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$HOME/dev/ophanim-av/runtime-env.sh"
sqlite3 -header -column "$OPHANIM_AV_DERIVED/catalog.sqlite3" '
SELECT
    id,
    status,
    ROUND(duration / 60.0, 2) AS minutes,
    source_path,
    COALESCE(error, "") AS error
FROM media
WHERE status IN ("failed", "processing")
ORDER BY indexed_at DESC;
'
FAILED_CMD

cat > "$BIN_DIR/ophanim-retry-incomplete" <<'RETRY_CMD'
#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="$HOME/dev/ophanim-av"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ophanim-av"
source "$APP_DIR/runtime-env.sh"
exec 9>"$STATE_DIR/index.lock"
if ! flock -n 9; then
    printf 'BODYCAM indexing is already running.\n'
    exit 0
fi
exec "$APP_DIR/.venv/bin/python" \
    "$APP_DIR/ophanim_av.py" \
    --source "$OPHANIM_AV_SOURCE" \
    --derived "$OPHANIM_AV_DERIVED" \
    --retry-incomplete
RETRY_CMD

chmod 0700 "$BIN_DIR/ophanim-failed" "$BIN_DIR/ophanim-retry-incomplete"

printf '[7/10] Validating Python syntax and imports...\n'
"$APP_DIR/.venv/bin/python" -m py_compile \
    "$APP_DIR/ophanim_av.py" \
    "$APP_DIR/player.py"

"$APP_DIR/.venv/bin/python" - <<'PY_CHECK'
import os
import cv2
import torch
import vlc
from PySide6 import QtCore
print("OpenCV:", cv2.__version__)
print("PyTorch:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("CUDA device:", torch.cuda.get_device_name(0))
print("Whisper GPU compute:", os.environ.get("WHISPER_COMPUTE_TYPE", "unset"))
print("Whisper language:", os.environ.get("WHISPER_LANGUAGE", "unset"))
print("YOLO image size:", os.environ.get("YOLO_IMGSZ", "unset"))
print("Qt:", QtCore.qVersion())
print("libVLC:", vlc.libvlc_get_version().decode())
PY_CHECK

printf '[8/10] Checking the upgraded database...\n'
sqlite3 -header -column "$DB" '
SELECT status, COUNT(*) AS files, ROUND(SUM(duration) / 3600.0, 2) AS hours
FROM media
GROUP BY status
ORDER BY status;

SELECT COUNT(*) AS clickable_word_rows FROM transcript_words;

SELECT kind, COUNT(*) AS events
FROM events
GROUP BY kind
ORDER BY kind;
'

printf '[9/10] Restarting recurring indexing...\n'
systemctl --user daemon-reload
systemctl --user enable --now ophanim-av-index.timer
systemctl --user start --no-block ophanim-av-index.service

printf '[10/10] Opening the upgraded player...\n'
PLAYER_LOG="$STATE_DIR/player-v2.log"
nohup "$BIN_DIR/ophanim-player" >"$PLAYER_LOG" 2>&1 &
PLAYER_PID=$!
sleep 4
if ! kill -0 "$PLAYER_PID" 2>/dev/null; then
    printf 'Player failed during startup. Log follows:\n' >&2
    cat "$PLAYER_LOG" >&2 || true
    exit 1
fi

printf '\n[OK] OphanimAV v3 repair and upgrade installed.\n'
printf 'Player PID: %s\n' "$PLAYER_PID"
printf 'Player log: %s\n' "$PLAYER_LOG"
printf 'Backup: %s\n' "$BACKUP"
printf '\nNew behavior:\n'
printf '  Click any transcript word to seek to that exact word.\n'
printf '  Click any object, motion, speech, or scene event to seek.\n'
printf '  Completed analyzed videos automatically switch to annotated-preview.mp4 with boxes and motion state.\n'
printf '  The player refreshes every three seconds; Whisper uses large-v3 INT8/FP16 with CPU fallback on CUDA OOM.\n'
printf '\nCommands:\n'
printf '  ophanim-status\n'
printf '  ophanim-log\n'
printf '  ophanim-failed\n'
printf '  ophanim-retry-incomplete\n'
printf '  ophanim-player\n'
