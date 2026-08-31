#!/usr/bin/env python3
"""Regression checks for the generated pronunciation database."""

from __future__ import annotations

import hashlib
import re
import sqlite3
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

from build_database import (  # noqa: E402
    arpabet_to_ipa,
    arpabet_to_readable,
    build_database,
    load_wikipron_manifest,
)
from build_release import (  # noqa: E402
    DATABASE_SHA256,
    G2P_SHA256,
    PLUGIN_DIRECTORY,
    RELEASE_ID_LENGTH,
    RELEASE_FILES,
    build_release,
    default_release_output,
    git_release_id,
)


def check_conversion() -> None:
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
        assert metadata["version"] == "0.5.0"
        assert len(metadata["cmudict_revision"]) == 40
        assert len(metadata["supplement_sha256"]) == 64
        assert len(metadata["language_hints_sha256"]) == 64
        assert len(metadata["wikipron_revision"]) == 40
        assert metadata["wikipron_eng_us_sha256"] == (
            "f304b8f0565466e8abfe4c04a30d99421e1590d2aa17c4a08ebfa5942c587e75"
        )
        assert metadata["wikipron_eng_uk_sha256"] == (
            "f8ca476aa2e96cb22cafbf9099d689b5902a9d321579055081909b2eeafa1b8d"
        )
        assert metadata["wikipron_eng_us_records"] == "105458"
        assert metadata["wikipron_eng_uk_records"] == "105157"
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
            f"{hashlib.sha256(us_wikipron.read_bytes()).hexdigest()}\n"
            f"{uk_wikipron.name}\teng_uk\ten\tEnglish\tUK\t"
            f"{hashlib.sha256(uk_wikipron.read_bytes()).hexdigest()}\n",
            encoding="utf-8",
        )
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
    release_id = git_release_id()
    assert re.fullmatch(
        rf"[0-9a-f]{{{RELEASE_ID_LENGTH},64}}", release_id
    )
    assert default_release_output() == (
        ROOT / "dist" / f"{PLUGIN_DIRECTORY}-{release_id}.zip"
    )

    with tempfile.TemporaryDirectory(prefix="pronunciation-release-test-") as directory:
        output = Path(directory) / "release.zip"
        second_output = Path(directory) / "release-again.zip"
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
    check_g2p_model()
    check_release_build()
    print("database regression tests: OK")
