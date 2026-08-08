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
import time
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


def elapsed_seconds(start: float) -> float:
    return round(max(0.0, time.perf_counter() - start), 3)


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
        CREATE TABLE IF NOT EXISTS media_aliases (
            source_path TEXT PRIMARY KEY,
            sha256 TEXT NOT NULL,
            media_id INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
            canonical_path TEXT NOT NULL,
            added_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_media_aliases_sha256 ON media_aliases(sha256);
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
    conn.execute("DELETE FROM transcript_words WHERE media_id = ?", (media_id,))
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


def _wav_metrics(wav_path: Path) -> tuple[float, float]:
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
        {"start": start.seconds, "end": end.seconds, "label": "scene"}
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
    """Track objects and create a review proxy with synchronized boxes and motion state."""
    import cv2
    from ultralytics import YOLO
    from yolo_auto import resolve

    force_cpu = model_name.startswith("cpu::")
    if force_cpu:
        model_name = model_name[5:]
    yolo_runtime = resolve(model_name, force_device="cpu" if force_cpu else None)
    selected = yolo_runtime["selected"]
    model_name = selected["model_path"]
    yolo_device = selected["device"]
    logging.info("YOLO runtime: model=%s device=%s policy=%s latency=%s ms", selected["model"], yolo_device, yolo_runtime["policy"], selected.get("latency_ms_640"))
    json_dump(work_dir / "yolo-runtime.json", yolo_runtime)

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
        device=yolo_device,
        vid_stride=stride,
        imgsz=int(os.environ.get("YOLO_IMGSZ", "640")),
        quantize=(16 if yolo_device not in {"cpu", "mps"} and os.environ.get("YOLO_FP16", "1") == "1" else None),
        channels_last=(yolo_device not in {"cpu", "mps"} and os.environ.get("YOLO_CHANNELS_LAST", "1") == "1"),
        batch=1,
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
        results = None
        model = None
        _release_cuda()

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


def add_transcript_words(
    conn: sqlite3.Connection,
    media_id: int,
    segments: Iterable[dict[str, Any]],
) -> None:
    rows = []
    for segment in segments:
        segment_start = float(segment["start"])
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
    candidates: list[Path] = []
    if source_dir.is_file() and source_dir.suffix.lower() in MEDIA_EXTENSIONS:
        candidates.append(source_dir)
    elif source_dir.is_dir():
        candidates.extend(
            path
            for path in source_dir.rglob("*")
            if path.is_file() and path.suffix.lower() in MEDIA_EXTENSIONS
        )

    derived_value = os.environ.get("OPHANIM_AV_DERIVED", "").strip()
    if derived_value:
        registry_path = Path(derived_value).expanduser() / "intake-sources.json"
        if registry_path.is_file():
            try:
                registry = json.loads(registry_path.read_text(encoding="utf-8"))
                for entry in registry if isinstance(registry, list) else []:
                    raw_path = entry.get("path") if isinstance(entry, dict) else None
                    if not raw_path:
                        continue
                    candidate = Path(str(raw_path)).expanduser()
                    if candidate.is_file() and candidate.suffix.lower() in MEDIA_EXTENSIONS:
                        candidates.append(candidate)
            except Exception as error:
                logging.warning("Could not read intake registry %s: %s", registry_path, error)

    unique: dict[str, Path] = {}
    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        unique[str(resolved)] = resolved
    return sorted(unique.values(), key=lambda item: str(item).casefold())


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
            return "cuda", os.environ.get("WHISPER_COMPUTE_TYPE", "int8_float16")
    except Exception:
        pass
    return "cpu", os.environ.get("WHISPER_CPU_COMPUTE_TYPE", "int8")


def process_media(
    conn: sqlite3.Connection,
    source: Path,
    derived: Path,
    args: argparse.Namespace,
    device: str,
    compute_type: str,
    hf_token: str | None,
) -> None:
    media_started_at = time.perf_counter()
    logging.info("Indexing %s", source)
    digest = sha256_file(source)
    duplicate = conn.execute(
        """
        SELECT id, source_path, status
        FROM media
        WHERE sha256=? AND source_path<>?
        ORDER BY CASE status
            WHEN 'complete' THEN 0
            WHEN 'processing' THEN 1
            WHEN 'failed' THEN 2
            ELSE 3
        END, id
        LIMIT 1
        """,
        (digest, str(source)),
    ).fetchone()
    if duplicate and not args.force:
        conn.execute(
            """
            INSERT INTO media_aliases(source_path, sha256, media_id, canonical_path, added_at)
            VALUES(?,?,?,?,?)
            ON CONFLICT(source_path) DO UPDATE SET
                sha256=excluded.sha256,
                media_id=excluded.media_id,
                canonical_path=excluded.canonical_path,
                added_at=excluded.added_at
            """,
            (str(source), digest, int(duplicate["id"]), str(duplicate["source_path"]), now_iso()),
        )
        conn.commit()
        logging.info(
            "Duplicate SHA-256 already cataloged; skipping %s; canonical source is %s",
            source,
            duplicate["source_path"],
        )
        return
    probe = ffprobe(source)
    source_duration = duration_from_probe(probe)
    source_fps = fps_from_probe(probe) or 30.0
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
            "source_fps": source_fps,
            "source_duration": source_duration,
        },
    }
    json_dump(work_dir / "manifest.json", manifest)
    (work_dir / "source.sha256").write_text(f"{digest}  {source}\n", encoding="utf-8")

    all_events: list[dict[str, Any]] = []
    segments: list[dict[str, Any]] = []
    wav_path = work_dir / "audio-16k-mono.wav"
    performance: dict[str, Any] = {"stages": {}}

    def stage(name: str, func, *stage_args, **stage_kwargs):
        started = time.perf_counter()
        try:
            return func(*stage_args, **stage_kwargs)
        finally:
            performance["stages"][name] = elapsed_seconds(started)

    if not args.skip_transcription:
        stage("extract_audio", extract_audio, source, wav_path)

    if not args.skip_transcription:
        try:
            segments, _ = stage(
                "transcribe",
                transcribe,
                wav_path, work_dir, args.whisper_model, device, compute_type
            )
        except Exception as error:
            if device == "cuda" and "out of memory" in str(error).lower():
                logging.warning(
                    "Whisper CUDA OOM; retrying this file on CPU with int8"
                )
                _release_cuda()
                segments, _ = stage(
                    "transcribe_cpu_fallback",
                    transcribe,
                    wav_path, work_dir, args.whisper_model, "cpu", "int8"
                )
            else:
                raise
        if not args.skip_sentiment and segments:
            try:
                stage("sentiment", apply_sentiment, segments, device)
            except Exception:
                logging.exception("Sentiment analysis failed; continuing")
        if args.diarize and hf_token:
            try:
                turns = stage("diarize", diarize, wav_path, work_dir, hf_token, device)
                assign_speakers(segments, turns)
            except Exception:
                logging.exception("Speaker diarization failed; continuing")
        stage("write_subtitles", write_subtitles, work_dir, segments)
        add_transcript(conn, media_id, segments)
        add_transcript_words(conn, media_id, segments)
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
                scenes = stage("detect_scenes", detect_scenes, source, work_dir)
                all_events.extend({
                    "start": scene["start"], "end": min(scene["start"] + 1.0, scene["end"]),
                    "kind": "scene", "label": "scene-change", "confidence": None,
                    "metadata": scene,
                } for scene in scenes[1:])
            except Exception:
                logging.exception("Scene detection failed; continuing")
        if not args.skip_motion:
            try:
                motion = stage("detect_motion", compensated_motion, source, work_dir)
                all_events.extend({
                    "start": item["start"], "end": item["end"], "kind": "motion",
                    "label": item["label"], "confidence": item.get("confidence"), "metadata": item,
                } for item in motion)
            except Exception:
                logging.exception("Motion analysis failed; continuing")
        if not args.skip_objects:
            try:
                objects = stage(
                    "detect_objects",
                    detect_objects,
                    source, work_dir, args.object_model, device,
                    source_fps, args.object_stride,
                )
                all_events.extend(objects)
            except Exception as error:
                if device == "cuda" and "out of memory" in str(error).lower():
                    logging.warning(
                        "Object tracking CUDA OOM; retrying this file on CPU"
                    )
                    _release_cuda()
                    try:
                        objects = stage(
                            "detect_objects_cpu_fallback",
                            detect_objects,
                            source, work_dir, f"cpu::{args.object_model}", "cpu",
                            source_fps, args.object_stride,
                        )
                        all_events.extend(objects)
                    except Exception:
                        logging.exception("CPU object tracking fallback failed; continuing")
                else:
                    logging.exception("Object tracking failed; continuing")

    stage("add_events", add_events, conn, media_id, all_events)
    review_intervals = merge_review_intervals(all_events, source_duration)
    json_dump(work_dir / "review-intervals.json", review_intervals)
    performance["segments"] = len(segments)
    performance["events"] = len(all_events)
    performance["source_fps"] = source_fps
    performance["source_duration"] = source_duration
    performance["total"] = elapsed_seconds(media_started_at)
    manifest["analysis"]["performance"] = performance
    json_dump(work_dir / "performance-metrics.json", performance)
    json_dump(work_dir / "manifest.json", manifest)
    conn.execute("UPDATE media SET status='complete', error=NULL, indexed_at=? WHERE id=?", (now_iso(), media_id))
    conn.commit()
    logging.info("Complete %s", source)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local ophanim media transcription and vision indexer")
    parser.add_argument("--source", type=Path, default=Path(os.environ.get("OPHANIM_AV_SOURCE", ".")))
    parser.add_argument("--derived", type=Path, default=Path(os.environ.get("OPHANIM_AV_DERIVED", "./derived")))
    parser.add_argument("--whisper-model", default=os.environ.get("WHISPER_MODEL", "large-v3"))
    parser.add_argument("--object-model", default=os.environ.get("YOLO_MODEL", "auto"))
    parser.add_argument("--object-stride", type=int, default=int(os.environ.get("YOLO_STRIDE", "3")))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument(
        "--retry-incomplete",
        action="store_true",
        help="Process only media currently marked failed, processing, or new",
    )
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

    hf_token = None
    if args.diarize:
        try:
            from huggingface_hub import get_token

            hf_token = get_token()
        except ImportError:
            logging.warning(
                "Diarization enabled but huggingface_hub is unavailable; skipping diarization"
            )
        if not hf_token:
            logging.warning(
                "Diarization enabled but huggingface_hub found no credential; skipping diarization"
            )

    device, compute_type = gpu_device()
    logging.info("Compute device: %s; Whisper compute type: %s", device, compute_type)
    paths = discover(source)
    if args.retry_incomplete:
        retry_paths = {
            str(row[0])
            for row in conn.execute(
                "SELECT source_path FROM media WHERE status IN ('failed', 'processing', 'new')"
            ).fetchall()
        }
        paths = [path for path in paths if str(path) in retry_paths]
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
