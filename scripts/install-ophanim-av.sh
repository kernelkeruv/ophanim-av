#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_DIR="${OPHANIM_AV_SOURCE:-/path/to/media}"
DERIVED_DIR="${OPHANIM_AV_DERIVED:-/path/to/ophanim-av-derived}"
APP_DIR="${OPHANIM_AV_APP_DIR:-$HOME/dev/ophanim-av}"
VENV_DIR="$APP_DIR/.venv"
CONFIG_DIR="$HOME/.config/ophanim-av"
STATE_DIR="$HOME/.local/state/ophanim-av"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
DESKTOP_DIR="$HOME/.local/share/applications"
RUN_NOW="${RUN_NOW:-1}"

if [[ $EUID -eq 0 ]]; then
    printf 'ERROR: Run this as your normal user; the script uses sudo only for Fedora packages.\n' >&2
    exit 1
fi

printf '[1/9] Installing Fedora system dependencies...\n'
sudo dnf install -y \
    python3.13 python3.13-devel \
    gcc gcc-c++ make git git-lfs jq sqlite util-linux \
    desktop-file-utils xorg-x11-server-Xwayland \
    libX11 libxcb libxkbcommon-x11 mesa-libGL \
    xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm

FEDORA_VERSION="$(rpm -E %fedora)"
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v vlc >/dev/null 2>&1; then
    printf '[2/9] Enabling RPM Fusion for full FFmpeg and VLC packages...\n'
    sudo dnf install -y \
        "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
        "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"
    sudo dnf install -y --allowerasing ffmpeg vlc
else
    printf '[2/9] FFmpeg and VLC already installed; leaving them unchanged.\n'
fi

for required in ffmpeg ffprobe vlc python3.13; do
    command -v "$required" >/dev/null 2>&1 || { printf 'ERROR: Missing required command: %s\n' "$required" >&2; exit 1; }
done

printf '[3/9] Creating private application and evidence-derived directories...\n'
mkdir -p "$APP_DIR" "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR" "$SYSTEMD_DIR" "$DESKTOP_DIR"
mkdir -p "$DERIVED_DIR"/{items,cache,logs}
chmod 700 "$APP_DIR" "$CONFIG_DIR" "$STATE_DIR" "$DERIVED_DIR" "$DERIVED_DIR"/{items,cache,logs}
if [[ ! -d "$SOURCE_DIR" ]]; then
    printf 'WARNING: Source directory does not currently exist: %s\n' "$SOURCE_DIR" >&2
    printf 'The service will fail safely until the path is mounted or corrected in %s/config.env.\n' "$CONFIG_DIR" >&2
fi

printf '[4/9] Building isolated Python 3.13 environment...\n'
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    python3.13 -m venv "$VENV_DIR"
fi

if ! "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
    printf 'Bootstrapping pip inside the Python 3.13 virtual environment...\n'
    "$VENV_DIR/bin/python" -m ensurepip --upgrade
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel

if command -v nvidia-smi >/dev/null 2>&1; then
    printf 'Installing CUDA-enabled PyTorch wheels...\n'
    "$VENV_DIR/bin/python" -m pip install --upgrade \
        torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu128
else
    printf 'NVIDIA GPU not detected; installing CPU PyTorch wheels.\n'
    "$VENV_DIR/bin/python" -m pip install --upgrade torch torchvision torchaudio
fi

"$VENV_DIR/bin/python" -m pip install --upgrade \
    faster-whisper \
    nvidia-cublas-cu12 nvidia-cudnn-cu12 \
    ultralytics \
    opencv-python-headless numpy \
    'scenedetect[opencv]' \
    transformers sentencepiece accelerate \
    python-vlc PySide6 \
    pyannote.audio \
    rich tqdm pyyaml

"$VENV_DIR/bin/python" -m pip freeze > "$APP_DIR/requirements.lock.txt"
"$VENV_DIR/bin/yolo" settings analytics=False >/dev/null 2>&1 || true

printf '[5/9] Writing the indexer and VLC review player...\n'
cat > "$APP_DIR/ophanim_av.py" <<'PY_INDEXER'
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import logging
import os
import shutil
import sqlite3
import subprocess
import sys
import traceback
from pathlib import Path
from typing import Any, Iterable

