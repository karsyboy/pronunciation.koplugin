#!/usr/bin/env python3
"""Regression checks for the generated pronunciation database."""

from __future__ import annotations

import csv
import hashlib
import sqlite3
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

from build_database import (  # noqa: E402
    PLUGIN_VERSION as DATABASE_PLUGIN_VERSION,
    arpabet_to_ipa,
    arpabet_to_readable,
    build_database,
    load_wikipron_manifest,
    refresh_wikipron_manifest,
    sync_git_checkout,
)
from build_release import (  # noqa: E402
    DATABASE_SHA256,
    G2P_SHA256,
    PLUGIN_DIRECTORY,
    PLUGIN_VERSION,
    RELEASE_FILES,
    build_release,
    default_release_output,
    read_plugin_version,
)
from prepare_release import (  # noqa: E402
    synchronize_database_hash,
    synchronize_runtime_version,
)


def check_conversion() -> None:
    assert DATABASE_PLUGIN_VERSION == PLUGIN_VERSION
    assert arpabet_to_ipa("K AE1 T".split()) == "/ˈkæt/"
    assert arpabet_to_readable("K AE1 T".split()) == "KAT"
    epitome = "IH0 P IH1 T AH0 M IY0".split()
    assert arpabet_to_ipa(epitome) == "/ɪˈpɪtəmi/"
    assert arpabet_to_readable(epitome) == "ih-PIT-uh-mee"
    colour = "K AH1 L ER0".split()
    assert arpabet_to_ipa(colour) == "/ˈkʌlɚ/"
    assert arpabet_to_readable(colour) == "KUHL-er"


def check_database() -> None:
    database = ROOT / "data" / "pronunciations.sqlite3"
    assert hashlib.sha256(database.read_bytes()).hexdigest() == DATABASE_SHA256
    connection = sqlite3.connect(database)
    try:
        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 6
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(pronunciations)")
        }
        assert {"region", "simple_approx"} <= columns
        object_types = dict(connection.execute(
            "SELECT name, type FROM sqlite_schema"
        ))
        assert object_types["pronunciations"] == "view"
        assert object_types["pronunciation_entries"] == "table"
        assert connection.execute(
            "SELECT COUNT(*) FROM pronunciation_sources"
        ).fetchone()[0] == 3
        assert connection.execute(
            "SELECT COUNT(*) FROM pronunciation_profiles"
        ).fetchone()[0] == 8
        headwords, records = connection.execute(
            "SELECT COUNT(DISTINCT word), COUNT(*) FROM pronunciations"
        ).fetchone()
        assert headwords >= 176_000
        assert records >= 345_000

        for ipa, arpabet, simple in connection.execute(
            "SELECT ipa, arpabet, simple FROM pronunciations "
            "WHERE source = 'CMUdict'"
        ):
            phones = arpabet.split()
            assert ipa == arpabet_to_ipa(phones)
            assert simple == arpabet_to_readable(phones)
            assert ipa.count("/") == 2

        def pronunciations(word: str):
            return connection.execute(
                "SELECT ipa, simple FROM pronunciations WHERE word = ?",
                (word,),
            ).fetchall()

        assert ("/ˈkæt/", "KAT") in pronunciations("cat")
        assert ("/ɪˈpɪtəmi/", "ih-PIT-uh-mee") in pronunciations("epitome")
        assert any(ipa == "/ˈklʊərɪkɔːnz/"
                   for ipa, _ in pronunciations("clurichauns"))
        regional_tomato = connection.execute(
            "SELECT ipa, region, simple_approx FROM pronunciations "
            "WHERE word = 'tomato' AND source = 'WikiPron/Wiktionary'"
        ).fetchall()
        assert {region for _, region, _ in regional_tomato} == {"US", "UK"}
        assert ("/təmɑːtəʊ/", "UK", 1) in regional_tomato
        assert ("/təmeɪtoʊ/", "US", 1) in regional_tomato
        assert connection.execute(
            "SELECT COUNT(*) FROM pronunciations "
            "WHERE source = 'WikiPron/Wiktionary' "
            "AND (ipa NOT LIKE '/%/' "
            "OR LENGTH(ipa) - LENGTH(REPLACE(ipa, '/', '')) != 2)"
        ).fetchone()[0] == 0
        assert connection.execute(
            "SELECT COUNT(*) FROM language_hints"
        ).fetchone()[0] == 0
        metadata = dict(connection.execute("SELECT key, value FROM metadata"))
        assert metadata["version"] == PLUGIN_VERSION
        assert len(metadata["cmudict_revision"]) == 40
        assert len(metadata["supplement_sha256"]) == 64
        assert len(metadata["language_hints_sha256"]) == 64
        assert len(metadata["wikipron_revision"]) == 40
        with (ROOT / "data" / "wikipron_sources.tsv").open(
            encoding="utf-8", newline=""
        ) as manifest:
            for row in csv.DictReader(manifest, delimiter="\t"):
                source_id = row["source_id"]
                assert metadata[f"wikipron_{source_id}_sha256"] == row["sha256"]
                assert int(metadata[f"wikipron_{source_id}_records"]) > 0
        assert metadata["converter"] == (
            "tools/build_database.py manifest profile schema v4"
        )
        assert database.stat().st_size < 15_000_000
    finally:
        connection.close()


