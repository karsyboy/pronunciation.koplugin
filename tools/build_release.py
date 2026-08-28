#!/usr/bin/env python3
"""Build a deterministic, runtime-only KOReader plugin release archive."""

from __future__ import annotations

import argparse
import hashlib
import os
import sqlite3
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN_DIRECTORY = "pronunciation.koplugin"
RELEASE_FILES = (
    "_meta.lua",
    "main.lua",
    "README.md",
    "LICENSES.txt",
    "data/pronunciations.sqlite3",
    "data/mfa_english_g2p.bin",
    "data/mfa_english_g2p.SOURCE.txt",
)
ZIP_TIMESTAMP = (2026, 1, 1, 0, 0, 0)
PLUGIN_VERSION = "0.5.0"
DATABASE_SHA256 = (
    "337c196fbf8411fc9fb8c096b980f8a3dadf88c7f129931e138119044761ffb1"
)
G2P_SHA256 = (
    "9b4d3730a451c530da2a81f2c378a9e4635ec706e14f43d22fee945effd17f84"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_inputs() -> None:
    missing = [
        relative for relative in RELEASE_FILES if not (ROOT / relative).is_file()
    ]
    if missing:
        raise FileNotFoundError(f"release input(s) missing: {', '.join(missing)}")

    database_path = ROOT / "data/pronunciations.sqlite3"
    database = sqlite3.connect(f"{database_path.as_uri()}?mode=ro", uri=True)
    try:
        if database.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("pronunciation database failed quick_check")
        if database.execute("PRAGMA user_version").fetchone()[0] != 5:
            raise RuntimeError("pronunciation database schema is not release-ready")
        metadata = dict(database.execute("SELECT key, value FROM metadata"))
        if metadata.get("version") != PLUGIN_VERSION:
            raise RuntimeError("pronunciation database version does not match release")
    finally:
        database.close()
    if sha256(database_path) != DATABASE_SHA256:
        raise RuntimeError("pronunciation database failed the release integrity check")

    metadata_source = (ROOT / "_meta.lua").read_text(encoding="utf-8")
    runtime_source = (ROOT / "main.lua").read_text(encoding="utf-8")
    if f'version = "{PLUGIN_VERSION}"' not in metadata_source:
        raise RuntimeError("plugin metadata version does not match release")
    if f'local PLUGIN_VERSION = "{PLUGIN_VERSION}"' not in runtime_source:
        raise RuntimeError("runtime version does not match release")

    with (ROOT / "data/mfa_english_g2p.bin").open("rb") as model:
        if model.read(8) != b"KPG2P3\0\0":
            raise RuntimeError("G2P model format is not release-ready")
    if sha256(ROOT / "data/mfa_english_g2p.bin") != G2P_SHA256:
        raise RuntimeError("G2P model failed the release integrity check")


def build_release(output: Path) -> tuple[int, int]:
    validate_inputs()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    if temporary.exists():
        temporary.unlink()

    uncompressed_size = 0
    try:
        with zipfile.ZipFile(
            temporary,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            for relative in RELEASE_FILES:
                data = (ROOT / relative).read_bytes()
                uncompressed_size += len(data)
                info = zipfile.ZipInfo(
                    f"{PLUGIN_DIRECTORY}/{relative}",
                    date_time=ZIP_TIMESTAMP,
                )
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data, compresslevel=9)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()
    return uncompressed_size, output.stat().st_size


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "dist" / f"{PLUGIN_DIRECTORY}.zip",
    )
    args = parser.parse_args()
    uncompressed, compressed = build_release(args.output)
    print(
        f"built {args.output}: {compressed} bytes compressed, "
        f"{uncompressed} bytes installed, sha256 {sha256(args.output)}"
    )


if __name__ == "__main__":
    main()