MEDIA_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".m4v", ".webm", ".mts", ".m2ts", ".ts",
    ".mp3", ".wav", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wma", ".aax",
}
VIDEO_EXTENSIONS = {".mp4", ".mkv", ".avi", ".mov", ".m4v", ".webm", ".mts", ".m2ts", ".ts"}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def json_dump(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def run(cmd: list[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
    logging.debug("RUN %s", " ".join(cmd))
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=check,
    )


def sha256_file(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def ffprobe(path: Path) -> dict[str, Any]:
    result = run([
        "ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)
    ], capture=True)
    return json.loads(result.stdout)


def duration_from_probe(probe: dict[str, Any]) -> float:
    with contextlib.suppress(Exception):
        return float(probe.get("format", {}).get("duration", 0.0))
    for stream in probe.get("streams", []):
        with contextlib.suppress(Exception):
            return float(stream.get("duration", 0.0))
    return 0.0


def video_stream(probe: dict[str, Any]) -> dict[str, Any] | None:
    return next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), None)


def fps_from_probe(probe: dict[str, Any]) -> float:
    stream = video_stream(probe)
    if not stream:
        return 0.0
    rate = stream.get("avg_frame_rate") or stream.get("r_frame_rate") or "0/1"
    try:
        numerator, denominator = rate.split("/", 1)
        return float(numerator) / max(float(denominator), 1.0)
    except Exception:
        return 0.0


def init_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=60)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS media (
            id INTEGER PRIMARY KEY,
            source_path TEXT NOT NULL UNIQUE,
            sha256 TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            duration REAL NOT NULL DEFAULT 0,
            media_type TEXT NOT NULL,
            work_dir TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'new',
            error TEXT,
            indexed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_media_sha256 ON media(sha256);
        CREATE TABLE IF NOT EXISTS transcript (
            id INTEGER PRIMARY KEY,
            media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
            start REAL NOT NULL,
            end REAL NOT NULL,
            text TEXT NOT NULL,
            confidence REAL,
            speaker TEXT,
            sentiment_label TEXT,
            sentiment_score REAL
        );
        CREATE INDEX IF NOT EXISTS idx_transcript_media_start ON transcript(media_id, start);
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY,
            media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
            start REAL NOT NULL,
            end REAL NOT NULL,
            kind TEXT NOT NULL,
            label TEXT NOT NULL,
            confidence REAL,
            metadata_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_events_media_start ON events(media_id, start);
        CREATE INDEX IF NOT EXISTS idx_events_kind_label ON events(kind, label);
        """
    )
    return conn


def upsert_media(
    conn: sqlite3.Connection,
    source: Path,
    digest: str,
    probe: dict[str, Any],
    work_dir: Path,
) -> int:
    stat = source.stat()
    media_type = "video" if video_stream(probe) else "audio"
    conn.execute(
        """
        INSERT INTO media(source_path, sha256, size_bytes, mtime_ns, duration, media_type, work_dir, status, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'processing', ?)
        ON CONFLICT(source_path) DO UPDATE SET
            sha256=excluded.sha256,
            size_bytes=excluded.size_bytes,
            mtime_ns=excluded.mtime_ns,
            duration=excluded.duration,
            media_type=excluded.media_type,
            work_dir=excluded.work_dir,
            status='processing',
            error=NULL,
            indexed_at=excluded.indexed_at
        """,
        (
            str(source), digest, stat.st_size, stat.st_mtime_ns, duration_from_probe(probe),
            media_type, str(work_dir), now_iso(),
        ),
    )
    media_id = int(conn.execute("SELECT id FROM media WHERE source_path = ?", (str(source),)).fetchone()[0])
    conn.execute("DELETE FROM transcript WHERE media_id = ?", (media_id,))
    conn.execute("DELETE FROM events WHERE media_id = ?", (media_id,))
    conn.commit()
    return media_id


def extract_audio(source: Path, wav_path: Path) -> None:
    wav_path.parent.mkdir(parents=True, exist_ok=True)
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
        "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav_path),
    ])


def timestamp_srt(seconds: float) -> str:
    milliseconds = max(0, int(round(seconds * 1000)))
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02}:{minutes:02}:{secs:02},{milliseconds:03}"


def timestamp_vtt(seconds: float) -> str:
    return timestamp_srt(seconds).replace(",", ".")


def write_subtitles(work_dir: Path, segments: list[dict[str, Any]]) -> None:
    srt_lines: list[str] = []
    vtt_lines: list[str] = ["WEBVTT", ""]
    txt_lines: list[str] = []
    for index, segment in enumerate(segments, start=1):
        text = segment["text"].strip()
        srt_lines.extend([
            str(index),
            f"{timestamp_srt(segment['start'])} --> {timestamp_srt(segment['end'])}",
            text,
            "",
        ])
        vtt_lines.extend([
            f"{timestamp_vtt(segment['start'])} --> {timestamp_vtt(segment['end'])}",
            text,
            "",
        ])
        txt_lines.append(f"[{timestamp_vtt(segment['start'])}] {text}")
    (work_dir / "transcript.srt").write_text("\n".join(srt_lines), encoding="utf-8")
    (work_dir / "transcript.vtt").write_text("\n".join(vtt_lines), encoding="utf-8")
    (work_dir / "transcript.txt").write_text("\n".join(txt_lines) + "\n", encoding="utf-8")
    json_dump(work_dir / "transcript.json", segments)


def transcribe(
    wav_path: Path,
    work_dir: Path,
    model_name: str,
    device: str,
    compute_type: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    from faster_whisper import WhisperModel

    logging.info("Loading Whisper model %s on %s", model_name, device)
    model = WhisperModel(model_name, device=device, compute_type=compute_type)
    segment_iter, info = model.transcribe(
        str(wav_path),
        beam_size=5,
        best_of=5,
        vad_filter=True,
        word_timestamps=True,
        condition_on_previous_text=True,
    )
    segments: list[dict[str, Any]] = []
    for segment in segment_iter:
        words = []
        for word in segment.words or []:
            words.append({
                "start": word.start,
                "end": word.end,
                "word": word.word,
                "probability": word.probability,
            })
        segments.append({
            "start": float(segment.start),
            "end": float(segment.end),
            "text": segment.text.strip(),
            "avg_logprob": getattr(segment, "avg_logprob", None),
            "no_speech_prob": getattr(segment, "no_speech_prob", None),
            "words": words,
        })
    metadata = {
        "language": info.language,
        "language_probability": info.language_probability,
        "duration": info.duration,
        "duration_after_vad": getattr(info, "duration_after_vad", None),
        "model": model_name,
        "device": device,
        "compute_type": compute_type,
    }
    json_dump(work_dir / "transcription-metadata.json", metadata)
    write_subtitles(work_dir, segments)
    del model
    with contextlib.suppress(Exception):
        import torch
        torch.cuda.empty_cache()
    return segments, metadata


def apply_sentiment(segments: list[dict[str, Any]], device: str) -> None:
    from transformers import pipeline

    pipeline_device = 0 if device == "cuda" else -1
    classifier = pipeline(
        "text-classification",
        model="cardiffnlp/twitter-roberta-base-sentiment-latest",
        device=pipeline_device,
        truncation=True,
    )
    texts = [segment["text"][:500] or " " for segment in segments]
    for start in range(0, len(texts), 16):
        batch = classifier(texts[start:start + 16])
        for offset, result in enumerate(batch):
            segments[start + offset]["sentiment_label"] = str(result["label"]).lower()
            segments[start + offset]["sentiment_score"] = float(result["score"])
    del classifier
    with contextlib.suppress(Exception):
        import torch
        torch.cuda.empty_cache()


def diarize(wav_path: Path, work_dir: Path, token: str, device: str) -> list[dict[str, Any]]:
    os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "0")
    import torch
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-community-1", token=token)
    if device == "cuda":
        pipeline.to(torch.device("cuda"))
    output = pipeline(str(wav_path))
    annotation = getattr(output, "exclusive_speaker_diarization", None) or output.speaker_diarization
    turns: list[dict[str, Any]] = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append({"start": float(turn.start), "end": float(turn.end), "speaker": str(speaker)})
    json_dump(work_dir / "diarization.json", turns)
    del pipeline
    with contextlib.suppress(Exception):
        torch.cuda.empty_cache()
    return turns


def assign_speakers(segments: list[dict[str, Any]], turns: list[dict[str, Any]]) -> None:
    for segment in segments:
        best_speaker = None
        best_overlap = 0.0
        for turn in turns:
            overlap = max(0.0, min(segment["end"], turn["end"]) - max(segment["start"], turn["start"]))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = turn["speaker"]
        segment["speaker"] = best_speaker


def detect_scenes(source: Path, work_dir: Path) -> list[dict[str, Any]]:
    from scenedetect import AdaptiveDetector, SceneManager, open_video

    video = open_video(str(source))
    manager = SceneManager()
    manager.add_detector(AdaptiveDetector(adaptive_threshold=3.0, min_scene_len=15))
    manager.detect_scenes(video=video, show_progress=False)
    scenes = [
        {"start": start.get_seconds(), "end": end.get_seconds(), "label": "scene"}
        for start, end in manager.get_scene_list(start_in_scene=True)
    ]
    json_dump(work_dir / "scenes.json", scenes)
    return scenes


def compensated_motion(source: Path, work_dir: Path, sample_seconds: float = 0.5) -> list[dict[str, Any]]:
    import cv2
    import numpy as np

    capture = cv2.VideoCapture(str(source))
    fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    stride = max(1, int(round(fps * sample_seconds)))
    orb = cv2.ORB_create(nfeatures=700)
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    previous = None
    index = 0
    samples: list[dict[str, Any]] = []
    active_start: float | None = None
    active_peak = 0.0
    intervals: list[dict[str, Any]] = []

    while True:
        ok, frame = capture.read()
        if not ok:
            break
        if index % stride != 0:
            index += 1
            continue
        timestamp = index / fps
        height, width = frame.shape[:2]
        scale = min(1.0, 640.0 / max(width, 1))
        if scale < 1.0:
            frame = cv2.resize(frame, (int(width * scale), int(height * scale)))
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (5, 5), 0)
        score = 0.0
        if previous is not None:
            kp1, desc1 = orb.detectAndCompute(previous, None)
            kp2, desc2 = orb.detectAndCompute(gray, None)
            aligned = gray
            if desc1 is not None and desc2 is not None and len(kp1) >= 8 and len(kp2) >= 8:
                matches = sorted(matcher.match(desc1, desc2), key=lambda match: match.distance)[:120]
                if len(matches) >= 8:
                    src = np.float32([kp2[m.trainIdx].pt for m in matches]).reshape(-1, 1, 2)
                    dst = np.float32([kp1[m.queryIdx].pt for m in matches]).reshape(-1, 1, 2)
                    matrix, _ = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC)
                    if matrix is not None:
                        aligned = cv2.warpAffine(gray, matrix, (previous.shape[1], previous.shape[0]))
            diff = cv2.absdiff(previous, aligned)
            _, mask = cv2.threshold(diff, 28, 255, cv2.THRESH_BINARY)
            mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
            score = float(cv2.countNonZero(mask)) / float(mask.size)
        samples.append({"time": timestamp, "score": score})
        active = score >= 0.025
        if active and active_start is None:
            active_start = timestamp
            active_peak = score
        elif active:
            active_peak = max(active_peak, score)
        elif active_start is not None:
            intervals.append({
                "start": active_start,
                "end": timestamp + sample_seconds,
                "label": "compensated-motion",
                "confidence": min(1.0, active_peak / 0.15),
            })
            active_start = None
            active_peak = 0.0
        previous = gray
        index += 1

    if active_start is not None:
        intervals.append({
            "start": active_start,
            "end": index / fps,
            "label": "compensated-motion",
            "confidence": min(1.0, active_peak / 0.15),
        })
    capture.release()
    json_dump(work_dir / "motion-samples.json", samples)
    json_dump(work_dir / "motion-intervals.json", intervals)
    return intervals


def detect_objects(
    source: Path,
    work_dir: Path,
    model_name: str,
    device: str,
    fps: float,
    stride: int,
) -> list[dict[str, Any]]:
    from ultralytics import YOLO

    model = YOLO(model_name)
    results = model.track(
        source=str(source),
        stream=True,
        persist=True,
        tracker="botsort.yaml",
        device=0 if device == "cuda" else "cpu",
        vid_stride=max(1, stride),
        conf=0.25,
        iou=0.5,
        verbose=False,
        save=False,
    )
    detections_path = work_dir / "objects.jsonl"
    detections_path.unlink(missing_ok=True)
    events: list[dict[str, Any]] = []
    last_seen: dict[tuple[str, int], float] = {}
    with detections_path.open("a", encoding="utf-8") as output:
        for result_index, result in enumerate(results):
            timestamp = result_index * max(1, stride) / max(fps, 1.0)
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
                        "end": timestamp + 1.5,
                        "kind": "object",
                        "label": label,
                        "confidence": float(confidence),
                        "metadata": record,
                    })
                    last_seen[key] = timestamp
    del model
    with contextlib.suppress(Exception):
        import torch
        torch.cuda.empty_cache()
    return events


def add_events(conn: sqlite3.Connection, media_id: int, events: Iterable[dict[str, Any]]) -> None:
    rows = []
    for event in events:
        rows.append((
            media_id,
            float(event["start"]),
            float(event["end"]),
            str(event.get("kind", "analysis")),
            str(event.get("label", "event")),
            event.get("confidence"),
            json.dumps(event.get("metadata", {}), ensure_ascii=False),
        ))
    conn.executemany(
        "INSERT INTO events(media_id, start, end, kind, label, confidence, metadata_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
        rows,
    )


def add_transcript(conn: sqlite3.Connection, media_id: int, segments: Iterable[dict[str, Any]]) -> None:
    rows = []
    for segment in segments:
        confidence = None
        if segment.get("words"):
            probabilities = [w.get("probability") for w in segment["words"] if w.get("probability") is not None]
            if probabilities:
                confidence = sum(probabilities) / len(probabilities)
        rows.append((
            media_id,
            float(segment["start"]),
            float(segment["end"]),
            str(segment["text"]),
            confidence,
            segment.get("speaker"),
            segment.get("sentiment_label"),
            segment.get("sentiment_score"),
        ))
    conn.executemany(
        """
        INSERT INTO transcript(media_id, start, end, text, confidence, speaker, sentiment_label, sentiment_score)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        rows,
    )


