#!/usr/bin/env python3
"""Build a deterministic, runtime-only KOReader plugin release archive."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sqlite3
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
    "data/en/pronunciations.sqlite3",
    "data/en/pack.tsv",
    "data/en/readable.tsv",
    "data/en/g2p.bin",
    "data/en/g2p.SOURCE.txt",
)
ZIP_TIMESTAMP = (2026, 1, 1, 0, 0, 0)
VERSION_PATTERN = re.compile(
    r"(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)\."
    r"(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
    r"(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
)
DATABASE_SHA256 = (
    "e293ec21a228c387f6f82d9601b81357cb7d4b5b64cb264097ccf4b00d8b3707"
)
G2P_SHA256 = (
    "4056b000fb0b7b6b972a1bebaad89d21556fe1b64b199870608839d3d9d4b22c"
)
READABLE_SHA256 = (
    "3505d7c55e1a0a0cb2fec298e08856248c109d3153e9b085939f023ed18bbf0a"
)


def read_plugin_version(metadata_path: Path = ROOT / "_meta.lua") -> str:
    """Read and validate the release version declared in KOReader metadata."""
    metadata = metadata_path.read_text(encoding="utf-8")
    matches = re.findall(
        r'^\s*version\s*=\s*"([^"]+)"\s*,?\s*(?:--.*)?$',
        metadata,
        flags=re.MULTILINE,
    )
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one version in plugin metadata: {metadata_path}"
        )
    version = matches[0]
    if VERSION_PATTERN.fullmatch(version) is None:
        raise RuntimeError(f"plugin metadata has an invalid version: {version!r}")
    return version


PLUGIN_VERSION = read_plugin_version()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def default_release_output() -> Path:
    return ROOT / "dist" / f"{PLUGIN_DIRECTORY}-{PLUGIN_VERSION}.zip"


def validate_inputs() -> None:
    missing = [
        relative for relative in RELEASE_FILES if not (ROOT / relative).is_file()
    ]
    if missing:
        raise FileNotFoundError(f"release input(s) missing: {', '.join(missing)}")

    database_path = ROOT / "data/en/pronunciations.sqlite3"
    database = sqlite3.connect(f"{database_path.as_uri()}?mode=ro", uri=True)
    try:
        if database.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise RuntimeError("pronunciation database failed quick_check")
        if database.execute("PRAGMA user_version").fetchone()[0] != 8:
            raise RuntimeError("pronunciation database schema is not release-ready")
        metadata = dict(database.execute("SELECT key, value FROM metadata"))
        if metadata.get("version") != PLUGIN_VERSION:
            raise RuntimeError("pronunciation database version does not match release")
        if metadata.get("language_code") != "en":
            raise RuntimeError("bundled pronunciation database is not English")
        if not metadata.get("wikipron_release"):
            raise RuntimeError("pronunciation database lacks WikiPron release provenance")
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

    pack_metadata = dict(
        line.rstrip("\n").split("\t", 1)
        for line in (ROOT / "data/en/pack.tsv").read_text(
            encoding="utf-8"
        ).splitlines()
    )
    if (pack_metadata.get("language_code") != "en"
            or pack_metadata.get("language_name") != "English"
            or pack_metadata.get("schema_version") != "8"
            or pack_metadata.get("readable_converter") != "readable.tsv"
            or pack_metadata.get("g2p_model") != "g2p.bin"):
        raise RuntimeError("bundled English pack sidecar is invalid")
    if pack_metadata.get("aliases") != metadata.get("language_aliases"):
        raise RuntimeError("bundled pack sidecar does not match database metadata")

    if not (ROOT / "LICENSE").read_text(encoding="utf-8").startswith(
        "MIT License\n"
    ):
        raise RuntimeError("plugin code license is missing or invalid")

    runtime_source = (ROOT / "main.lua").read_text(encoding="utf-8")
    if f'local PLUGIN_VERSION = "{PLUGIN_VERSION}"' not in runtime_source:
        raise RuntimeError("runtime version does not match release")

    readable_path = ROOT / "data/en/readable.tsv"
    if not readable_path.read_text(encoding="utf-8").startswith(
        "ipa\treadable\n"
    ):
        raise RuntimeError("bundled readable converter is invalid")
    if sha256(readable_path) != READABLE_SHA256:
        raise RuntimeError("readable converter failed the release integrity check")

    g2p_path = ROOT / "data/en/g2p.bin"
    with g2p_path.open("rb") as model:
        if model.read(8) not in (b"KPG2P3\0\0", b"KPG2P4\0\0"):
            raise RuntimeError("G2P model format is not release-ready")
    if sha256(g2p_path) != G2P_SHA256:
        raise RuntimeError("G2P model failed the release integrity check")
    g2p_source = (ROOT / "data/en/g2p.SOURCE.txt").read_text(encoding="utf-8")
    if "Release: g2p-" not in g2p_source or G2P_SHA256 not in g2p_source:
        raise RuntimeError("G2P model provenance is missing or stale")


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
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument(
        "--output",
        type=Path,
        help=(
            "archive path (default: "
            f"dist/{PLUGIN_DIRECTORY}-<version>.zip)"
        ),
    )
    output_group.add_argument(
        "--print-version",
        action="store_true",
        help="print the validated plugin version and exit",
    )
    args = parser.parse_args()
    if args.print_version:
        print(PLUGIN_VERSION)
        return
    output = args.output or default_release_output()
    uncompressed, compressed = build_release(output)
    print(
        f"built {output}: {compressed} bytes compressed, "
        f"{uncompressed} bytes installed, sha256 {sha256(output)}"
    )


if __name__ == "__main__":
    main()
