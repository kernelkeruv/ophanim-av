#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image


CANONICAL_ICON = "assets/ophanimav.png"
HICOLOR_SIZES = (16, 24, 32, 48, 64, 128, 256, 512, 1024)
ICO_SIZES = ((16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256))


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    source = repo_root / CANONICAL_ICON
    if not source.is_file():
        raise SystemExit(f"Canonical icon does not exist: {source}")

    image = Image.open(source).convert("RGBA")
    for size in HICOLOR_SIZES:
        output = repo_root / f"assets/icons/hicolor/{size}x{size}/apps/ophanimav.png"
        output.parent.mkdir(parents=True, exist_ok=True)
        image.resize((size, size), Image.Resampling.LANCZOS).save(
            output, format="PNG", optimize=True
        )

    image.save(repo_root / "assets/ophanimav.ico", format="ICO", sizes=ICO_SIZES)
    print("Regenerated icon variants from", source)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
