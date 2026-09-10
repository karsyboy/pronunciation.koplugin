#!/usr/bin/env python3
"""Synchronize generated release inputs with the version in _meta.lua."""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

from build_release import read_plugin_version


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_VERSION_PATTERN = re.compile(
    r'^(local PLUGIN_VERSION\s*=\s*")[^"]+("\s*)$',
    flags=re.MULTILINE,
)
DATABASE_HASH_PATTERN = re.compile(
    r'(DATABASE_SHA256\s*=\s*\(\s*")[0-9a-f]{64}("\s*\))',
    flags=re.MULTILINE,
)
READABLE_HASH_PATTERN = re.compile(
    r'(READABLE_SHA256\s*=\s*\(\s*")[0-9a-f]{64}("\s*\))',
    flags=re.MULTILINE,
)
G2P_HASH_PATTERN = re.compile(
    r'(G2P_SHA256\s*=\s*\(\s*")[0-9a-f]{64}("\s*\))',
    flags=re.MULTILINE,
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def replace_one(path: Path, pattern: re.Pattern[str], replacement) -> None:
    source = path.read_text(encoding="utf-8")
    updated, count = pattern.subn(replacement, source)
    if count != 1:
        raise RuntimeError(f"expected exactly one release value in {path}")
    if updated != source:
        path.write_text(updated, encoding="utf-8")


def synchronize_runtime_version(
    version: str,
    runtime_path: Path = ROOT / "main.lua",
) -> None:
    replace_one(
        runtime_path,
        RUNTIME_VERSION_PATTERN,
        lambda match: f"{match.group(1)}{version}{match.group(2)}",
    )


def synchronize_database_hash(
    database_path: Path = ROOT / "data" / "en" / "pronunciations.sqlite3",
    release_builder_path: Path = ROOT / "tools" / "build_release.py",
) -> str:
    database_hash = sha256(database_path)
    replace_one(
        release_builder_path,
        DATABASE_HASH_PATTERN,
        lambda match: f"{match.group(1)}{database_hash}{match.group(2)}",
    )
    return database_hash


def synchronize_readable_hash(
    readable_path: Path = ROOT / "data" / "en" / "readable.tsv",
    release_builder_path: Path = ROOT / "tools" / "build_release.py",
) -> str:
    readable_hash = sha256(readable_path)
    replace_one(
        release_builder_path,
        READABLE_HASH_PATTERN,
        lambda match: f"{match.group(1)}{readable_hash}{match.group(2)}",
    )
    return readable_hash


def synchronize_g2p_hash(
    g2p_path: Path = ROOT / "data" / "en" / "g2p.bin",
    release_builder_path: Path = ROOT / "tools" / "build_release.py",
) -> str:
    g2p_hash = sha256(g2p_path)
    replace_one(
        release_builder_path,
        G2P_HASH_PATTERN,
        lambda match: f"{match.group(1)}{g2p_hash}{match.group(2)}",
    )
    return g2p_hash


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sources-dir",
        type=Path,
        help="override the automatic pronunciation source checkout directory",
    )
    parser.add_argument(
        "--generated-date",
        help="UTC database build date (YYYY-MM-DD)",
    )
    args = parser.parse_args()

    version = read_plugin_version()
    command = [sys.executable, str(ROOT / "tools" / "build_language_pack.py")]
    if args.sources_dir is not None:
        command.extend(("--sources-dir", str(args.sources_dir)))
    if args.generated_date is not None:
        command.extend(("--generated-date", args.generated_date))
    subprocess.run(command, cwd=ROOT, check=True)

    synchronize_runtime_version(version)
    database_hash = synchronize_database_hash()
    readable_hash = synchronize_readable_hash()
    g2p_hash = synchronize_g2p_hash()
    print(
        f"prepared release {version}: synchronized main.lua and database "
        f"sha256 {database_hash}; readable sha256 {readable_hash}; "
        f"G2P sha256 {g2p_hash}"
    )


if __name__ == "__main__":
    main()
