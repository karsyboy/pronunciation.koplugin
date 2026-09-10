#!/usr/bin/env python3
"""Regression checks for the generated pronunciation database."""

from __future__ import annotations

import hashlib
import io
import json
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
    default_database_path,
    discover_wikipron_languages,
    latest_github_release,
    resolve_requested_language,
    sync_git_checkout,
    sync_git_release_checkout,
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
    database = ROOT / "data" / "en" / "pronunciations.sqlite3"
    assert not (ROOT / "data" / "pronunciations.sqlite3").exists()
    assert not (ROOT / "data" / "wikipron_sources.tsv").exists()
    assert hashlib.sha256(database.read_bytes()).hexdigest() == DATABASE_SHA256
    connection = sqlite3.connect(database)
    try:
        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 7
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(pronunciations)")
        }
        assert {
            "region", "simple_approx", "language_code", "language_name",
            "script", "profile", "transcription",
        } <= columns
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
        ).fetchone()[0] >= 8
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
        assert ("/təmɑːtəʊ/", "UK", 0) in regional_tomato
        assert ("/təmeɪtoʊ/", "US", 0) in regional_tomato
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
        assert metadata["language_code"] == "en"
        assert metadata["language_name"] == "English"
        assert metadata["language_iso6393"] == "eng"
        assert metadata["schema_version"] == "7"
        assert len(metadata["cmudict_revision"]) == 40
        assert len(metadata["supplement_sha256"]) == 64
        assert len(metadata["language_hints_sha256"]) == 64
        assert len(metadata["wikipron_revision"]) == 40
        assert metadata["wikipron_release"].startswith("v")
        assert metadata["wikipron_profiles"] == "2"
        assert not any(
            key.startswith("wikipron_") and key.endswith("_sha256")
            for key in metadata
        )
        assert metadata["converter"] == (
            "tools/build_database.py discovery profile schema v5"
        )
        assert database.stat().st_size < 15_000_000
    finally:
        connection.close()