def check_compact_database_build() -> None:
    with tempfile.TemporaryDirectory(prefix="pronunciation-db-test-") as directory:
        directory = Path(directory)
        cmudict = directory / "cmudict.dict"
        cmudict.write_text("cat K AE1 T\n", encoding="utf-8")
        us_wikipron = directory / "eng_latn_us_broad.tsv"
        uk_wikipron = directory / "eng_latn_uk_broad.tsv"
        us_wikipron.write_text("test\tt ɛ s t\n", encoding="utf-8")
        uk_wikipron.write_text("test\tt ɛ s t\n", encoding="utf-8")
        manifest = directory / "wikipron_sources.tsv"
        manifest.write_text(
            "filename\tsource_id\tlanguage_code\tlanguage_name\tregion\tsha256\n"
            f"{us_wikipron.name}\teng_us\ten\tEnglish\tUS\t"
            f"{'0' * 64}\n"
            f"{uk_wikipron.name}\teng_uk\ten\tEnglish\tUK\t"
            f"{'0' * 64}\n",
            encoding="utf-8",
        )
        assert refresh_wikipron_manifest(manifest, directory)
        assert not refresh_wikipron_manifest(manifest, directory)
        wikipron_sources = load_wikipron_manifest(manifest, directory)
        assert [source.source_id for source in wikipron_sources] == [
            "eng_us", "eng_uk",
        ]
        output = directory / "pronunciations.sqlite3"
        headwords, records = build_database(
            cmudict,
            ROOT / "data" / "supplemental.tsv",
            ROOT / "data" / "language_hints.tsv",
            wikipron_sources,
            output,
            "test-cmudict-revision",
            "test-wikipron-revision",
            "2026-01-01",
        )
        assert headwords > 2 and records > 2
        connection = sqlite3.connect(output)
        try:
            assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
            assert connection.execute("PRAGMA user_version").fetchone()[0] == 6
            assert connection.execute(
                "SELECT ipa, arpabet, simple FROM pronunciations WHERE word='cat'"
            ).fetchone() == ("/ˈkæt/", "K AE1 T", "KAT")
            assert connection.execute(
                "SELECT COUNT(*) FROM pronunciation_sources"
            ).fetchone()[0] == 3
            assert connection.execute(
                "SELECT COUNT(*) FROM pronunciation_profiles"
            ).fetchone()[0] == 8
            assert connection.execute(
                "SELECT region FROM pronunciations "
                "WHERE word='test' AND source='WikiPron/Wiktionary' "
                "ORDER BY region"
            ).fetchall() == [("UK",), ("US",)]
            assert connection.execute(
                "SELECT value FROM metadata WHERE key='generated'"
            ).fetchone()[0] == "2026-01-01"
        finally:
            connection.close()


