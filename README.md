# OphanimAV Reviewer


A local-first media review application built around libVLC, Faster-Whisper, PySide6, OpenCV and Ultralytics. It indexes audio and video, creates timed transcripts, provides clickable word seeking, detects scenes, motion and objects, and preserves original media as read-only input.

<img width="1600" height="900" alt="image" src="https://github.com/user-attachments/assets/7ae0bb96-e5f6-4ec6-8c31-77114bea4508" />

## Privacy boundary

This repository contains source code and deployment templates only. It intentionally excludes original media, captions, transcripts, SQLite catalogs, analysis output, thumbnails, model weights, caches, logs, access tokens and machine-specific configuration.

## Repository layout

- `src/ophanim_av.py`; indexing, transcription and analysis pipeline.
- `src/player.py`; PySide6 and libVLC review interface.
- `scripts/install-ophanim-av.sh`; Fedora-oriented installer snapshot, when available.
- `scripts/regenerate-icons.py`; rebuilds all distributed icon variants from one canonical source icon.
- `scripts/packaging/`; CI packaging scripts for Windows, Linux and macOS installers.
- `scripts/launchers/`; user command wrappers.
- `scripts/upgrades/`; migration and repair scripts.
- `systemd/`; user service and timer templates.
- `config/config.env.example`; generic configuration example.
- `scripts/privacy-check.sh`; pre-push repository privacy guard.

## Configuration

Copy `config/config.env.example` into your local configuration directory and replace the placeholder paths. Never commit the real configuration, Hugging Face token, media, derived output or SQLite catalog.

## Canonical icon source

`assets/ophanimav.png` is the canonical application icon. Regenerate all shipped icon variants from it with:

`python3 scripts/regenerate-icons.py`

## Status

This is an exported snapshot of a working local installation. Review dependency licensing and installation assumptions before publishing the repository publicly or distributing binaries.

## Build artifacts in CI

Installer generation is handled by `.github/workflows/package-artifacts.yml` with isolated platform jobs:

- Windows EXE and MSI artifacts.
- Linux DEB, RPM and Arch artifacts.
- macOS Intel and Apple Silicon DMG artifacts.

Each platform uploads artifacts independently so one platform failure does not stop other platform outputs.

## AV performance telemetry

Each indexed media item now writes `/performance-metrics.json` in its work directory with stage timing metrics (audio extraction, transcription, sentiment, scene/motion/object passes, and event persistence). Use these metrics as the baseline when tuning pipeline throughput.

## Optional Hugging Face integration

OphanimAV remains fully functional without a Hugging Face account. Authentication is optional and is delegated to `huggingface_hub`; OphanimAV does not maintain its own token file.

```bash
ophanim-models status
ophanim-models login
ophanim-models logout
ophanim-models current
ophanim-models search whisper
```

Local-first privacy remains the default. This integration does not upload source media, transcripts, frames, SQLite catalogs, thumbnails, embeddings, or derived analysis data.


## Hardware-aware YOLO26 vision

OphanimAV defaults to `YOLO_MODEL=auto`. `ophanim-yolo select` inspects CUDA VRAM, Apple MPS, system RAM and CPU capacity; it then smoke-tests the largest suitable YOLO26 model and falls back automatically.

```bash
ophanim-yolo profile
ophanim-yolo select --force --policy accuracy
ophanim-yolo status
```
