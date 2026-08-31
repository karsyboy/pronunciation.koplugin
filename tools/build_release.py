#!/usr/bin/env python3
"""Build a deterministic, runtime-only KOReader plugin release archive."""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import re
import sqlite3
import subprocess
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN_DIRECTORY = "pronunciation.koplugin"
RELEASE_FILES = (
    "_meta.lua",
    "main.lua",
    "README.md",
    "LICENSE",
    "LICENSES.txt",
    "data/pronunciations.sqlite3",
    "data/mfa_english_g2p.bin",
    "data/mfa_english_g2p.SOURCE.txt",
    "data/wikipron_sources.tsv",
)
ZIP_TIMESTAMP = (2026, 1, 1, 0, 0, 0)
RELEASE_ID_LENGTH = 12
PLUGIN_VERSION = "0.5.0"
DATABASE_SHA256 = (
    "62494a9b4b612eeaf04caedde85b123d1b5365fc87ed597ca6ec9815d0281fcc"
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


def git_release_id() -> str:
    """Return an abbreviated Git commit SHA suitable for an artifact name."""
    try:
        result = subprocess.run(
            (
                "git",
                "rev-parse",
                "--verify",
                f"--short={RELEASE_ID_LENGTH}",
                "HEAD",
            ),
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        raise RuntimeError(
            "cannot determine the Git SHA for the default release name; "
            "build from a Git checkout or pass --output"
        ) from error

    release_id = result.stdout.strip().lower()
    if not re.fullmatch(rf"[0-9a-f]{{{RELEASE_ID_LENGTH},64}}", release_id):
        raise RuntimeError(f"Git returned an invalid release SHA: {release_id!r}")
    return release_id


def default_release_output() -> Path:
    return ROOT / "dist" / f"{PLUGIN_DIRECTORY}-{git_release_id()}.zip"


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
        if database.execute("PRAGMA user_version").fetchone()[0] != 6:
            raise RuntimeError("pronunciation database schema is not release-ready")
        metadata = dict(database.execute("SELECT key, value FROM metadata"))
        if metadata.get("version") != PLUGIN_VERSION:
            raise RuntimeError("pronunciation database version does not match release")
        headwords, records = database.execute(
            "SELECT COUNT(DISTINCT word), COUNT(*) FROM pronunciations"
        ).fetchone()
        if metadata.get("headwords") != str(headwords):
            raise RuntimeError("pronunciation database headword metadata is stale")
        if metadata.get("records") != str(records):
            raise RuntimeError("pronunciation database record metadata is stale")
    finally:
        database.close()
    if sha256(database_path) != DATABASE_SHA256:
        raise RuntimeError("pronunciation database failed the release integrity check")

    with (ROOT / "data/wikipron_sources.tsv").open(
        encoding="utf-8", newline=""
    ) as manifest:
        reader = csv.DictReader(manifest, delimiter="\t")
        required = {"source_id", "sha256"}
        missing_columns = required - set(reader.fieldnames or ())
        if missing_columns:
            raise RuntimeError(
                f"WikiPron manifest is missing columns: {sorted(missing_columns)}"
            )
        source_count = 0
        for row in reader:
            source_count += 1
            source_id = row["source_id"].strip()
            expected = row["sha256"].strip().lower()
            if metadata.get(f"wikipron_{source_id}_sha256") != expected:
                raise RuntimeError(
                    f"database metadata does not match WikiPron source {source_id}"
                )
        if source_count == 0:
            raise RuntimeError("WikiPron release manifest contains no sources")

    if not (ROOT / "LICENSE").read_text(encoding="utf-8").startswith(
        "MIT License\n"
    ):
        raise RuntimeError("plugin code license is missing or invalid")

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
        help=(
            "archive path (default: "
            f"dist/{PLUGIN_DIRECTORY}-<12-character-git-sha>.zip)"
        ),
    )
    args = parser.parse_args()
    output = args.output or default_release_output()
    uncompressed, compressed = build_release(output)
    print(
        f"built {output}: {compressed} bytes compressed, "
        f"{uncompressed} bytes installed, sha256 {sha256(output)}"
    )


if __name__ == "__main__":
    main()
