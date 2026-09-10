#!/usr/bin/env python3
"""Regression checks for the generated pronunciation database."""

from __future__ import annotations

import hashlib
import io
import json
import sqlite3
import struct
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
    build_database,
    default_database_path,
    discover_wikipron_languages,
    latest_github_release,
    resolve_requested_language,
    sync_git_release_checkout,
)
from build_g2p_model import (  # noqa: E402
    build_language_g2p,
    build_model,
    fetch_mfa_models,
    parse_phone_symbols,
    resolve_mfa_model,
)
from build_release import (  # noqa: E402
    DATABASE_SHA256,
    G2P_SHA256,
    READABLE_SHA256,
    PLUGIN_DIRECTORY,
    PLUGIN_VERSION,
    RELEASE_FILES,
    build_release,
    default_release_output,
    read_plugin_version,
)
from prepare_release import (  # noqa: E402
    synchronize_database_hash,
    synchronize_g2p_hash,
    synchronize_readable_hash,
    synchronize_runtime_version,
)


def check_database() -> None:
    assert DATABASE_PLUGIN_VERSION == PLUGIN_VERSION
    database = ROOT / "data" / "en" / "pronunciations.sqlite3"
    assert not (ROOT / "data" / "pronunciations.sqlite3").exists()
    assert not (ROOT / "data" / "wikipron_sources.tsv").exists()
    assert hashlib.sha256(database.read_bytes()).hexdigest() == DATABASE_SHA256
    connection = sqlite3.connect(database)
    try:
        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 8
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
        ).fetchone()[0] == 2
        assert connection.execute(
            "SELECT COUNT(*) FROM pronunciation_profiles"
        ).fetchone()[0] >= 3
        headwords, records = connection.execute(
            "SELECT COUNT(DISTINCT word), COUNT(*) FROM pronunciations"
        ).fetchone()
        assert headwords >= 85_000
        assert records >= 210_000
        assert connection.execute(
            "SELECT COUNT(*) FROM pronunciations WHERE source = 'CMUdict'"
        ).fetchone()[0] == 0

        def pronunciations(word: str):
            return connection.execute(
                "SELECT ipa, simple FROM pronunciations WHERE word = ?",
                (word,),
            ).fetchall()

        assert any(ipa == "/kæt/" and simple for ipa, simple in pronunciations("cat"))
        assert any(ipa == "/ɪpɪtəmi/" and simple
                   for ipa, simple in pronunciations("epitome"))
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
        assert "language_hints" not in object_types
        metadata = dict(connection.execute("SELECT key, value FROM metadata"))
        assert metadata["version"] == PLUGIN_VERSION
        assert metadata["language_code"] == "en"
        assert metadata["language_name"] == "English"
        assert metadata["language_iso6393"] == "eng"
        assert metadata["schema_version"] == "8"
        assert len(metadata["supplement_sha256"]) == 64
        assert len(metadata["wikipron_revision"]) == 40
        assert metadata["wikipron_release"].startswith("v")
        assert metadata["wikipron_profiles"] == "2"
        assert metadata["readable_converter"] == "readable.tsv"
        assert int(metadata["readable_converter_mappings"]) > 0
        assert not any(
            key.startswith("wikipron_") and key.endswith("_sha256")
            for key in metadata
        )
        assert metadata["converter"] == (
            "tools/build_database.py discovery profile schema v5"
        )
        assert database.stat().st_size < 18_000_000
        readable = ROOT / "data" / "en" / "readable.tsv"
        assert readable.read_text(encoding="utf-8").startswith("ipa\treadable\n")
        assert not (ROOT / "data" / "language_hints.tsv").exists()
        assert hashlib.sha256(readable.read_bytes()).hexdigest() == READABLE_SHA256
    finally:
        connection.close()