def merge_review_intervals(events: list[dict[str, Any]], duration: float) -> list[dict[str, Any]]:
    intervals = []
    for event in events:
        start = max(0.0, float(event["start"]) - 5.0)
        end = min(duration, float(event["end"]) + 8.0) if duration else float(event["end"]) + 8.0
        intervals.append({"start": start, "end": max(start, end), "reasons": [event.get("label", "event")]})
    intervals.sort(key=lambda item: item["start"])
    merged: list[dict[str, Any]] = []
    for interval in intervals:
        if not merged or interval["start"] > merged[-1]["end"] + 10.0:
            merged.append(interval)
        else:
            merged[-1]["end"] = max(merged[-1]["end"], interval["end"])
            merged[-1]["reasons"] = sorted(set(merged[-1]["reasons"] + interval["reasons"]))
    return merged


def discover(source_dir: Path) -> list[Path]:
    return sorted(
        path.resolve()
        for path in source_dir.rglob("*")
        if path.is_file() and path.suffix.lower() in MEDIA_EXTENSIONS
    )


def package_versions() -> dict[str, str]:
    versions: dict[str, str] = {}
    try:
        from importlib.metadata import version
        for package in [
            "faster-whisper", "ctranslate2", "ultralytics", "torch", "torchvision",
            "opencv-python-headless", "scenedetect", "transformers", "python-vlc", "PySide6",
            "pyannote.audio",
        ]:
            with contextlib.suppress(Exception):
                versions[package] = version(package)
    except Exception:
        pass
    return versions