def check_source_checkout_update() -> None:
    with tempfile.TemporaryDirectory(
        prefix="pronunciation-source-test-"
    ) as directory:
        directory = Path(directory)
        upstream = directory / "upstream"
        checkout = directory / "checkout"
        subprocess.run(
            ["git", "init", upstream], check=True, capture_output=True, text=True
        )
        subprocess.run(
            ["git", "-C", upstream, "config", "user.name", "Test Builder"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", upstream, "config", "user.email", "test@example.com"],
            check=True,
        )
        source = upstream / "source.txt"
        source.write_text("first\n", encoding="utf-8")
        subprocess.run(["git", "-C", upstream, "add", "source.txt"], check=True)
        subprocess.run(
            ["git", "-C", upstream, "commit", "-m", "first"],
            check=True,
            capture_output=True,
        )

        first_revision = sync_git_checkout(str(upstream.resolve()), checkout)
        assert (checkout / "source.txt").read_text(encoding="utf-8") == "first\n"

        source.write_text("second\n", encoding="utf-8")
        subprocess.run(["git", "-C", upstream, "add", "source.txt"], check=True)
        subprocess.run(
            ["git", "-C", upstream, "commit", "-m", "second"],
            check=True,
            capture_output=True,
        )
        second_revision = sync_git_checkout(str(upstream.resolve()), checkout)
        assert second_revision != first_revision
        assert (checkout / "source.txt").read_text(encoding="utf-8") == "second\n"


def check_release_preparation() -> None:
    with tempfile.TemporaryDirectory(
        prefix="pronunciation-release-preparation-test-"
    ) as directory:
        directory = Path(directory)
        runtime = directory / "main.lua"
        runtime.write_text(
            'local PLUGIN_VERSION = "0.1.0"\nlocal untouched = true\n',
            encoding="utf-8",
        )
        synchronize_runtime_version("2.3.4", runtime)
        assert runtime.read_text(encoding="utf-8") == (
            'local PLUGIN_VERSION = "2.3.4"\nlocal untouched = true\n'
        )

        database = directory / "pronunciations.sqlite3"
        database.write_bytes(b"database test contents")
        release_builder = directory / "build_release.py"
        release_builder.write_text(
            'DATABASE_SHA256 = (\n    "' + "0" * 64 + '"\n)\n',
            encoding="utf-8",
        )
        database_hash = synchronize_database_hash(database, release_builder)
        assert database_hash == hashlib.sha256(database.read_bytes()).hexdigest()
        assert database_hash in release_builder.read_text(encoding="utf-8")


def check_g2p_model() -> None:
    assert not (ROOT / "data" / "cmu_flite_lts.bin").exists()
    assert not (ROOT / "data" / "cmu_flite_lts.SOURCE.txt").exists()
    assert not (ROOT / "tools" / "build_lts_model.py").exists()
    model = ROOT / "data" / "mfa_english_g2p.bin"
    data = model.read_bytes()
    assert data[:8] == b"KPG2P3\0\0"
    assert int.from_bytes(data[8:12], "little") == 532_450
    assert int.from_bytes(data[12:16], "little") == 1_450_681
    assert int.from_bytes(data[16:20], "little") == 1
    assert int.from_bytes(data[20:22], "little") == 1_024
    assert data[22:26] == bytes((69, 2, 6, 0))
    assert int.from_bytes(data[26:30], "little") == 81_768
    assert len(data) == 10_011_830
    assert hashlib.sha256(data).hexdigest() == G2P_SHA256
    source = (ROOT / "data" / "mfa_english_g2p.SOURCE.txt").read_text()
    assert "g2p-english_us_arpa-v2.0.0" in source
    assert "f079ae88f792458fa7c123b256e5b86cc55c29ac2ffc457c673e6c60c36cd143" in source


def check_release_build() -> None:
    assert read_plugin_version() == PLUGIN_VERSION
    assert default_release_output() == (
        ROOT / "dist" / f"{PLUGIN_DIRECTORY}-{PLUGIN_VERSION}.zip"
    )

    with tempfile.TemporaryDirectory(prefix="pronunciation-release-test-") as directory:
        directory = Path(directory)
        metadata = directory / "_meta.lua"
        metadata.write_text(
            'return {\n    version = "1.2.3-rc.1+build.4",\n}\n',
            encoding="utf-8",
        )
        assert read_plugin_version(metadata) == "1.2.3-rc.1+build.4"
        metadata.write_text(
            'return {\n    version = "not/a/version",\n}\n',
            encoding="utf-8",
        )
        try:
            read_plugin_version(metadata)
        except RuntimeError:
            pass
        else:
            raise AssertionError("invalid plugin metadata version was accepted")

        version_result = subprocess.run(
            [
                sys.executable,
                ROOT / "tools" / "build_release.py",
                "--print-version",
            ],
            cwd=directory,
            check=True,
            capture_output=True,
            text=True,
        )
        assert version_result.stdout.strip() == PLUGIN_VERSION

        output = directory / "release.zip"
        second_output = directory / "release-again.zip"
        installed_size, archive_size = build_release(output)
        build_release(second_output)
        assert output.read_bytes() == second_output.read_bytes()
        assert installed_size < 26_000_000
        assert archive_size < installed_size
        with zipfile.ZipFile(output) as archive:
            assert archive.namelist() == [
                f"{PLUGIN_DIRECTORY}/{relative}" for relative in RELEASE_FILES
            ]
            assert all("flite" not in name.lower() for name in archive.namelist())
            assert (
                archive.read(f"{PLUGIN_DIRECTORY}/LICENSE")
                .startswith(b"MIT License\n")
            )


if __name__ == "__main__":
    check_conversion()
    check_database()
    check_compact_database_build()
    check_source_checkout_update()
    check_release_preparation()
    check_g2p_model()
    check_release_build()
    print("database regression tests: OK")
