#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import html
import json
import os
import sqlite3
import subprocess
import sys
from bisect import bisect_right
from pathlib import Path

import vlc
from PySide6.QtCore import Qt, QThread, QTimer, QUrl, Signal
from PySide6.QtGui import QAction, QDesktopServices, QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFileDialog,
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


MEDIA_EXTENSIONS = {
    ".mp4", ".mkv", ".avi", ".mov", ".m4v", ".webm", ".mts", ".m2ts", ".ts",
    ".mp3", ".wav", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wma", ".aax",
}

STATUS_STYLES = {
    "complete": ("#1b5e20", "#ffffff"),
    "processing": ("#f9a825", "#111111"),
    "queued": ("#1565c0", "#ffffff"),
    "new": ("#546e7a", "#ffffff"),
    "failed": ("#b71c1c", "#ffffff"),
}


def sha256_file(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def load_registry(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, list):
            return [entry for entry in value if isinstance(entry, dict) and entry.get("path")]
    except Exception:
        return []
    return []


class MediaRowWidget(QWidget):
    def __init__(self, status: str, name: str, parent: str, duration: str) -> None:
        super().__init__()
        layout = QHBoxLayout(self)
        layout.setContentsMargins(4, 3, 4, 3)
        layout.setSpacing(8)
        pill = QLabel(status.upper())
        background, foreground = STATUS_STYLES.get(status, ("#455a64", "#ffffff"))
        pill.setAlignment(Qt.AlignmentFlag.AlignCenter)
        pill.setMinimumWidth(78)
        pill.setStyleSheet(
            f"QLabel {{ background: {background}; color: {foreground}; "
            "border-radius: 9px; padding: 3px 8px; font-weight: 700; }}"
        )
        layout.addWidget(pill, 0, Qt.AlignmentFlag.AlignTop)
        detail = QLabel(
            f"<b>{html.escape(name)}</b> &nbsp; {html.escape(duration)}"
            f"<br><span style='color:#9aa4af'>{html.escape(parent)}</span>"
        )
        detail.setWordWrap(True)
        detail.setTextFormat(Qt.TextFormat.RichText)
        detail.setStyleSheet("background: transparent;")
        layout.addWidget(detail, 1)


class ImportWorker(QThread):
    progress = Signal(int, int, str)
    completed = Signal(object)
    failed = Signal(str)

    def __init__(self, selections: list[str], db_path: Path, registry_path: Path) -> None:
        super().__init__()
        self.selections = selections
        self.db_path = db_path
        self.derived_dir = db_path.parent
        self.registry_path = self.derived_dir / "intake-sources.json"
        self.import_worker: ImportWorker | None = None
        self.registry_path = registry_path

    def run(self) -> None:
        try:
            candidates: list[Path] = []
            for raw in self.selections:
                selected = Path(raw).expanduser()
                if selected.is_file() and selected.suffix.lower() in MEDIA_EXTENSIONS:
                    candidates.append(selected.resolve())
                elif selected.is_dir():
                    candidates.extend(
                        path.resolve()
                        for path in selected.rglob("*")
                        if path.is_file() and path.suffix.lower() in MEDIA_EXTENSIONS
                    )
            unique_candidates = list(dict.fromkeys(candidates))
            registry = load_registry(self.registry_path)
            registry_paths = {str(Path(entry["path"]).expanduser().resolve()): entry for entry in registry}
            registry_hashes = {str(entry.get("sha256")): entry for entry in registry if entry.get("sha256")}

            conn = sqlite3.connect(self.db_path, timeout=30)
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT source_path, sha256, status FROM media"
            ).fetchall()
            aliases = []
            if sql_table_exists(conn, "media_aliases"):
                aliases = conn.execute(
                    "SELECT source_path, sha256, canonical_path FROM media_aliases"
                ).fetchall()
            conn.close()

            known_paths: dict[str, str] = {}
            known_hashes: dict[str, str] = {}
            for row in rows:
                try:
                    resolved = str(Path(row["source_path"]).expanduser().resolve())
                except Exception:
                    resolved = str(row["source_path"])
                known_paths[resolved] = f"catalog status {row['status']}"
                if row["sha256"]:
                    known_hashes[str(row["sha256"])] = str(row["source_path"])
            for row in aliases:
                known_paths[str(row["source_path"])] = "catalog alias"
                if row["sha256"]:
                    known_hashes[str(row["sha256"])] = str(row["canonical_path"])

            added: list[dict] = []
            already: list[dict] = []
            errors: list[dict] = []
            total = len(unique_candidates)
            for index, candidate in enumerate(unique_candidates, start=1):
                self.progress.emit(index, total, candidate.name)
                candidate_text = str(candidate)
                if candidate_text in registry_paths:
                    already.append({"path": candidate_text, "reason": "path already queued"})
                    continue
                if candidate_text in known_paths:
                    already.append({"path": candidate_text, "reason": known_paths[candidate_text]})
                    continue
                try:
                    digest = sha256_file(candidate)
                    size = candidate.stat().st_size
                except Exception as error:
                    errors.append({"path": candidate_text, "reason": str(error)})
                    continue
                duplicate_target = known_hashes.get(digest)
                if duplicate_target:
                    already.append({
                        "path": candidate_text,
                        "reason": f"same SHA-256 as {duplicate_target}",
                    })
                    continue
                duplicate_entry = registry_hashes.get(digest)
                if duplicate_entry:
                    already.append({
                        "path": candidate_text,
                        "reason": f"same SHA-256 as queued {duplicate_entry.get('path')}",
                    })
                    continue
                entry = {
                    "path": candidate_text,
                    "sha256": digest,
                    "size_bytes": size,
                    "added_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                }
                registry.append(entry)
                registry_paths[candidate_text] = entry
                registry_hashes[digest] = entry
                known_hashes[digest] = candidate_text
                added.append(entry)

            self.registry_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.registry_path.with_suffix(self.registry_path.suffix + ".tmp")
            temporary.write_text(
                json.dumps(registry, indent=2, ensure_ascii=False), encoding="utf-8"
            )
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.registry_path)
            self.completed.emit({
                "selected": total,
                "added": added,
                "already": already,
                "errors": errors,
            })
        except Exception as error:
            self.failed.emit(str(error))

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
        self.derived_dir = db_path.parent
        self.registry_path = self.derived_dir / "intake-sources.json"
        self.import_worker: ImportWorker | None = None
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
        self._apply_theme()
        self._bind_shortcuts()
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
        header.addStretch(1)
        self.refresh_button = QPushButton("Refresh")
        self.refresh_button.clicked.connect(lambda: self._refresh_catalog(force=True))
        header.addWidget(self.refresh_button)
        left_layout.addLayout(header)

        intake_row = QHBoxLayout()
        self.add_files_button = QPushButton("Add files")
        self.add_files_button.clicked.connect(self._add_files)
        intake_row.addWidget(self.add_files_button)
        self.add_folder_button = QPushButton("Add folder")
        self.add_folder_button.clicked.connect(self._add_folder)
        intake_row.addWidget(self.add_folder_button)
        self.index_now_button = QPushButton("Index now")
        self.index_now_button.clicked.connect(self._index_now)
        intake_row.addWidget(self.index_now_button)
        left_layout.addLayout(intake_row)

        self.intake_status = QLabel("Add files or a folder; SHA-256 prevents duplicate indexing.")
        self.intake_status.setWordWrap(True)
        left_layout.addWidget(self.intake_status)
        self.catalog_label = QLabel("Catalog loading")
        left_layout.addWidget(self.catalog_label)
        self.media_search = QLineEdit()
        self.media_search.setPlaceholderText("Filter by filename, folder, or status")
        self.media_search.setClearButtonEnabled(True)
        self.media_search.textChanged.connect(self._filter_media)
        left_layout.addWidget(self.media_search)
        self.media_list = QListWidget()
        self.media_list.setAlternatingRowColors(True)
        self.media_list.itemDoubleClicked.connect(self._open_media_item)
        left_layout.addWidget(self.media_list)
        splitter.addWidget(left)

        center = QWidget()
        center_layout = QVBoxLayout(center)
        self.playback_label = QLabel("Open a completed item. Processing items update automatically.")
        center_layout.addWidget(self.playback_label)
        action_row = QHBoxLayout()
        self.open_source_button = QPushButton("Open source folder")
        self.open_source_button.clicked.connect(self._open_source_directory)
        action_row.addWidget(self.open_source_button)
        self.open_analysis_button = QPushButton("Open analysis folder")
        self.open_analysis_button.clicked.connect(self._open_analysis_directory)
        action_row.addWidget(self.open_analysis_button)
        action_row.addStretch(1)
        center_layout.addLayout(action_row)
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
        self.position.setToolTip("Drag to seek")
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
        self.use_preview.setToolTip("Toggle between source media and annotated AI preview")
        self.use_preview.toggled.connect(self._reload_current_at_same_time)
        controls.addWidget(self.use_preview)
        self.auto_skip = QCheckBox("Auto-skip inactive")
        self.auto_skip.setToolTip("Skip directly to the next review interval")
        controls.addWidget(self.auto_skip)
        center_layout.addLayout(controls)
        splitter.addWidget(center)

        right = QWidget()
        right_layout = QVBoxLayout(right)
        right_layout.addWidget(QLabel("Transcript search"))
        search_row = QHBoxLayout()
        self.transcript_search = QLineEdit()
        self.transcript_search.setPlaceholderText("Search transcript")
        self.transcript_search.setClearButtonEnabled(True)
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

    def _apply_theme(self) -> None:
        self.setStyleSheet(
            """
            QMainWindow, QWidget {
                background-color: #10141c;
                color: #dde7f2;
            }
            QMenuBar, QMenu {
                background-color: #0c1118;
                color: #dde7f2;
            }
            QListWidget, QTextBrowser, QLineEdit, QComboBox, QSlider, QFrame {
                background-color: #171d28;
                color: #dde7f2;
                border: 1px solid #2e3a4f;
                border-radius: 6px;
            }
            QPushButton {
                background-color: #2c4468;
                color: #f3f7ff;
                border: 1px solid #3c5f8d;
                border-radius: 6px;
                padding: 5px 10px;
            }
            QPushButton:hover {
                background-color: #355781;
            }
            QPushButton:disabled {
                background-color: #263142;
                color: #8f9aa8;
            }
            QCheckBox {
                spacing: 6px;
            }
            """
        )

    def _bind_shortcuts(self) -> None:
        QShortcut(QKeySequence(Qt.Key.Key_Space), self, activated=self._toggle_play)
        QShortcut(
            QKeySequence("Ctrl+F"),
            self,
            activated=lambda: self.transcript_search.setFocus(Qt.FocusReason.ShortcutFocusReason),
        )

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
            registry_stat = self.registry_path.stat().st_mtime_ns if self.registry_path.is_file() else 0
            signature = signature + (("registry", registry_stat),)
        except (sqlite3.Error, OSError):
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
        catalog_paths: set[str] = set()
        catalog_hashes: set[str] = set()
        hash_rows = self.conn.execute("SELECT source_path, sha256 FROM media").fetchall()
        for hash_row in hash_rows:
            try:
                catalog_paths.add(str(Path(hash_row["source_path"]).expanduser().resolve()))
            except Exception:
                catalog_paths.add(str(hash_row["source_path"]))
            if hash_row["sha256"]:
                catalog_hashes.add(str(hash_row["sha256"]))

        for row in rows:
            status = str(row["status"])
            counts[status] = counts.get(status, 0) + 1
            path = Path(row["source_path"])
            duration = format_time(float(row["duration"] or 0.0))
            item = QListWidgetItem(f"[{status}] {path.name} {duration} {path.parent}")
            item.setData(MEDIA_ROLE, int(row["id"]))
            item.setToolTip(str(row["error"] or path))
            widget = MediaRowWidget(status, path.name, str(path.parent), duration)
            item.setSizeHint(widget.sizeHint())
            self.media_list.addItem(item)
            self.media_list.setItemWidget(item, widget)
            if current_id == int(row["id"]):
                selected_item = item

        for entry in load_registry(self.registry_path):
            raw_path = str(entry.get("path") or "")
            if not raw_path:
                continue
            try:
                path = Path(raw_path).expanduser().resolve()
            except Exception:
                path = Path(raw_path)
            digest = str(entry.get("sha256") or "")
            if str(path) in catalog_paths or (digest and digest in catalog_hashes):
                continue
            counts["queued"] = counts.get("queued", 0) + 1
            item = QListWidgetItem(f"[queued] {path.name} {path.parent}")
            item.setData(MEDIA_ROLE, None)
            item.setToolTip(f"Queued for indexing\n{path}")
            widget = MediaRowWidget("queued", path.name, str(path.parent), "waiting")
            item.setSizeHint(widget.sizeHint())
            self.media_list.addItem(item)
            self.media_list.setItemWidget(item, widget)

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

    def _add_files(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(
            self,
            "Add audio or video files",
            str(Path.home()),
            "Media files (*.mp4 *.mkv *.avi *.mov *.m4v *.webm *.mts *.m2ts *.ts "
            "*.mp3 *.wav *.flac *.m4a *.aac *.ogg *.opus *.wma *.aax);;All files (*)",
        )
        if paths:
            self._start_import(paths)

    def _add_folder(self) -> None:
        path = QFileDialog.getExistingDirectory(
            self, "Add every supported media file in a folder", str(Path.home())
        )
        if path:
            self._start_import([path])

    def _set_import_controls(self, enabled: bool) -> None:
        self.add_files_button.setEnabled(enabled)
        self.add_folder_button.setEnabled(enabled)
        self.index_now_button.setEnabled(enabled)

    def _start_import(self, selections: list[str]) -> None:
        if self.import_worker is not None and self.import_worker.isRunning():
            QMessageBox.information(self, "Import active", "A duplicate-check scan is already running.")
            return
        self._set_import_controls(False)
        self.intake_status.setText("Enumerating media and calculating SHA-256 values...")
        self.import_worker = ImportWorker(selections, self.db_path, self.registry_path)
        self.import_worker.progress.connect(self._import_progress)
        self.import_worker.completed.connect(self._import_completed)
        self.import_worker.failed.connect(self._import_failed)
        self.import_worker.start()

    def _import_progress(self, current: int, total: int, name: str) -> None:
        self.intake_status.setText(f"Duplicate check {current}/{total}: {name}")

    def _import_completed(self, summary: dict) -> None:
        self._set_import_controls(True)
        added = list(summary.get("added") or [])
        already = list(summary.get("already") or [])
        errors = list(summary.get("errors") or [])
        self.intake_status.setText(
            f"Added: {len(added)}; already added or duplicate: {len(already)}; errors: {len(errors)}"
        )
        self._refresh_catalog(force=True)
        if added:
            self._index_now(quiet=True)
        lines = [
            f"New files queued: {len(added)}",
            f"Already added or duplicate: {len(already)}",
            f"Errors: {len(errors)}",
        ]
        if already:
            lines.append("\nDuplicate examples:")
            for entry in already[:8]:
                lines.append(f"  {Path(entry['path']).name}: {entry['reason']}")
        if errors:
            lines.append("\nError examples:")
            for entry in errors[:8]:
                lines.append(f"  {Path(entry['path']).name}: {entry['reason']}")
        QMessageBox.information(self, "BODYCAM intake result", "\n".join(lines))
        self.import_worker = None

    def _import_failed(self, message: str) -> None:
        self._set_import_controls(True)
        self.intake_status.setText(f"Import failed: {message}")
        QMessageBox.critical(self, "Import failed", message)
        self.import_worker = None

    def _index_now(self, quiet: bool = False) -> None:
        active = subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", "ophanim-av-index.service"],
            check=False,
        ).returncode == 0
        if active:
            queued = subprocess.run(
                ["systemctl", "--user", "start", "ophanim-av-rescan.service"],
                capture_output=True,
                text=True,
                check=False,
            )
            if queued.returncode == 0:
                self.intake_status.setText(
                    "Files are queued; an automatic rescan will start as soon as the active pass finishes."
                )
                if not quiet:
                    QMessageBox.information(
                        self,
                        "Rescan queued",
                        "The current file was not interrupted. A new indexing pass will start automatically when the active pass finishes.",
                    )
            else:
                message = (queued.stderr or queued.stdout or "could not queue rescan").strip()
                self.intake_status.setText(f"Files are queued; rescan scheduling failed: {message}")
                if not quiet:
                    QMessageBox.critical(self, "Could not queue rescan", message)
            return
        result = subprocess.run(
            ["systemctl", "--user", "start", "ophanim-av-index.service"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            self.intake_status.setText("Indexer started; queued files will appear as processing shortly.")
        else:
            message = (result.stderr or result.stdout or "systemctl start failed").strip()
            self.intake_status.setText(f"Could not start indexer: {message}")
            if not quiet:
                QMessageBox.critical(self, "Indexer start failed", message)

    def _open_media_item(self, item: QListWidgetItem) -> None:
        media_id = item.data(MEDIA_ROLE)
        if media_id is None:
            QMessageBox.information(
                self,
                "Queued for indexing",
                "This file has been added and passed duplicate checks. "
                "It will become playable after the indexer creates its catalog entry.",
            )
            return
        self._open_media_id(int(media_id), preserve_ms=None)

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