def system_manifest() -> dict[str, Any]:
    manifest: dict[str, Any] = {
        "created_at": now_iso(),
        "python": sys.version,
        "platform": sys.platform,
        "packages": package_versions(),
    }
    for name, command in {
        "ffmpeg": ["ffmpeg", "-version"],
        "ffprobe": ["ffprobe", "-version"],
        "vlc": ["vlc", "--version"],
        "nvidia_smi": ["nvidia-smi"],
    }.items():
        try:
            result = run(command, capture=True, check=False)
            manifest[name] = (result.stdout or result.stderr).splitlines()[:20]
        except Exception as error:
            manifest[name] = {"error": str(error)}
    return manifest


def gpu_device() -> tuple[str, str]:
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda", "float16"
    except Exception:
        pass
    return "cpu", "int8"


def process_media(
    conn: sqlite3.Connection,
    source: Path,
    derived: Path,
    args: argparse.Namespace,
    device: str,
    compute_type: str,
    hf_token: str | None,
) -> None:
    logging.info("Indexing %s", source)
    digest = sha256_file(source)
    probe = ffprobe(source)
    work_dir = derived / "items" / digest[:2] / digest
    work_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(work_dir, 0o700)

    existing = conn.execute(
        "SELECT id, sha256, status, size_bytes, mtime_ns FROM media WHERE source_path = ?",
        (str(source),),
    ).fetchone()
    stat = source.stat()
    if (
        existing and not args.force and existing["sha256"] == digest and existing["status"] == "complete"
        and existing["size_bytes"] == stat.st_size and existing["mtime_ns"] == stat.st_mtime_ns
    ):
        logging.info("Already complete; skipping %s", source)
        return

    media_id = upsert_media(conn, source, digest, probe, work_dir)
    manifest = {
        "source_path": str(source),
        "sha256": digest,
        "size_bytes": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "indexed_at": now_iso(),
        "ffprobe": probe,
        "analysis": {
            "whisper_model": args.whisper_model,
            "object_model": args.object_model,
            "device": device,
            "compute_type": compute_type,
            "object_stride": args.object_stride,
        },
    }
    json_dump(work_dir / "manifest.json", manifest)
    (work_dir / "source.sha256").write_text(f"{digest}  {source}\n", encoding="utf-8")

    all_events: list[dict[str, Any]] = []
    segments: list[dict[str, Any]] = []
    wav_path = work_dir / "audio-16k-mono.wav"

    if not args.skip_transcription or (args.diarize and hf_token):
        extract_audio(source, wav_path)

    if not args.skip_transcription:
        segments, _ = transcribe(wav_path, work_dir, args.whisper_model, device, compute_type)
        if not args.skip_sentiment and segments:
            try:
                apply_sentiment(segments, device)
            except Exception:
                logging.exception("Sentiment analysis failed; continuing")
        if args.diarize and hf_token:
            try:
                turns = diarize(wav_path, work_dir, hf_token, device)
                assign_speakers(segments, turns)
            except Exception:
                logging.exception("Speaker diarization failed; continuing")
        write_subtitles(work_dir, segments)
        add_transcript(conn, media_id, segments)
        all_events.extend({
            "start": segment["start"],
            "end": segment["end"],
            "kind": "speech",
            "label": "speech",
            "confidence": None,
            "metadata": {"text": segment["text"], "speaker": segment.get("speaker")},
        } for segment in segments)

    if video_stream(probe):
        if not args.skip_scenes:
            try:
                scenes = detect_scenes(source, work_dir)
                all_events.extend({
                    "start": scene["start"], "end": min(scene["start"] + 1.0, scene["end"]),
                    "kind": "scene", "label": "scene-change", "confidence": None,
                    "metadata": scene,
                } for scene in scenes[1:])
            except Exception:
                logging.exception("Scene detection failed; continuing")
        if not args.skip_motion:
            try:
                motion = compensated_motion(source, work_dir)
                all_events.extend({
                    "start": item["start"], "end": item["end"], "kind": "motion",
                    "label": item["label"], "confidence": item.get("confidence"), "metadata": item,
                } for item in motion)
            except Exception:
                logging.exception("Motion analysis failed; continuing")
        if not args.skip_objects:
            try:
                objects = detect_objects(
                    source, work_dir, args.object_model, device,
                    fps_from_probe(probe) or 30.0, args.object_stride,
                )
                all_events.extend(objects)
            except Exception:
                logging.exception("Object tracking failed; continuing")

    add_events(conn, media_id, all_events)
    review_intervals = merge_review_intervals(all_events, duration_from_probe(probe))
    json_dump(work_dir / "review-intervals.json", review_intervals)
    conn.execute("UPDATE media SET status='complete', error=NULL, indexed_at=? WHERE id=?", (now_iso(), media_id))
    conn.commit()
    logging.info("Complete %s", source)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local ophanim media transcription and vision indexer")
    parser.add_argument("--source", type=Path, default=Path(os.environ.get("OPHANIM_AV_SOURCE", ".")))
    parser.add_argument("--derived", type=Path, default=Path(os.environ.get("OPHANIM_AV_DERIVED", "./derived")))
    parser.add_argument("--whisper-model", default=os.environ.get("WHISPER_MODEL", "large-v3"))
    parser.add_argument("--object-model", default=os.environ.get("YOLO_MODEL", "yolo11s.pt"))
    parser.add_argument("--object-stride", type=int, default=int(os.environ.get("YOLO_STRIDE", "3")))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--skip-transcription", action="store_true")
    parser.add_argument("--skip-sentiment", action="store_true")
    parser.add_argument("--skip-objects", action="store_true")
    parser.add_argument("--skip-motion", action="store_true")
    parser.add_argument("--skip-scenes", action="store_true")
    parser.add_argument("--diarize", action="store_true", default=os.environ.get("ENABLE_DIARIZATION", "0") == "1")
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    source = args.source.expanduser().resolve()
    derived = args.derived.expanduser().resolve()
    if not source.is_dir():
        raise SystemExit(f"Source directory does not exist: {source}")
    derived.mkdir(parents=True, exist_ok=True)
    os.chmod(derived, 0o700)
    db_path = derived / "catalog.sqlite3"
    conn = init_db(db_path)
    json_dump(derived / "system-manifest.json", system_manifest())

    token_path = Path(os.environ.get("HF_TOKEN_FILE", "~/.config/ophanim-av/hf_token")).expanduser()
    hf_token = token_path.read_text(encoding="utf-8").strip() if token_path.is_file() else None
    if args.diarize and not hf_token:
        logging.warning("Diarization enabled but no token exists at %s; skipping diarization", token_path)

    device, compute_type = gpu_device()
    logging.info("Compute device: %s; Whisper compute type: %s", device, compute_type)
    paths = discover(source)
    if args.limit:
        paths = paths[:args.limit]
    logging.info("Discovered %d media files", len(paths))

    for path in paths:
        try:
            process_media(conn, path, derived, args, device, compute_type, hf_token)
        except KeyboardInterrupt:
            raise
        except Exception as error:
            logging.error("Failed %s: %s", path, error)
            logging.debug("%s", traceback.format_exc())
            with contextlib.suppress(Exception):
                conn.execute(
                    "UPDATE media SET status='failed', error=?, indexed_at=? WHERE source_path=?",
                    (f"{type(error).__name__}: {error}", now_iso(), str(path)),
                )
                conn.commit()
    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY_INDEXER

