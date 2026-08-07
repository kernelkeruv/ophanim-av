#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(realpath -e "$ROOT")"

python3 - "$ROOT" <<'PY_PRIVACY'
from __future__ import annotations

import re
import sys
from pathlib import Path

root = Path(sys.argv[1])

blocked_extensions = {
    ".aac", ".aax", ".avi", ".db", ".engine", ".flac", ".jsonl",
    ".m2ts", ".m4a", ".m4v", ".mkv", ".mov", ".mp3", ".mp4", ".mts",
    ".ogg", ".onnx", ".opus", ".pt", ".pth", ".safetensors", ".sqlite",
    ".sqlite3", ".srt", ".ts", ".vtt", ".wav", ".webm", ".wma",
}

blocked_names = {
    "catalog.sqlite3",
    "config.env",
    "hf_token",
    "intake-sources.json",
    "system-manifest.json",
}

ignored_parts = {
    ".git",
    ".venv",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    "dist",
    "build",
    "Output",
}

secret_patterns = {
    "private key": re.compile(
        r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"
    ),
    "GitHub token": re.compile(
        r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"
    ),
    "Hugging Face token": re.compile(r"\bhf_[A-Za-z0-9]{20,}\b"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "credential assignment": re.compile(
        r"(?i)\b(?:password|passwd|api[_-]?key|access[_-]?token|"
        r"auth[_-]?token|client[_-]?secret)\b"
        r"\s*[:=]\s*['\"][^'\"\n]{8,}['\"]"
    ),
}

personal_markers = [
    "klaw" + "-yer",
    "SILICON" + "-SERAPHIM",
    "PR0WL3R" + "-SH3LL",
    "GN007447" + "TR88",
    "341c0046aede474d" + "af4628f1beee1ca0",
    "1206 Dot" + " Ave",
    "3635 Wildwood" + " Dr",
    "gturner8" + "@uwo.ca",
    "519-567" + "-0739",
    "(519) 567" + "-0739",
]

def approved_binary(relative_text: str) -> bool:
    if relative_text in {
        "assets/ophanimav.png",
        "assets/ophanimav.ico",
    }:
        return True

    return (
        relative_text.startswith("assets/icons/hicolor/")
        and relative_text.endswith("/apps/ophanimav.png")
    )

problems: list[str] = []

for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue

    relative = path.relative_to(root)

    if any(part in ignored_parts for part in relative.parts):
        continue

    relative_text = relative.as_posix()

    # This scanner necessarily contains its own detection signatures.
    if relative_text == "scripts/privacy-check.sh":
        continue

    if path.name in blocked_names or path.suffix.lower() in blocked_extensions:
        problems.append(f"blocked evidence or model file: {relative_text}")
        continue

    size = path.stat().st_size

    if approved_binary(relative_text):
        if size > 4 * 1024 * 1024:
            problems.append(
                f"approved branding file exceeds 4 MiB: "
                f"{relative_text} ({size} bytes)"
            )
        continue

    if size > 2 * 1024 * 1024:
        problems.append(
            f"file exceeds 2 MiB allowlist limit: "
            f"{relative_text} ({size} bytes)"
        )
        continue

    data = path.read_bytes()

    if b"\x00" in data:
        problems.append(f"binary file is not permitted: {relative_text}")
        continue

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        problems.append(f"non-UTF-8 file is not permitted: {relative_text}")
        continue

    for label, pattern in secret_patterns.items():
        if pattern.search(text):
            problems.append(f"possible {label}: {relative_text}")

    for marker in personal_markers:
        if marker.casefold() in text.casefold():
            problems.append(
                f"machine-specific or personal marker "
                f"'{marker}': {relative_text}"
            )

if problems:
    print("PRIVACY CHECK FAILED", file=sys.stderr)
    for problem in sorted(set(problems)):
        print(f"  {problem}", file=sys.stderr)
    raise SystemExit(1)

print("PRIVACY CHECK PASSED")
PY_PRIVACY