def check_compact_database_build() -> None:
    with tempfile.TemporaryDirectory(prefix="pronunciation-db-test-") as directory:
        directory = Path(directory)
        cmudict = directory / "cmudict.dict"
        cmudict.write_text("cat K AE1 T\n", encoding="utf-8")
        supplement = directory / "supplemental.tsv"
        supplement.write_text(
            "word\tipa\tsimple\tregion\tconfidence\tnote\n"
            "projectword\t/ˈpɹɑdʒɛkt/\tPRAH-jekt\tUS\t90\tFixture\n",
            encoding="utf-8",
        )
        hints = directory / "language_hints.tsv"
        hints.write_text(
            "word\tlanguage_code\tlanguage_name\tsource\tnote\n",
            encoding="utf-8",
        )
        scrape = directory / "scrape"
        tsv = scrape / "tsv"
        library = scrape / "lib"
        tsv.mkdir(parents=True)
        library.mkdir()
        (library / "languages.json").write_text(json.dumps({
            "eng": {
                "iso639_name": "English", "wiktionary_code": "en",
                "wiktionary_name": "English", "script": {"latn": "Latin"},
                "dialect": {
                    "us": "US | General American",
                    "uk": "UK | Received Pronunciation",
                },
            },
            "fra": {
                "iso639_name": "French", "wiktionary_code": "fr",
                "wiktionary_name": "French", "script": {"latn": "Latin"},
                "dialect": {"ca": "Canada", "fr": "France"},
            },
            "deu": {
                "iso639_name": "German", "wiktionary_code": "de",
                "wiktionary_name": "German", "script": {"latn": "Latin"},
            },
        }), encoding="utf-8")
        (tsv / "eng_latn_us_broad.tsv").write_text(
            "test\tt ɛ s t\ntest\tt ɛ s t\ntomato\tt ə m eɪ t oʊ\n",
            encoding="utf-8",
        )
        (tsv / "eng_latn_uk_broad.tsv").write_text(
            "test\tt ɛ s t\ntomato\tt ə m ɑː t əʊ\n", encoding="utf-8"
        )
        (tsv / "fra_latn_ca_broad.tsv").write_text(
            "bonjour\tb ɔ̃ ʒ u ʁ\nduplicate\td y p\n", encoding="utf-8"
        )
        (tsv / "fra_latn_fr_broad.tsv").write_text(
            "bonjour\tb ɔ̃ ʒ u ʁ\nduplicate\td y p\n", encoding="utf-8"
        )
        (tsv / "fra_latn_narrow.tsv").write_text(
            "narrow-only\tn a ʁ o\n", encoding="utf-8"
        )
        (tsv / "fra_latn_broad_filtered.tsv").write_text(
            "filtered-only\tf i l t ʁ\n", encoding="utf-8"
        )
        (tsv / "deu_latn_broad.tsv").write_text(
            "hallo\th a l oː\n", encoding="utf-8"
        )

        languages = discover_wikipron_languages(tsv)
        assert set(languages) == {"de", "en", "fr"}
        assert resolve_requested_language("eng", languages) == "en"
        assert resolve_requested_language("en-US", languages) == "en"
        assert resolve_requested_language("fra", languages) == "fr"
        assert resolve_requested_language("fre", languages) == "fr"
        assert resolve_requested_language("fr-CA", languages) == "fr"
        assert [source.region for source in languages["en"].sources] == [
            "UK", "US",
        ]
        assert [source.region for source in languages["fr"].sources] == [
            "Canada", "France",
        ]
        assert all(
            source.transcription == "broad"
            for source in languages["fr"].sources
        )

        output = default_database_path(directory / "packs", "en")
        headwords, records = build_database(
            languages["en"],
            languages["en"].sources,
            output,
            "v-test",
            "test-wikipron-revision",
            "2026-01-01",
            cmudict=cmudict,
            cmudict_revision="test-cmudict-revision",
            supplement=supplement,
            language_hints=hints,
        )
        assert headwords > 2 and records > 2
        connection = sqlite3.connect(output)
        try:
            assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
            assert connection.execute("PRAGMA user_version").fetchone()[0] == 7
            assert connection.execute(
                "SELECT ipa, arpabet, simple FROM pronunciations WHERE word='cat'"
            ).fetchone() == ("/ˈkæt/", "K AE1 T", "KAT")
            assert connection.execute(
                "SELECT region FROM pronunciations "
                "WHERE word='test' AND source='WikiPron/Wiktionary' "
                "ORDER BY region"
            ).fetchall() == [("UK",), ("US",)]
            assert connection.execute(
                "SELECT value FROM metadata WHERE key='generated'"
            ).fetchone()[0] == "2026-01-01"
            assert connection.execute(
                "SELECT COUNT(*) FROM pronunciations "
                "WHERE word='test' AND region='US'"
            ).fetchone()[0] == 1
        finally:
            connection.close()

        french_output = default_database_path(directory / "packs", "fr")
        build_database(
            languages["fr"], languages["fr"].sources, french_output,
            "v-test", "test-wikipron-revision", "2026-01-01",
        )
        connection = sqlite3.connect(french_output)
        try:
            assert connection.execute(
                "SELECT region FROM pronunciations WHERE word='bonjour' "
                "ORDER BY region"
            ).fetchall() == [("Canada",), ("France",)]
            assert connection.execute(
                "SELECT COUNT(*) FROM pronunciations WHERE word='duplicate'"
            ).fetchone()[0] == 2
            assert connection.execute(
                "SELECT COUNT(*) FROM pronunciations WHERE word='narrow-only'"
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT COUNT(*) FROM pronunciations WHERE word='filtered-only'"
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT simple, language_code, language_name FROM pronunciations "
                "WHERE word='bonjour' LIMIT 1"
            ).fetchone() == (None, "fr", "French")
        finally:
            connection.close()

        sidecar = dict(
            line.split("\t", 1)
            for line in (french_output.parent / "pack.tsv")
            .read_text(encoding="utf-8").splitlines()
        )
        assert sidecar["language_code"] == "fr"
        assert sidecar["language_name"] == "French"
        assert "fre" in sidecar["aliases"].split(",")

        common = [
            "--wikipron-root", str(tsv),
            "--wikipron-release", "v-test",
            "--wikipron-revision", "test-wikipron-revision",
            "--generated-date", "2026-01-01",
        ]
        command = [sys.executable, ROOT / "tools" / "build_database.py"]
        default_root = directory / "default-output"
        subprocess.run(command + common + [
            "--data-dir", str(default_root), "--cmudict", str(cmudict),
            "--cmudict-revision", "test-cmudict-revision",
            "--supplement", str(supplement), "--language-hints", str(hints),
        ], check=True, capture_output=True, text=True)
        assert default_database_path(default_root, "en").is_file()

        one_root = directory / "one-output"
        subprocess.run(command + common + [
            "--language", "fr-CA", "--data-dir", str(one_root),
        ], check=True, capture_output=True, text=True)
        assert default_database_path(one_root, "fr").is_file()

        repeated_root = directory / "repeated-output"
        subprocess.run(command + common + [
            "--language", "fr", "--language", "de",
            "--data-dir", str(repeated_root),
        ], check=True, capture_output=True, text=True)
        assert default_database_path(repeated_root, "fr").is_file()
        assert default_database_path(repeated_root, "de").is_file()

        all_root = directory / "all-output"
        subprocess.run(command + common + [
            "--all", "--data-dir", str(all_root), "--cmudict", str(cmudict),
            "--cmudict-revision", "test-cmudict-revision",
            "--supplement", str(supplement), "--language-hints", str(hints),
        ], check=True, capture_output=True, text=True)
        assert {
            path.parent.name for path in all_root.glob("*/pronunciations.sqlite3")
        } == {"de", "en", "fr"}

        conflict = subprocess.run(command + common + [
            "--all", "--language", "fr", "--data-dir", str(directory / "bad"),
        ], capture_output=True, text=True)
        assert conflict.returncode != 0
        assert "not allowed with argument" in conflict.stderr


def check_latest_release_resolution() -> None:
    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.close()

    requested = []

    def opener(request, timeout):
        requested.append((request.full_url, timeout))
        return Response(json.dumps({
            "tag_name": "v9.8.7", "draft": False, "prerelease": False,
        }).encode())

    assert latest_github_release(opener=opener) == "v9.8.7"
    assert requested == [(
        "https://api.github.com/repos/CUNY-CL/wikipron/releases/latest", 30,
    )]


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
        subprocess.run(["git", "-C", upstream, "tag", "v1.0.0"], check=True)

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

        release_checkout = directory / "release-checkout"
        release_revision = sync_git_release_checkout(
            str(upstream.resolve()), release_checkout, "v1.0.0"
        )
        assert release_revision == first_revision
        assert (release_checkout / "source.txt").read_text(
            encoding="utf-8"
        ) == "first\n"


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
    assert "data/en/pronunciations.sqlite3" in RELEASE_FILES
    assert "data/pronunciations.sqlite3" not in RELEASE_FILES
    assert not any(
        relative.startswith("data/fr/") or relative.startswith("data/de/")
        for relative in RELEASE_FILES
    )
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
    check_latest_release_resolution()
    check_source_checkout_update()
    check_release_preparation()
    check_g2p_model()
    check_release_build()
    print("database regression tests: OK")