cat > "$APP_DIR/player.py" <<'PY_PLAYER'
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sqlite3
import sys
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
    QVBoxLayout,
    QWidget,
)

START_ROLE = Qt.ItemDataRole.UserRole
MEDIA_ROLE = Qt.ItemDataRole.UserRole + 1


def format_time(seconds: float) -> str:
    value = max(0, int(seconds))
    hours, remainder = divmod(value, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours:02}:{minutes:02}:{secs:02}"


class OphanimAVPlayer(QMainWindow):
    def __init__(self, db_path: Path) -> None:
        super().__init__()
        self.db_path = db_path
        self.conn = sqlite3.connect(db_path)
        self.conn.row_factory = sqlite3.Row
        self.current_media_id: int | None = None
        self.current_path: Path | None = None
        self.review_intervals: list[dict] = []
        self.seeking = False

        self.vlc_instance = vlc.Instance("--no-video-title-show", "--quiet")
        self.player = self.vlc_instance.media_player_new()

        self.setWindowTitle("OphanimAV Review Player")
        self.resize(1600, 950)
        self._build_ui()
        self._load_media_list()

        self.timer = QTimer(self)
        self.timer.setInterval(250)
        self.timer.timeout.connect(self._tick)
        self.timer.start()

    def _build_ui(self) -> None:
        menu = self.menuBar().addMenu("File")
        open_dir = QAction("Open source directory", self)
        open_dir.triggered.connect(self._open_source_directory)
        menu.addAction(open_dir)

        root = QWidget(self)
        root_layout = QHBoxLayout(root)
        splitter = QSplitter(Qt.Orientation.Horizontal)
        root_layout.addWidget(splitter)
        self.setCentralWidget(root)

        left = QWidget()
        left_layout = QVBoxLayout(left)
        left_layout.addWidget(QLabel("Indexed media"))
        self.media_search = QLineEdit()
        self.media_search.setPlaceholderText("Filter files")
        self.media_search.textChanged.connect(self._filter_media)
        left_layout.addWidget(self.media_search)
        self.media_list = QListWidget()
        self.media_list.itemDoubleClicked.connect(self._open_media_item)
        left_layout.addWidget(self.media_list)
        splitter.addWidget(left)

        center = QWidget()
        center_layout = QVBoxLayout(center)
        self.video_frame = QFrame()
        self.video_frame.setFrameShape(QFrame.Shape.Box)
        self.video_frame.setStyleSheet("background: black;")
        self.video_frame.setMinimumSize(720, 405)
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
        for label, value in [("0.5x", 0.5), ("1.0x", 1.0), ("1.5x", 1.5), ("2.0x", 2.0), ("3.0x", 3.0), ("4.0x", 4.0)]:
            self.rate.addItem(label, value)
        self.rate.setCurrentText("1.0x")
        self.rate.currentIndexChanged.connect(self._set_rate)
        controls.addWidget(self.rate)
        self.auto_skip = QCheckBox("Auto-skip inactive")
        controls.addWidget(self.auto_skip)
        center_layout.addLayout(controls)
        splitter.addWidget(center)

        right = QWidget()
        right_layout = QVBoxLayout(right)
        right_layout.addWidget(QLabel("Transcript search"))
        self.transcript_search = QLineEdit()
        self.transcript_search.setPlaceholderText("Search transcript")
        self.transcript_search.textChanged.connect(self._filter_transcript)
        right_layout.addWidget(self.transcript_search)
        right_layout.addWidget(QLabel("Transcript"))
        self.transcript_list = QListWidget()
        self.transcript_list.itemClicked.connect(self._seek_from_item)
        right_layout.addWidget(self.transcript_list, 2)
        right_layout.addWidget(QLabel("Analysis events"))
        self.event_list = QListWidget()
        self.event_list.itemClicked.connect(self._seek_from_item)
        right_layout.addWidget(self.event_list, 1)
        splitter.addWidget(right)

        splitter.setSizes([300, 950, 450])

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

    def _load_media_list(self) -> None:
        self.media_list.clear()
        rows = self.conn.execute(
            "SELECT id, source_path, status, duration FROM media ORDER BY source_path"
        ).fetchall()
        for row in rows:
            path = Path(row["source_path"])
            item = QListWidgetItem(f"[{row['status']}] {path.name}\n{path.parent}")
            item.setData(MEDIA_ROLE, int(row["id"]))
            item.setToolTip(str(path))
            self.media_list.addItem(item)

    def _filter_media(self, text: str) -> None:
        query = text.casefold().strip()
        for index in range(self.media_list.count()):
            item = self.media_list.item(index)
            item.setHidden(query not in item.text().casefold())

    def _open_media_item(self, item: QListWidgetItem) -> None:
        media_id = int(item.data(MEDIA_ROLE))
        row = self.conn.execute("SELECT * FROM media WHERE id=?", (media_id,)).fetchone()
        if not row:
            return
        path = Path(row["source_path"])
        if not path.is_file():
            QMessageBox.critical(self, "Missing file", f"Source file no longer exists:\n{path}")
            return
        self.current_media_id = media_id
        self.current_path = path
        media = self.vlc_instance.media_new(str(path))
        subtitle = Path(row["work_dir"]) / "transcript.srt"
        if subtitle.is_file():
            media.add_option(f":sub-file={subtitle}")
        self.player.set_media(media)
        self._attach_video_output()
        self.player.play()
        self.play_button.setText("Pause")
        self._load_transcript(media_id)
        self._load_events(media_id)
        review_path = Path(row["work_dir"]) / "review-intervals.json"
        try:
            self.review_intervals = json.loads(review_path.read_text(encoding="utf-8")) if review_path.is_file() else []
        except Exception:
            self.review_intervals = []
        self.setWindowTitle(f"OphanimAV Review Player; {path.name}")

    def _load_transcript(self, media_id: int) -> None:
        self.transcript_list.clear()
        rows = self.conn.execute(
            """
            SELECT start, end, text, speaker, sentiment_label, sentiment_score
            FROM transcript WHERE media_id=? ORDER BY start
            """,
            (media_id,),
        ).fetchall()
        for row in rows:
            prefix = f"[{format_time(row['start'])}]"
            if row["speaker"]:
                prefix += f" {row['speaker']}"
            suffix = ""
            if row["sentiment_label"]:
                suffix = f"  [{row['sentiment_label']} {row['sentiment_score']:.2f}]"
            item = QListWidgetItem(f"{prefix} {row['text']}{suffix}")
            item.setData(START_ROLE, float(row["start"]))
            self.transcript_list.addItem(item)

    def _load_events(self, media_id: int) -> None:
        self.event_list.clear()
        rows = self.conn.execute(
            "SELECT start, end, kind, label, confidence FROM events WHERE media_id=? ORDER BY start",
            (media_id,),
        ).fetchall()
        for row in rows:
            confidence = "" if row["confidence"] is None else f" {row['confidence']:.2f}"
            item = QListWidgetItem(
                f"[{format_time(row['start'])}] {row['kind']}; {row['label']}{confidence}"
            )
            item.setData(START_ROLE, float(row["start"]))
            self.event_list.addItem(item)

    def _filter_transcript(self, text: str) -> None:
        query = text.casefold().strip()
        for index in range(self.transcript_list.count()):
            item = self.transcript_list.item(index)
            item.setHidden(query not in item.text().casefold())

    def _seek_from_item(self, item: QListWidgetItem) -> None:
        start = float(item.data(START_ROLE) or 0.0)
        self.player.set_time(int(start * 1000))

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
        value = float(self.rate.currentData() or 1.0)
        self.player.set_rate(value)

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

    def _auto_skip(self, current: float) -> None:
        for interval in self.review_intervals:
            if interval["start"] <= current <= interval["end"]:
                return
            if interval["start"] > current:
                self.player.set_time(int(interval["start"] * 1000))
                return

    def _open_source_directory(self) -> None:
        if self.current_path:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.current_path.parent)))

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

