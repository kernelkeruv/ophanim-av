# BODYCAM AI Reviewer

A local-first media review application built around libVLC, Faster-Whisper, PySide6, OpenCV and Ultralytics. It indexes audio and video, creates timed transcripts, provides clickable word seeking, detects scenes, motion and objects, and preserves original media as read-only input.

## Privacy boundary

This repository contains source code and deployment templates only. It intentionally excludes original media, captions, transcripts, SQLite catalogs, analysis output, thumbnails, model weights, caches, logs, access tokens and machine-specific configuration.

## Repository layout

- `src/bodycam_ai.py`; indexing, transcription and analysis pipeline.
- `src/player.py`; PySide6 and libVLC review interface.
- `scripts/install-bodycam-ai.sh`; Fedora-oriented installer snapshot, when available.
- `scripts/launchers/`; user command wrappers.
- `scripts/upgrades/`; migration and repair scripts.
- `systemd/`; user service and timer templates.
- `config/config.env.example`; generic configuration example.
- `scripts/privacy-check.sh`; pre-push repository privacy guard.

## Configuration

Copy `config/config.env.example` into your local configuration directory and replace the placeholder paths. Never commit the real configuration, Hugging Face token, media, derived output or SQLite catalog.

## Status

This is an exported snapshot of a working local installation. Review dependency licensing and installation assumptions before publishing the repository publicly or distributing binaries.
