#!/usr/bin/env python3
"""Regression checks for the generated pronunciation database."""

from __future__ import annotations

import hashlib
import sqlite3
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))

from build_database import arpabet_to_ipa, arpabet_to_readable  # noqa: E402


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
    connection = sqlite3.connect(database)
    try:
        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
        assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(pronunciations)")
        }
        assert {"region", "simple_approx"} <= columns
        headwords, records = connection.execute(
            "SELECT COUNT(DISTINCT word), COUNT(*) FROM pronunciations"
        ).fetchone()
        assert headwords >= 137_500
        assert records >= 155_000

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
        assert ("/eu̯s̺kaɾa/", None) in pronunciations("euskara")
        basque = connection.execute(
            "SELECT source, region, simple_approx FROM pronunciations "
            "WHERE word = 'euskara' AND ipa = '/eu̯s̺kaɾa/'"
        ).fetchone()
        assert basque == ("WikiPron/Wiktionary", "Basque", 1)
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
        assert metadata["wikipron_eus_sha256"] == (
            "9e4301ed2f86e060a43fa8fb06f9b2590df284c9a54ed373bbae2d002a0bfac0"
        )
        assert metadata["wikipron_eus_records"] == "20058"
    finally:
        connection.close()


def check_lts_model() -> None:
    model = ROOT / "data" / "cmu_flite_lts.bin"
    data = model.read_bytes()
    assert data[:8] == b"KPLTS1\0\0"
    state_count = int.from_bytes(data[8:10], "little")
    assert state_count == 25_505
    assert data[10] == 26
    assert data[11] == 75
    assert len(data) < 200_000
    assert hashlib.sha256(data).hexdigest() == (
        "f2d7c39eee26212e34db62fc712f88365de5033fa7b4ade817bc27d3896aa2a1"
    )
    source = (ROOT / "data" / "cmu_flite_lts.SOURCE.txt").read_text()
    assert "6c9f20dc915b17f5619340069889db0aa007fcdc" in source


if __name__ == "__main__":
    check_conversion()
    check_database()
    check_lts_model()
    print("database regression tests: OK")