chmod 700 "$APP_DIR/ophanim_av.py" "$APP_DIR/player.py"

cat > "$CONFIG_DIR/config.env" <<EOF_CONFIG
OPHANIM_AV_SOURCE="$SOURCE_DIR"
OPHANIM_AV_DERIVED="$DERIVED_DIR"
WHISPER_MODEL="large-v3"
YOLO_MODEL="yolo11s.pt"
YOLO_STRIDE="3"
ENABLE_DIARIZATION="0"
HF_TOKEN_FILE="$CONFIG_DIR/hf_token"
EOF_CONFIG
chmod 600 "$CONFIG_DIR/config.env"
touch "$CONFIG_DIR/hf_token"
chmod 600 "$CONFIG_DIR/hf_token"

cat > "$APP_DIR/runtime-env.sh" <<EOF_RUNTIME
#!/usr/bin/env bash
set -Eeuo pipefail
source "$CONFIG_DIR/config.env"
export PATH="$VENV_DIR/bin:\$PATH"
export PYTHONNOUSERSITE=1
export PYTHONUNBUFFERED=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export PYANNOTE_METRICS_ENABLED=0
export TOKENIZERS_PARALLELISM=false
export HF_HOME="\$OPHANIM_AV_DERIVED/cache/huggingface"
export TORCH_HOME="\$OPHANIM_AV_DERIVED/cache/torch"
export YOLO_CONFIG_DIR="\$OPHANIM_AV_DERIVED/cache/ultralytics"
mkdir -p "\$HF_HOME" "\$TORCH_HOME" "\$YOLO_CONFIG_DIR"
CUDA_PY_LIBS="\$("$VENV_DIR/bin/python" - <<'PY_CUDA_LIBS'
import site
from pathlib import Path
paths = []
for root in map(Path, site.getsitepackages()):
    for pattern in ("nvidia/*/lib", "nvidia/*/lib64"):
        paths.extend(str(path) for path in root.glob(pattern) if path.is_dir())
