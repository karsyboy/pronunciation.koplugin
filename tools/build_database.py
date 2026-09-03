#!/usr/bin/env python3
"""Build the bundled database from CMUdict and selected WikiPron broad TSVs."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import os
import re
import sqlite3
import subprocess
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN_VERSION = "0.5.1"
DEFAULT_SOURCES_DIR = ROOT / "pronunciation-sources"
CMUDICT_REPOSITORY = "https://github.com/cmusphinx/cmudict.git"
WIKIPRON_REPOSITORY = "https://github.com/CUNY-CL/wikipron.git"


@dataclass(frozen=True)
class WikiPronSource:
    path: Path
    source_id: str
    language_code: str
    language_name: str
    region: str | None = None


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
                row["word"].strip().casefold(),
                row["ipa"].strip(),
                None,
                row["simple"].strip(),
                "Curated supplement",
                int(row["confidence"]),
                row["note"].strip(),
                row["region"].strip() or None,
                0,
            )


def parse_wikipron(source: WikiPronSource):
    """Load a WikiPron broad TSV, removing its phoneme-segmentation spaces."""
    location = (
        f"{source.region} {source.language_name}"
        if source.region else source.language_name
    )
    with source.path.open(encoding="utf-8") as tsv:
        for line_number, raw_line in enumerate(tsv, 1):
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
                f"Exact {location} IPA mined from Wiktionary by WikiPron.",
                source.region or source.language_name,
                1,
            )


def load_wikipron_manifest(path: Path, tsv_root: Path) -> list[WikiPronSource]:
    """Resolve and verify the curated set of distributable broad-IPA inputs."""
    required = {
        "filename", "source_id", "language_code", "language_name",
        "region", "sha256",
    }
    sources = []
    seen_ids = set()
    with path.open(encoding="utf-8", newline="") as manifest:
        reader = csv.DictReader(manifest, delimiter="\t")
        missing = required - set(reader.fieldnames or ())
        if missing:
            raise ValueError(f"WikiPron manifest is missing columns: {sorted(missing)}")
        for line_number, row in enumerate(reader, 2):
            filename = row["filename"].strip()
            relative = Path(filename)
            if (not filename or relative.is_absolute() or ".." in relative.parts
                    or not filename.endswith("_broad.tsv")):
                raise ValueError(
                    f"invalid WikiPron broad TSV on manifest line {line_number}: "
                    f"{filename!r}"
                )
            source_id = row["source_id"].strip().lower()
            if not re.fullmatch(r"[a-z0-9_]+", source_id):
                raise ValueError(
                    f"invalid WikiPron source_id on line {line_number}: "
                    f"{source_id!r}"
                )
            if source_id in seen_ids:
                raise ValueError(f"duplicate WikiPron source_id: {source_id}")
            seen_ids.add(source_id)
            expected_hash = row["sha256"].strip().lower()
            if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
                raise ValueError(
                    f"invalid WikiPron SHA-256 on line {line_number}"
                )
            tsv_path = tsv_root / relative
            if not tsv_path.is_file():
                raise FileNotFoundError(f"WikiPron TSV is missing: {tsv_path}")
            actual_hash = sha256(tsv_path)
            if actual_hash != expected_hash:
                raise ValueError(
                    f"WikiPron SHA-256 mismatch for {filename}: expected "
                    f"{expected_hash}, found {actual_hash}"
                )
            language_code = row["language_code"].strip().lower()
            language_name = row["language_name"].strip()
            if not language_code or not language_name:
                raise ValueError(
                    f"missing WikiPron language on manifest line {line_number}"
                )
            sources.append(WikiPronSource(
                path=tsv_path,
                source_id=source_id,
                language_code=language_code,
                language_name=language_name,
                region=row["region"].strip() or None,
            ))
    if not sources:
        raise ValueError("WikiPron manifest contains no broad-IPA sources")
    return sources


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


def run_git(*arguments: str | Path) -> str:
    command = ["git", *(str(argument) for argument in arguments)]
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise RuntimeError(
            "Git is required to download the pronunciation sources"
        ) from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"Git command failed: {detail}")
    return result.stdout.strip()


def sync_git_checkout(repository: str, checkout: Path) -> str:
    """Clone or update a clean, tool-managed checkout to upstream HEAD."""
    checkout = checkout.resolve()
    checkout.parent.mkdir(parents=True, exist_ok=True)
    if checkout.exists():
        if not (checkout / ".git").exists():
            raise RuntimeError(
                f"source directory exists but is not a Git checkout: {checkout}"
            )
        remote = run_git("-C", checkout, "remote", "get-url", "origin")
        if remote != repository:
            raise RuntimeError(
                f"source checkout has an unexpected origin: {checkout}"
            )
        if run_git("-C", checkout, "status", "--porcelain"):
            raise RuntimeError(
                f"source checkout has local changes; clean it before updating: "
                f"{checkout}"
            )
        print(f"Updating {checkout.name} from {repository}")
        run_git("-C", checkout, "fetch", "--depth", "1", "origin", "HEAD")
        run_git("-C", checkout, "checkout", "--detach", "FETCH_HEAD")
    else:
        print(f"Downloading {checkout.name} from {repository}")
        run_git("clone", "--depth", "1", repository, checkout)

    revision = run_git("-C", checkout, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError(f"could not determine source revision for {checkout}")
    return revision


def refresh_wikipron_manifest(path: Path, tsv_root: Path) -> bool:
    """Update hashes for the allowlisted TSVs after fetching WikiPron."""
    with path.open(encoding="utf-8", newline="") as manifest:
        reader = csv.DictReader(manifest, delimiter="\t")
        fieldnames = reader.fieldnames
        required = {"filename", "sha256"}
        missing = required - set(fieldnames or ())
        if missing:
            raise ValueError(
                f"WikiPron manifest is missing columns: {sorted(missing)}"
            )
        rows = list(reader)

    changed = False
    for line_number, row in enumerate(rows, 2):
        filename = row["filename"].strip()
        relative = Path(filename)
        if (not filename or relative.is_absolute() or ".." in relative.parts
                or not filename.endswith("_broad.tsv")):
            raise ValueError(
                f"invalid WikiPron broad TSV on manifest line {line_number}: "
                f"{filename!r}"
            )
        source = tsv_root / relative
        if not source.is_file():
            raise FileNotFoundError(f"WikiPron TSV is missing: {source}")
        actual_hash = sha256(source)
        if row["sha256"].strip().lower() != actual_hash:
            row["sha256"] = actual_hash
            changed = True

    if changed:
        temporary = path.with_name(path.name + ".tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="") as manifest:
                writer = csv.DictWriter(
                    manifest,
                    fieldnames=fieldnames,
                    delimiter="\t",
                    lineterminator="\n",
                )
                writer.writeheader()
                writer.writerows(rows)
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()
        print(f"Updated WikiPron hashes in {path}")
    return changed


def iso_date(value: str) -> str:
    try:
        parsed = dt.date.fromisoformat(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "date must use YYYY-MM-DD format"
        ) from error
    if parsed.isoformat() != value:
        raise argparse.ArgumentTypeError("date must use YYYY-MM-DD format")
    return value


SCHEMA = """
CREATE TABLE pronunciation_sources (
    id INTEGER NOT NULL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
) WITHOUT ROWID;
CREATE TABLE pronunciation_profiles (
    id INTEGER NOT NULL PRIMARY KEY,
    source_id INTEGER NOT NULL,
    confidence INTEGER NOT NULL,
    note TEXT,
    region TEXT,
    simple_approx INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TABLE pronunciation_entries (
    word TEXT NOT NULL,
    ipa TEXT NOT NULL,
    arpabet TEXT,
    simple TEXT,
    profile_id INTEGER NOT NULL,
    PRIMARY KEY (word, ipa, profile_id)
) WITHOUT ROWID;
CREATE VIEW pronunciations AS
SELECT e.word, e.ipa, e.arpabet, e.simple, s.name AS source,
       p.confidence, p.note, p.region, p.simple_approx
  FROM pronunciation_entries AS e
  JOIN pronunciation_profiles AS p ON p.id = e.profile_id
  JOIN pronunciation_sources AS s ON s.id = p.source_id;
CREATE TABLE language_hints (
    word TEXT NOT NULL,
    language_code TEXT NOT NULL,
    language_name TEXT NOT NULL,
    source TEXT NOT NULL,
    note TEXT,
    PRIMARY KEY (word, language_code, source)
) WITHOUT ROWID;
CREATE TABLE metadata (
    key TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;
PRAGMA user_version = 6;
"""


def insert_pronunciations(
    connection: sqlite3.Connection,
    rows,
    source_ids: dict[str, int],
    profile_ids: dict[tuple, int],
) -> int:
    """Normalize repeated source metadata while streaming pronunciation rows."""
    insert = """
        INSERT OR IGNORE INTO pronunciation_entries
            (word, ipa, arpabet, simple, profile_id)
        VALUES (?, ?, ?, ?, ?)
    """
    batch = []
    inserted = 0

    def flush() -> None:
        nonlocal inserted
        if not batch:
            return
        cursor = connection.executemany(insert, batch)
        inserted += max(cursor.rowcount, 0)
        batch.clear()

    for row in rows:
        word, ipa, arpabet, simple, source, confidence, note, region, approx = row
        source_id = source_ids.get(source)
        if source_id is None:
            source_id = len(source_ids) + 1
            source_ids[source] = source_id
            connection.execute(
                "INSERT INTO pronunciation_sources(id, name) VALUES (?, ?)",
                (source_id, source),
            )

        profile = (source_id, confidence, note, region, approx)
        profile_id = profile_ids.get(profile)
        if profile_id is None:
            profile_id = len(profile_ids) + 1
            profile_ids[profile] = profile_id
            connection.execute(
                "INSERT INTO pronunciation_profiles VALUES (?, ?, ?, ?, ?, ?)",
                (profile_id, *profile),
            )

        batch.append((word, ipa, arpabet, simple, profile_id))
        if len(batch) >= 5000:
            flush()
    flush()
    return inserted


def build_database(
    cmudict: Path,
    supplement: Path,
    language_hints: Path,
    wikipron_sources: list[WikiPronSource],
    output: Path,
    revision: str,
    wikipron_revision: str,
    generated_date: str | None = None,
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
        source_ids: dict[str, int] = {}
        profile_ids: dict[tuple, int] = {}
        insert_pronunciations(
            connection, parse_cmudict(cmudict), source_ids, profile_ids
        )
        insert_pronunciations(
            connection, parse_supplement(supplement), source_ids, profile_ids
        )
        wikipron_counts = {}
        for source in wikipron_sources:
            wikipron_counts[source.source_id] = insert_pronunciations(
                connection,
                parse_wikipron(source),
                source_ids,
                profile_ids,
            )
        connection.executemany(
            """
            INSERT OR IGNORE INTO language_hints
                (word, language_code, language_name, source, note)
            VALUES (?, ?, ?, ?, ?)
            """,
            parse_language_hints(language_hints),
        )
        headwords, records = connection.execute(
            "SELECT COUNT(DISTINCT word), COUNT(*) FROM pronunciation_entries"
        ).fetchone()
        metadata = {
            "name": "KOReader Pronunciation",
            "version": PLUGIN_VERSION,
            "generated": (
                generated_date
                or dt.datetime.now(dt.timezone.utc).date().isoformat()
            ),
            "base": "CMU Pronouncing Dictionary"
                    + (" + WikiPron" if wikipron_sources else ""),
            "cmudict_revision": revision,
            "cmudict_url": "https://github.com/cmusphinx/cmudict",
            "supplement_sha256": sha256(supplement),
            "language_hints_sha256": sha256(language_hints),
            "headwords": str(headwords),
            "records": str(records),
            "converter": "tools/build_database.py manifest profile schema v4",
        }
        if wikipron_sources:
            metadata.update({
                "wikipron_revision": wikipron_revision,
                "wikipron_url": "https://github.com/CUNY-CL/wikipron",
                "wikipron_license": "CC BY-SA 4.0 (Wiktionary data)",
            })
            for source in wikipron_sources:
                key = f"wikipron_{source.source_id}"
                metadata[f"{key}_sha256"] = sha256(source.path)
                metadata[f"{key}_records"] = str(
                    wikipron_counts[source.source_id]
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
    parser.add_argument(
        "--sources-dir",
        type=Path,
        default=DEFAULT_SOURCES_DIR,
        help=(
            "automatic CMUdict and WikiPron checkout directory "
            "(default: pronunciation-sources)"
        ),
    )
    parser.add_argument(
        "--cmudict",
        type=Path,
        help="use a local cmudict.dict instead of downloading latest CMUdict",
    )
    parser.add_argument("--supplement", type=Path,
                        default=ROOT / "data" / "supplemental.tsv")
    parser.add_argument("--language-hints", type=Path,
                        default=ROOT / "data" / "language_hints.tsv")
    parser.add_argument(
        "--wikipron-manifest", type=Path,
        default=ROOT / "data" / "wikipron_sources.tsv",
        help="curated WikiPron broad-IPA source manifest",
    )
    parser.add_argument(
        "--wikipron-root",
        type=Path,
        help=(
            "use a local directory containing the manifest's WikiPron TSV "
            "files instead of downloading latest WikiPron"
        ),
    )
    parser.add_argument("--wikipron-revision", default="")
    parser.add_argument(
        "--generated-date",
        type=iso_date,
        help="UTC build date to record (YYYY-MM-DD; set for reproducible builds)",
    )
    parser.add_argument("--output", type=Path,
                        default=ROOT / "data" / "pronunciations.sqlite3")
    parser.add_argument("--cmudict-revision", default="")
    args = parser.parse_args()

    local_sources = args.cmudict is not None or args.wikipron_root is not None
    if local_sources:
        if args.cmudict is None or args.wikipron_root is None:
            parser.error(
                "--cmudict and --wikipron-root must be provided together"
            )
        if not args.cmudict_revision:
            parser.error("--cmudict-revision is required with local sources")
        if not args.wikipron_revision:
            parser.error("--wikipron-revision is required with local sources")
        cmudict = args.cmudict
        wikipron_root = args.wikipron_root
        cmudict_revision = args.cmudict_revision
        wikipron_revision = args.wikipron_revision
    else:
        if args.cmudict_revision or args.wikipron_revision:
            parser.error(
                "source revisions can only be used with explicit local sources"
            )
        cmudict_checkout = args.sources_dir / "cmudict"
        wikipron_checkout = args.sources_dir / "wikipron"
        cmudict_revision = sync_git_checkout(
            CMUDICT_REPOSITORY, cmudict_checkout
        )
        wikipron_revision = sync_git_checkout(
            WIKIPRON_REPOSITORY, wikipron_checkout
        )
        cmudict = cmudict_checkout / "cmudict.dict"
        wikipron_root = wikipron_checkout / "data" / "scrape" / "tsv"
        refresh_wikipron_manifest(args.wikipron_manifest, wikipron_root)
        print(
            f"Using CMUdict {cmudict_revision} and "
            f"WikiPron {wikipron_revision}"
        )

    wikipron_sources = load_wikipron_manifest(
        args.wikipron_manifest, wikipron_root
    )
    headwords, records = build_database(
        cmudict,
        args.supplement,
        args.language_hints,
        wikipron_sources,
        args.output,
        cmudict_revision,
        wikipron_revision,
        args.generated_date,
    )
    print(f"built {args.output}: {headwords} headwords, {records} records")


if __name__ == "__main__":
    main()
