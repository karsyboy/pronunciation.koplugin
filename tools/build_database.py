#!/usr/bin/env python3
"""Build the bundled KOReader pronunciation database from CMUdict."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import os
import re
import sqlite3
from pathlib import Path


PLUGIN_VERSION = "0.5.0"
VOWELS = {
    "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER",
    "EY", "IH", "IY", "OW", "OY", "UH", "UW",
}
LAX_VOWELS = {"AE", "AH", "EH", "IH", "UH"}

IPA = {
    "AA": "ɑ", "AE": "æ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ",
    "EH": "ɛ", "EY": "eɪ", "IH": "ɪ", "IY": "i", "OW": "oʊ",
    "OY": "ɔɪ", "UH": "ʊ", "UW": "u",
    "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "F": "f",
    "G": "ɡ", "HH": "h", "JH": "dʒ", "K": "k", "L": "l",
    "M": "m", "N": "n", "NG": "ŋ", "P": "p", "R": "ɹ",
    "S": "s", "SH": "ʃ", "T": "t", "TH": "θ", "V": "v",
    "W": "w", "Y": "j", "Z": "z", "ZH": "ʒ",
}

READABLE = {
    "AA": "ah", "AE": "a", "AH": "uh", "AO": "aw",
    "AW": "ow", "AY": "eye", "EH": "eh", "ER": "er",
    "EY": "ay", "IH": "ih", "IY": "ee", "OW": "oh",
    "OY": "oy", "UH": "uu", "UW": "oo",
    "B": "b", "CH": "ch", "D": "d", "DH": "th", "F": "f",
    "G": "g", "HH": "h", "JH": "j", "K": "k", "L": "l",
    "M": "m", "N": "n", "NG": "ng", "P": "p", "R": "r",
    "S": "s", "SH": "sh", "T": "t", "TH": "th", "V": "v",
    "W": "w", "Y": "y", "Z": "z", "ZH": "zh",
}

VALID_ONSETS = {
    ("P", "R"), ("P", "L"), ("P", "Y"),
    ("B", "R"), ("B", "L"), ("B", "Y"),
    ("T", "R"), ("T", "W"), ("T", "Y"),
    ("D", "R"), ("D", "W"), ("D", "Y"),
    ("K", "R"), ("K", "L"), ("K", "W"), ("K", "Y"),
    ("G", "R"), ("G", "L"), ("G", "W"), ("G", "Y"),
    ("F", "R"), ("F", "L"), ("F", "Y"),
    ("V", "R"), ("V", "Y"), ("TH", "R"),
    ("SH", "R"), ("CH", "R"), ("JH", "R"),
    ("S", "P"), ("S", "T"), ("S", "K"),
    ("S", "M"), ("S", "N"), ("S", "L"), ("S", "W"),
    ("S", "P", "R"), ("S", "P", "L"),
    ("S", "T", "R"), ("S", "K", "R"), ("S", "K", "W"),
}


def base_phone(phone: str) -> str:
    return re.sub(r"[012]$", "", phone)


def stress(phone: str) -> int | None:
    match = re.search(r"([012])$", phone)
    return int(match.group(1)) if match else None


def choose_onset_length(
    phones: list[str], previous_vowel: int, vowel_index: int
) -> int:
    cluster_length = vowel_index - previous_vowel - 1
    if cluster_length <= 0:
        return 0

    maximum = min(3, cluster_length)
    previous = phones[previous_vowel]
    if stress(previous) == 1 and base_phone(previous) in LAX_VOWELS:
        maximum = min(maximum, cluster_length - 1)

    for length in range(maximum, 0, -1):
        cluster = tuple(base_phone(p) for p in phones[vowel_index - length:vowel_index])
        if length == 1:
            if cluster[0] != "NG":
                return 1
        elif cluster in VALID_ONSETS:
            return length
    return 0


def syllable_starts(phones: list[str]) -> tuple[list[int], list[int]]:
    vowels = [i for i, phone in enumerate(phones) if base_phone(phone) in VOWELS]
    if not vowels:
        return [0], []
    starts = [0]
    for previous_vowel, vowel_index in zip(vowels, vowels[1:]):
        starts.append(vowel_index - choose_onset_length(
            phones, previous_vowel, vowel_index
        ))
    return starts, vowels


def vowel_ipa(phone: str) -> str:
    base = base_phone(phone)
    phone_stress = stress(phone)
    if base == "AH":
        return "ə" if phone_stress == 0 else "ʌ"
    if base == "ER":
        return "ɚ" if phone_stress == 0 else "ɝ"
    return IPA[base]


def arpabet_to_ipa(phones: list[str]) -> str:
    starts, vowels = syllable_starts(phones)
    markers: dict[int, str] = {}
    for start, vowel_index in zip(starts, vowels):
        phone_stress = stress(phones[vowel_index])
        if phone_stress == 1:
            markers[start] = "ˈ"
        elif phone_stress == 2:
            markers[start] = "ˌ"

    output: list[str] = []
    for index, phone in enumerate(phones):
        if index in markers:
            output.append(markers[index])
        base = base_phone(phone)
        output.append(vowel_ipa(phone) if base in VOWELS else IPA[base])
    return "/" + "".join(output) + "/"


def arpabet_to_readable(phones: list[str]) -> str:
    starts, vowels = syllable_starts(phones)
    if not vowels:
        return "".join(READABLE[base_phone(phone)] for phone in phones).upper()
    syllables: list[str] = []
    for index, (start, vowel_index) in enumerate(zip(starts, vowels)):
        end = starts[index + 1] if index + 1 < len(starts) else len(phones)
        chunks = []
        for phone in phones[start:end]:
            readable = READABLE[base_phone(phone)]
            if base_phone(phone) == "IH" and stress(phone) == 1:
                readable = "i"
            chunks.append(readable)
        text = "".join(chunks)
        if stress(phones[vowel_index]) == 1 or (len(starts) == 1 and stress(phones[vowel_index]) is None):
            text = text.upper()
        syllables.append(text)
    return "-".join(syllables)


def parse_cmudict(path: Path):
    with path.open(encoding="utf-8") as source:
        for line_number, raw_line in enumerate(source, 1):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            data = line.split(" #", 1)[0].split()
            if len(data) < 2:
                raise ValueError(f"invalid CMUdict line {line_number}: {raw_line!r}")
            word = re.sub(r"\(\d+\)$", "", data[0]).lower()
            phones = data[1:]
            unknown = sorted(
                {base_phone(phone) for phone in phones} - (set(IPA) | VOWELS)
            )
            if unknown:
                raise ValueError(
                    f"unknown phone(s) {unknown} on CMUdict line {line_number}"
                )
            yield (
                word,
                arpabet_to_ipa(phones),
                " ".join(phones),
                arpabet_to_readable(phones),
                "CMUdict",
                80,
                "Stress-aware General American IPA generated from CMUdict ARPABET.",
                "US",
                0,
            )


def parse_supplement(path: Path):
    with path.open(encoding="utf-8", newline="") as source:
        for row in csv.DictReader(source, delimiter="\t"):
            yield (
                row["word"].strip().lower(),
                row["ipa"].strip(),
                None,
                row["simple"].strip(),
                "Curated supplement",
                int(row["confidence"]),
                row["note"].strip(),
                row["region"].strip() or None,
                0,
            )


def parse_wikipron(path: Path, language_code: str, language_name: str):
    """Load a WikiPron broad TSV, removing its phoneme-segmentation spaces."""
    with path.open(encoding="utf-8") as source:
        for line_number, raw_line in enumerate(source, 1):
            line = raw_line.rstrip("\r\n")
            if not line:
                continue
            try:
                word, segmented_ipa = line.split("\t", 1)
            except ValueError as error:
                raise ValueError(
                    f"invalid WikiPron line {line_number}: {raw_line!r}"
                ) from error
            word = word.strip().casefold()
            ipa = re.sub(r"\s+", "", segmented_ipa)
            if not word or not ipa:
                continue
            yield (
                word,
                f"/{ipa}/",
                None,
                None,
                "WikiPron/Wiktionary",
                78,
                f"Exact {language_name} IPA mined from Wiktionary by WikiPron.",
                language_name,
                1,
            )


def parse_language_hints(path: Path):
    with path.open(encoding="utf-8", newline="") as source:
        for row in csv.DictReader(source, delimiter="\t"):
            yield (
                row["word"].strip().casefold(),
                row["language_code"].strip().lower(),
                row["language_name"].strip(),
                row["source"].strip(),
                row["note"].strip(),
            )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


SCHEMA = """
CREATE TABLE pronunciations (
    word TEXT NOT NULL,
    ipa TEXT NOT NULL,
    arpabet TEXT,
    simple TEXT,
    source TEXT NOT NULL,
    confidence INTEGER NOT NULL DEFAULT 80,
    note TEXT,
    region TEXT,
    simple_approx INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (word, ipa, source)
);
CREATE INDEX idx_pron_word ON pronunciations(word);
CREATE TABLE language_hints (
    word TEXT NOT NULL,
    language_code TEXT NOT NULL,
    language_name TEXT NOT NULL,
    source TEXT NOT NULL,
    note TEXT,
    PRIMARY KEY (word, language_code, source)
);
CREATE INDEX idx_language_hint_word ON language_hints(word);
CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
PRAGMA user_version = 4;
"""


def build_database(
    cmudict: Path,
    supplement: Path,
    language_hints: Path,
    wikipron_sources: list[tuple[Path, str, str]],
    output: Path,
    revision: str,
    wikipron_revision: str,
) -> tuple[int, int]:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    if temporary.exists():
        temporary.unlink()

    connection = sqlite3.connect(temporary)
    try:
        connection.execute("PRAGMA journal_mode=OFF")
        connection.execute("PRAGMA synchronous=OFF")
        connection.executescript(SCHEMA)
        insert = """
            INSERT OR IGNORE INTO pronunciations
                (word, ipa, arpabet, simple, source, confidence, note,
                 region, simple_approx)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        connection.executemany(insert, parse_cmudict(cmudict))
        connection.executemany(insert, parse_supplement(supplement))
        wikipron_counts = {}
        for path, language_code, language_name in wikipron_sources:
            before = connection.total_changes
            connection.executemany(
                insert, parse_wikipron(path, language_code, language_name)
            )
            wikipron_counts[language_code] = connection.total_changes - before
        connection.executemany(
            """
            INSERT OR IGNORE INTO language_hints
                (word, language_code, language_name, source, note)
            VALUES (?, ?, ?, ?, ?)
            """,
            parse_language_hints(language_hints),
        )
        headwords, records = connection.execute(
            "SELECT COUNT(DISTINCT word), COUNT(*) FROM pronunciations"
        ).fetchone()
        metadata = {
            "name": "KOReader Pronunciation",
            "version": PLUGIN_VERSION,
            "generated": dt.datetime.now(dt.timezone.utc).date().isoformat(),
            "base": "CMU Pronouncing Dictionary"
                    + (" + WikiPron" if wikipron_sources else ""),
            "cmudict_revision": revision,
            "cmudict_url": "https://github.com/cmusphinx/cmudict",
            "supplement_sha256": sha256(supplement),
            "language_hints_sha256": sha256(language_hints),
            "headwords": str(headwords),
            "records": str(records),
            "converter": "tools/build_database.py multilingual schema v2",
        }
        if wikipron_sources:
            metadata.update({
                "wikipron_revision": wikipron_revision,
                "wikipron_url": "https://github.com/CUNY-CL/wikipron",
                "wikipron_license": "CC BY-SA 4.0 (Wiktionary data)",
            })
            for path, language_code, _ in wikipron_sources:
                metadata[f"wikipron_{language_code}_sha256"] = sha256(path)
                metadata[f"wikipron_{language_code}_records"] = str(
                    wikipron_counts[language_code]
                )
        connection.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)", metadata.items()
        )
        connection.commit()
        connection.execute("ANALYZE")
        connection.execute("VACUUM")
        check = connection.execute("PRAGMA quick_check").fetchone()[0]
        if check != "ok":
            raise RuntimeError(f"SQLite quick_check failed: {check}")
    finally:
        connection.close()

    os.replace(temporary, output)
    return headwords, records


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmudict", required=True, type=Path)
    parser.add_argument("--supplement", type=Path,
                        default=Path("data/supplemental.tsv"))
    parser.add_argument("--language-hints", type=Path,
                        default=Path("data/language_hints.tsv"))
    parser.add_argument(
        "--wikipron", nargs=3, action="append", default=[],
        metavar=("TSV", "LANGUAGE_CODE", "LANGUAGE_NAME"),
        help="add an exact WikiPron TSV; may be repeated",
    )
    parser.add_argument("--wikipron-revision", default="")
    parser.add_argument("--output", type=Path,
                        default=Path("data/pronunciations.sqlite3"))
    parser.add_argument("--cmudict-revision", required=True)
    args = parser.parse_args()
    wikipron_sources = [
        (Path(path), language_code, language_name)
        for path, language_code, language_name in args.wikipron
    ]
    if wikipron_sources and not args.wikipron_revision:
        parser.error("--wikipron-revision is required with --wikipron")
    headwords, records = build_database(
        args.cmudict,
        args.supplement,
        args.language_hints,
        wikipron_sources,
        args.output,
        args.cmudict_revision,
        args.wikipron_revision,
    )
    print(f"built {args.output}: {headwords} headwords, {records} records")


if __name__ == "__main__":
    main()