print(":".join(paths))
PY_CUDA_LIBS
)"
if [[ -n "\$CUDA_PY_LIBS" ]]; then
    export LD_LIBRARY_PATH="\$CUDA_PY_LIBS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
fi
EOF_RUNTIME
chmod 700 "$APP_DIR/runtime-env.sh"

printf '[6/9] Installing user commands...\n'
cat > "$BIN_DIR/ophanim-index" <<EOF_INDEX
#!/usr/bin/env bash
set -Eeuo pipefail
source "$APP_DIR/runtime-env.sh"
mkdir -p "$STATE_DIR"
exec flock -n "$STATE_DIR/index.lock" \
    "$VENV_DIR/bin/python" "$APP_DIR/ophanim_av.py" \
    --source "\$OPHANIM_AV_SOURCE" \
    --derived "\$OPHANIM_AV_DERIVED" \
    "\$@"
EOF_INDEX

cat > "$BIN_DIR/ophanim-player" <<EOF_PLAYER
#!/usr/bin/env bash
set -Eeuo pipefail
source "$APP_DIR/runtime-env.sh"
export QT_QPA_PLATFORM=xcb
exec "$VENV_DIR/bin/python" "$APP_DIR/player.py" "\$@"
EOF_PLAYER

cat > "$BIN_DIR/ophanim-status" <<EOF_STATUS
#!/usr/bin/env bash
set -Eeuo pipefail
source "$APP_DIR/runtime-env.sh"
printf 'Service status:\n'
systemctl --user --no-pager status ophanim-av-index.service || true
printf '\nTimer status:\n'
systemctl --user --no-pager status ophanim-av-index.timer || true
printf '\nCatalog summary:\n'
if [[ -f "\$OPHANIM_AV_DERIVED/catalog.sqlite3" ]]; then
    sqlite3 -header -column "\$OPHANIM_AV_DERIVED/catalog.sqlite3" \
        "SELECT status, COUNT(*) AS files, ROUND(SUM(duration)/3600.0,2) AS hours FROM media GROUP BY status ORDER BY status;"