def check_compact_database_build() -> None:
    with tempfile.TemporaryDirectory(prefix="pronunciation-db-test-") as directory:
        directory = Path(directory)
        supplement = directory / "supplemental.tsv"
        supplement.write_text(
            "word\tipa\tsimple\tregion\tconfidence\tnote\n"
            "projectword\t/ˈpɹɑdʒɛkt/\tPRAH-jekt\tUS\t90\tFixture\n",
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
            supplement=supplement,
        )
        assert headwords > 2 and records > 2
        connection = sqlite3.connect(output)
        try:
            assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
            assert connection.execute("PRAGMA user_version").fetchone()[0] == 8
            assert connection.execute(
                "SELECT COUNT(*) FROM pronunciations WHERE source='CMUdict'"
            ).fetchone()[0] == 0
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
            simple, code, name = connection.execute(
                "SELECT simple, language_code, language_name FROM pronunciations "
                "WHERE word='bonjour' LIMIT 1"
            ).fetchone()
            assert simple
            assert (code, name) == ("fr", "French")
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
        assert sidecar["readable_converter"] == "readable.tsv"
        converter = french_output.parent / "readable.tsv"
        assert converter.read_text(encoding="utf-8").startswith(
            "ipa\treadable\n"
        )

        common = [
            "--wikipron-root", str(tsv),
            "--wikipron-release", "v-test",
            "--wikipron-revision", "test-wikipron-revision",
            "--generated-date", "2026-01-01",
            "--no-g2p",
        ]
        command = [sys.executable, ROOT / "tools" / "build_database.py"]
        default_root = directory / "default-output"
        subprocess.run(command + common + [
            "--data-dir", str(default_root),
            "--supplement", str(supplement),
        ], check=True, capture_output=True, text=True)
        assert default_database_path(default_root, "en").is_file()

        one_root = directory / "one-output"
        subprocess.run(command + common + [
            "--language", "fr-CA", "--data-dir", str(one_root),
        ], check=True, capture_output=True, text=True)
        assert default_database_path(one_root, "fr").is_file()

        ergonomic_root = directory / "ergonomic-output"
        subprocess.run([
            sys.executable, ROOT / "tools" / "build_language_pack.py",
            "fr-CA", *common, "--data-dir", ergonomic_root,
        ], check=True, capture_output=True, text=True)
        assert default_database_path(ergonomic_root, "fr").is_file()

        repeated_root = directory / "repeated-output"
        subprocess.run(command + common + [
            "--language", "fr", "--language", "de",
            "--data-dir", str(repeated_root),
        ], check=True, capture_output=True, text=True)
        assert default_database_path(repeated_root, "fr").is_file()
        assert default_database_path(repeated_root, "de").is_file()

        all_root = directory / "all-output"
        subprocess.run(command + common + [
            "--all", "--data-dir", str(all_root),
            "--supplement", str(supplement),
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

        first_revision = subprocess.run(
            ["git", "-C", upstream, "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

        source.write_text("second\n", encoding="utf-8")
        subprocess.run(["git", "-C", upstream, "add", "source.txt"], check=True)
        subprocess.run(
            ["git", "-C", upstream, "commit", "-m", "second"],
            check=True,
            capture_output=True,
        )
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

        readable = directory / "readable.tsv"
        readable.write_text("ipa\treadable\na\ta\n", encoding="utf-8")
        with release_builder.open("a", encoding="utf-8") as target:
            target.write('READABLE_SHA256 = (\n    "' + "0" * 64 + '"\n)\n')
        readable_hash = synchronize_readable_hash(readable, release_builder)
        assert readable_hash == hashlib.sha256(readable.read_bytes()).hexdigest()
        assert readable_hash in release_builder.read_text(encoding="utf-8")

        g2p = directory / "g2p.bin"
        g2p.write_bytes(b"test g2p")
        with release_builder.open("a", encoding="utf-8") as target:
            target.write('G2P_SHA256 = (\n    "' + "0" * 64 + '"\n)\n')
        g2p_hash = synchronize_g2p_hash(g2p, release_builder)
        assert g2p_hash == hashlib.sha256(g2p.read_bytes()).hexdigest()
        assert g2p_hash in release_builder.read_text(encoding="utf-8")


def check_g2p_model() -> None:
    assert not (ROOT / "data" / "cmu_flite_lts.bin").exists()
    assert not (ROOT / "data" / "cmu_flite_lts.SOURCE.txt").exists()
    assert not (ROOT / "tools" / "build_lts_model.py").exists()
    model = ROOT / "data" / "en" / "g2p.bin"
    data = model.read_bytes()
    assert data[:8] == b"KPG2P4\0\0"
    assert int.from_bytes(data[8:12], "little") == 532_450
    assert int.from_bytes(data[12:16], "little") == 1_450_681
    assert int.from_bytes(data[16:20], "little") == 1
    assert int.from_bytes(data[20:22], "little") == 1_024
    assert int.from_bytes(data[22:24], "little") == 69
    assert data[24:28] == bytes((2, 10, 1, 0))
    assert int.from_bytes(data[28:32], "little") == 81_768
    assert len(data) == 15_814_625
    assert hashlib.sha256(data).hexdigest() == G2P_SHA256
    source = (ROOT / "data" / "en" / "g2p.SOURCE.txt").read_text()
    assert "Model: english_us_arpa" in source
    assert "https://github.com/MontrealCorpusTools/mfa-models" in source
    assert "f079ae88f792458fa7c123b256e5b86cc55c29ac2ffc457c673e6c60c36cd143" in source
    assert parse_phone_symbols("<eps>\t0\ne\t1\n<UNK>\t2\n") == ["e"]


def make_test_g2p_archive(path: Path, character: str, phone: str) -> None:
    def string(value: str) -> bytes:
        encoded = value.encode("ascii")
        return len(encoded).to_bytes(4, "little", signed=True) + encoded

    fst = bytearray()
    fst.extend((0x7EB2FDD6).to_bytes(4, "little"))
    fst.extend(string("vector"))
    fst.extend(string("standard"))
    fst.extend((2).to_bytes(4, "little", signed=True))
    fst.extend((0).to_bytes(4, "little", signed=True))
    fst.extend((0).to_bytes(8, "little"))
    fst.extend((0).to_bytes(8, "little", signed=True))
    fst.extend((2).to_bytes(8, "little", signed=True))
    fst.extend((1).to_bytes(8, "little", signed=True))
    fst.extend(struct.pack("<fq", float("inf"), 1))
    fst.extend(struct.pack("<iifi", ord(character), 1, 0.0, 1))
    fst.extend(struct.pack("<fq", 0.0, 0))
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("fixture/meta.json", json.dumps({
            "architecture": "pynini", "name": "Fixture", "version": "1",
            "phones": [phone],
        }))
        archive.writestr(
            "fixture/phones.sym", f"<eps>\t0\n{phone}\t1\n<UNK>\t2\n"
        )
        archive.writestr("fixture/model.fst", fst)


def check_automatic_g2p_resolution() -> None:
    def release(tag: str, architecture: str, published: str) -> dict:
        model_name = tag[4:tag.rfind("-v")]
        return {
            "tag_name": tag,
            "draft": False,
            "prerelease": False,
            "published_at": published,
            "html_url": f"https://example.test/releases/{tag}",
            "body": (
                "## Model details\n"
                "- **Language:** [French](https://example.test/french)\n"
                f"- **Architecture:** `{architecture}`\n"
                "- **License:** [CC BY 4.0](https://example.test/license)\n"
            ),
            "assets": [{
                "name": f"{model_name}.zip",
                "browser_download_url": "https://example.test/french.zip",
            }],
        }

    catalog = [
        release("g2p-french_mfa-v3.0.0", "phonetisaurus", "2024-03-01"),
        release("g2p-french_mfa-v2.0.0a", "pynini", "2022-06-01"),
        release("g2p-french_mfa-v2.0.0", "pynini", "2022-04-01"),
    ]

    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.close()

    requests = []

    def catalog_opener(request, timeout):
        requests.append((request.full_url, timeout))
        return Response(json.dumps(catalog).encode())

    models = fetch_mfa_models(opener=catalog_opener)
    assert len(models) == 2
    selected = resolve_mfa_model("fr", "French", models)
    assert selected and selected.tag == "g2p-french_mfa-v2.0.0"
    assert requests == [(
        "https://api.github.com/repos/MontrealCorpusTools/mfa-models/releases"
        "?per_page=100&page=1",
        30,
    )]

    with tempfile.TemporaryDirectory(prefix="pronunciation-auto-g2p-") as directory:
        directory = Path(directory)
        archive = directory / "source.zip"
        make_test_g2p_archive(archive, "é", "e")
        archive_bytes = archive.read_bytes()

        def download_opener(request, timeout):
            assert request.full_url == "https://example.test/french.zip"
            assert timeout == 120
            return Response(archive_bytes)

        data_dir = directory / "data"
        pack = data_dir / "fr"
        pack.mkdir(parents=True)
        (pack / "pack.tsv").write_text(
            "language_code\tfr\nlanguage_name\tFrench\n",
            encoding="utf-8",
        )
        assert build_language_g2p(
            "fr", "French", data_dir, directory / "sources", models,
            opener=download_opener,
        )
        assert (pack / "g2p.bin").read_bytes()[:8] == b"KPG2P4\0\0"
        provenance = (pack / "g2p.SOURCE.txt").read_text(encoding="utf-8")
        assert "Release: g2p-french_mfa-v2.0.0" in provenance
        assert "License: CC BY 4.0" in provenance

        def unexpected_download(*_args, **_kwargs):
            raise AssertionError("cached model archive was downloaded again")

        assert build_language_g2p(
            "fr", "French", data_dir, directory / "sources", models,
            opener=unexpected_download,
        )
        assert not build_language_g2p(
            "zz", "No Such Language", data_dir, directory / "sources",
            models, opener=download_opener,
        )

    def failing_opener(*_args, **_kwargs):
        raise OSError("offline")

    try:
        fetch_mfa_models(opener=failing_opener)
    except RuntimeError as error:
        assert "--no-g2p" in str(error)
    else:
        raise AssertionError("MFA catalog failure was silently ignored")


def check_multilingual_g2p_build() -> None:
    with tempfile.TemporaryDirectory(prefix="pronunciation-g2p-test-") as directory:
        directory = Path(directory)
        en_archive = directory / "en.zip"
        fr_archive = directory / "fr.zip"
        make_test_g2p_archive(en_archive, "a", "æ")
        make_test_g2p_archive(fr_archive, "é", "e")
        output = directory / "direct.bin"
        states, arcs, metadata = build_model(fr_archive, output)
        assert (states, arcs, metadata["architecture"]) == (2, 1, "pynini")
        packed = output.read_bytes()
        assert packed[:8] == b"KPG2P4\0\0"
        assert packed[26] == 2  # IPA output symbols

        packs = directory / "packs"
        for code, name in (("en", "English"), ("fr", "French")):
            pack = packs / code
            pack.mkdir(parents=True)
            (pack / "pack.tsv").write_text(
                f"language_code\t{code}\nlanguage_name\t{name}\n",
                encoding="utf-8",
            )
        subprocess.run([
            sys.executable, ROOT / "tools" / "build_g2p_model.py",
            "--language", "en", "--model-archive", en_archive,
            "--language", "fr", "--model-archive", fr_archive,
            "--data-dir", packs,
        ], check=True, capture_output=True, text=True)
        for code in ("en", "fr"):
            assert (packs / code / "g2p.bin").read_bytes()[:8] == b"KPG2P4\0\0"
            assert (packs / code / "g2p.SOURCE.txt").is_file()
            assert "g2p_model\tg2p.bin" in (packs / code / "pack.tsv").read_text()

        all_packs = directory / "all-packs"
        subprocess.run([
            sys.executable, ROOT / "tools" / "build_g2p_model.py",
            "--all", "--models-dir", directory, "--data-dir", all_packs,
        ], check=True, capture_output=True, text=True)
        assert {
            path.parent.name for path in all_packs.glob("*/g2p.bin")
        } == {"en", "fr"}

        conflict = subprocess.run([
            sys.executable, ROOT / "tools" / "build_g2p_model.py",
            "--all", "--models-dir", directory, "--language", "fr",
        ], capture_output=True, text=True)
        assert conflict.returncode != 0
        assert "cannot be combined" in conflict.stderr


def check_release_build() -> None:
    assert read_plugin_version() == PLUGIN_VERSION
    assert "data/en/pronunciations.sqlite3" in RELEASE_FILES
    assert "data/en/readable.tsv" in RELEASE_FILES
    assert "data/en/g2p.bin" in RELEASE_FILES
    assert "data/pronunciations.sqlite3" not in RELEASE_FILES
    assert "data/mfa_english_g2p.bin" not in RELEASE_FILES
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
        assert installed_size < 35_000_000
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
    check_database()
    check_compact_database_build()
    check_latest_release_resolution()
    check_source_checkout_update()
    check_release_preparation()
    check_g2p_model()
    check_automatic_g2p_resolution()
    check_multilingual_g2p_build()
    check_release_build()
    print("database regression tests: OK")