else
    printf 'No catalog exists yet.\n'
fi
printf '\nRecent journal:\n'
journalctl --user-unit=ophanim-av-index.service -n 30 --no-pager || true
EOF_STATUS

cat > "$BIN_DIR/ophanim-log" <<'EOF_LOG'
#!/usr/bin/env bash
exec journalctl --user-unit=ophanim-av-index.service -f -o cat
EOF_LOG

chmod 700 "$BIN_DIR/ophanim-index" "$BIN_DIR/ophanim-player" "$BIN_DIR/ophanim-status" "$BIN_DIR/ophanim-log"

printf '[7/9] Creating the recurring systemd user workflow...\n'
cat > "$SYSTEMD_DIR/ophanim-av-index.service" <<EOF_SERVICE
[Unit]
Description=Local OphanimAV transcription, motion, scene, object and sentiment indexer
ConditionPathIsDirectory=$SOURCE_DIR

[Service]
Type=oneshot
EnvironmentFile=$CONFIG_DIR/config.env
ExecStart=$BIN_DIR/ophanim-index
WorkingDirectory=$APP_DIR
UMask=0077
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
NoNewPrivileges=true
PrivateTmp=true
TimeoutStartSec=infinity

[Install]
WantedBy=default.target
EOF_SERVICE

cat > "$SYSTEMD_DIR/ophanim-av-index.timer" <<'EOF_TIMER'
[Unit]
Description=Re-index BODYCAM media every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
AccuracySec=2min
Persistent=true
Unit=ophanim-av-index.service

[Install]
WantedBy=timers.target
EOF_TIMER

systemctl --user daemon-reload
systemctl --user enable --now ophanim-av-index.timer

printf '[8/9] Creating the KDE application launcher...\n'
cat > "$DESKTOP_DIR/ophanim-av-player.desktop" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=OphanimAV Review Player
Comment=Review locally indexed media, transcripts and detected events
Exec=$BIN_DIR/ophanim-player
Icon=vlc
Terminal=false
Categories=AudioVideo;Utility;
StartupNotify=true
EOF_DESKTOP
chmod 600 "$DESKTOP_DIR/ophanim-av-player.desktop"
update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true

printf '[9/9] Running compatibility checks...\n'
source "$APP_DIR/runtime-env.sh"
"$VENV_DIR/bin/python" - <<'PY_SMOKE'
import cv2
import torch
import vlc
from faster_whisper import WhisperModel
from scenedetect import AdaptiveDetector
from ultralytics import YOLO
from PySide6 import QtCore
print("Python imports: OK")
print("PyTorch:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("CUDA device:", torch.cuda.get_device_name(0))
print("OpenCV:", cv2.__version__)
print("Qt:", QtCore.qVersion())
print("libVLC:", vlc.libvlc_get_version().decode())
PY_SMOKE

if [[ "$RUN_NOW" == "1" && -d "$SOURCE_DIR" ]]; then
    systemctl --user start --no-block ophanim-av-index.service
    printf '\nIndexing was started in the background.\n'
else
    printf '\nIndexing was not started automatically.\n'
fi

cat <<EOF_DONE

Installed commands:
  ophanim-status       Show service, timer and catalog status
  ophanim-log          Follow indexing output
  ophanim-index        Run or resume indexing manually
  ophanim-player       Open the indexed VLC review player

Source:
  $SOURCE_DIR

Derived results; originals are not modified:
  $DERIVED_DIR

Speaker diarization is installed but remains disabled until the gated pyannote model is approved.
After approval, place the Hugging Face token in:
  $CONFIG_DIR/hf_token
Then change ENABLE_DIARIZATION="0" to "1" in:
  $CONFIG_DIR/config.env

Review progress now with:
  ophanim-log
EOF_DONE
