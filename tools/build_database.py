#!/usr/bin/env python3
"""Build per-language pronunciation databases from a WikiPron release."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from build_release import read_plugin_version


ROOT = Path(__file__).resolve().parents[1]
PLUGIN_VERSION = read_plugin_version()
DEFAULT_SOURCES_DIR = ROOT / "pronunciation-sources"
CMUDICT_REPOSITORY = "https://github.com/cmusphinx/cmudict.git"
WIKIPRON_REPOSITORY = "https://github.com/CUNY-CL/wikipron.git"
WIKIPRON_URL = "https://github.com/CUNY-CL/wikipron"
WIKIPRON_LATEST_RELEASE_API = (
    "https://api.github.com/repos/CUNY-CL/wikipron/releases/latest"
)

# ISO 639-2/B bibliographic aliases which differ from the ISO 639-2/T and
# ISO 639-3 code used by current WikiPron releases.  This is a fixed standards
# compatibility list, not an allowlist of supported languages.
ISO_639_BIBLIOGRAPHIC_ALIASES = {
    "sqi": "alb", "hye": "arm", "eus": "baq", "mya": "bur",
    "zho": "chi", "ces": "cze", "nld": "dut", "fra": "fre",
    "kat": "geo", "deu": "ger", "ell": "gre", "isl": "ice",
    "mkd": "mac", "mri": "mao", "msa": "may", "fas": "per",
    "ron": "rum", "slk": "slo", "bod": "tib", "cym": "wel",
}


@dataclass(frozen=True)
class WikiPronSource:
    path: Path
    source_id: str
    iso6393: str
    language_code: str
    language_name: str
    script: str
    transcription: str
    region: str | None = None
    profile: str | None = None


@dataclass(frozen=True)
class WikiPronLanguage:
    code: str
    iso6393: str
    name: str
    aliases: tuple[str, ...]
    sources: tuple[WikiPronSource, ...]


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
    """Load a WikiPron TSV, removing its phoneme-segmentation spaces."""
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
                f"Exact {source.transcription} {location} IPA mined from "
                f"Wiktionary by WikiPron ({source.path.name}, {source.script}).",
                source.region,
                0,
            )


WIKIPRON_FILENAME = re.compile(
    r"^(?P<iso6393>[a-z]{3})_(?P<script>[a-z]{4})"
    r"(?:_(?P<profile>[a-z0-9_]+?))?"
    r"_(?P<level>broad|narrow)(?P<filtered>_filtered)?\.tsv$"
)


def _wikipron_metadata_paths(tsv_root: Path) -> tuple[Path, Path]:
    """Find WikiPron's release-owned language catalog beside a TSV folder."""
    scrape_root = tsv_root.parent
    return scrape_root / "lib" / "languages.json", scrape_root / "summary.tsv"


def _profile_label(profile: str | None, definition: dict) -> str | None:
    if not profile:
        return None
    configured = definition.get("dialect", {}).get(profile)
    if configured:
        return configured.split("|", 1)[0].strip()
    if len(profile) == 2:
        return profile.upper()
    return profile.replace("_", " ").title()


def _language_aliases(
    base_code: str, iso6393: str, definition: dict
) -> tuple[str, ...]:
    aliases = {base_code, iso6393}
    wiktionary_code = definition.get("wiktionary_code")
    if isinstance(wiktionary_code, str) and re.fullmatch(
        r"[a-z]{2,3}", wiktionary_code.lower()
    ):
        aliases.add(wiktionary_code.lower())
    bibliographic = ISO_639_BIBLIOGRAPHIC_ALIASES.get(iso6393)
    if bibliographic:
        aliases.add(bibliographic)
    return tuple(sorted(aliases))


def discover_wikipron_languages(
    tsv_root: Path,
    languages_path: Path | None = None,
) -> dict[str, WikiPronLanguage]:
    """Discover usable WikiPron language/profile TSVs without an allowlist.

    Unfiltered broad transcriptions are preferred for each language.  If a
    release has no broad transcription for a language, its unfiltered narrow
    transcription is used instead.  All scripts and dialect profiles at the
    selected transcription level are retained in one base-language pack.
    """
    tsv_root = tsv_root.resolve()
    if not tsv_root.is_dir():
        raise FileNotFoundError(f"WikiPron TSV directory is missing: {tsv_root}")
    if languages_path is None:
        languages_path, _ = _wikipron_metadata_paths(tsv_root)
    if not languages_path.is_file():
        raise FileNotFoundError(
            "WikiPron language metadata is missing; expected "
            f"{languages_path} (or pass --wikipron-languages)"
        )
    try:
        definitions = json.loads(languages_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        raise ValueError(
            f"could not read WikiPron language metadata: {languages_path}"
        ) from error
    if not isinstance(definitions, dict):
        raise ValueError(f"invalid WikiPron language metadata: {languages_path}")

    candidates: dict[str, list[tuple[Path, re.Match[str]]]] = {}
    for path in sorted(tsv_root.glob("*.tsv")):
        match = WIKIPRON_FILENAME.fullmatch(path.name)
        if not match or match.group("filtered") or path.stat().st_size == 0:
            continue
        candidates.setdefault(match.group("iso6393"), []).append((path, match))

    discovered: dict[str, WikiPronLanguage] = {}
    for iso6393, files in sorted(candidates.items()):
        definition = definitions.get(iso6393)
        if not isinstance(definition, dict):
            continue
        broad_available = any(
            match.group("level") == "broad" for _, match in files
        )
        level = "broad" if broad_available else "narrow"
        wiktionary_code = str(definition.get("wiktionary_code", "")).lower()
        base_code = (
            wiktionary_code
            if re.fullmatch(r"[a-z]{2}", wiktionary_code)
            else iso6393
        )
        name = str(
            definition.get("wiktionary_name")
            or definition.get("iso639_name")
            or iso6393
        ).strip()
        sources = []
        for path, match in files:
            if match.group("level") != level:
                continue
            script_code = match.group("script")
            script = str(
                definition.get("script", {}).get(script_code)
                or script_code.title()
            )
            profile = match.group("profile")
            sources.append(WikiPronSource(
                path=path,
                source_id=path.stem,
                iso6393=iso6393,
                language_code=base_code,
                language_name=name,
                script=script,
                transcription=level,
                region=_profile_label(profile, definition),
                profile=profile,
            ))
        if not sources:
            continue
        language = WikiPronLanguage(
            code=base_code,
            iso6393=iso6393,
            name=name,
            aliases=_language_aliases(base_code, iso6393, definition),
            sources=tuple(sources),
        )
        if base_code in discovered:
            raise ValueError(
                "WikiPron languages unexpectedly share base code "
                f"{base_code!r}: {discovered[base_code].iso6393}, {iso6393}"
            )
        discovered[base_code] = language
    if not discovered:
        raise ValueError(f"WikiPron release has no usable TSV data in {tsv_root}")
    return discovered


def resolve_requested_language(
    value: str, languages: dict[str, WikiPronLanguage]
) -> str:
    key = value.strip().lower().replace("_", "-").split("-", 1)[0]
    matches = [
        language.code for language in languages.values()
        if key in language.aliases
    ]
    if len(matches) == 1:
        return matches[0]
    available = ", ".join(sorted(languages))
    raise ValueError(
        f"WikiPron release has no usable language matching {value!r}; "
        f"available base codes include: {available}"
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


def latest_github_release(
    api_url: str = WIKIPRON_LATEST_RELEASE_API,
    opener=urllib.request.urlopen,
) -> str:
    """Resolve the latest published stable GitHub release tag."""
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": f"pronunciation.koplugin/{PLUGIN_VERSION}",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(api_url, headers=headers)
    try:
        with opener(request, timeout=30) as response:
            payload = json.load(response)
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as error:
        raise RuntimeError(
            "could not resolve WikiPron's latest stable GitHub Release; "
            "check network/API access or use --wikipron-root with "
            "--wikipron-release for a deterministic local build"
        ) from error
    tag = payload.get("tag_name") if isinstance(payload, dict) else None
    if (not isinstance(tag, str) or not tag.strip()
            or payload.get("draft") or payload.get("prerelease")):
        raise RuntimeError(
            "GitHub returned no usable stable WikiPron release tag"
        )
    return tag.strip()


def sync_git_release_checkout(
    repository: str, checkout: Path, tag: str
) -> str:
    """Put a clean tool-managed checkout at an exact release tag."""
    if not tag or tag in {"HEAD", "main", "master"}:
        raise ValueError(f"invalid release tag: {tag!r}")
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
        try:
            local_release = run_git(
                "-C", checkout, "rev-parse", f"refs/tags/{tag}^{{commit}}"
            )
        except RuntimeError:
            local_release = ""
        current = run_git("-C", checkout, "rev-parse", "HEAD")
        if current == local_release:
            print(f"Using cached WikiPron release {tag}")
            return current
        print(f"Updating {checkout.name} to WikiPron release {tag}")
        run_git("-C", checkout, "fetch", "--depth", "1", "origin", "tag", tag)
    else:
        print(f"Downloading WikiPron release {tag}")
        run_git("clone", "--depth", "1", "--branch", tag, repository, checkout)
    run_git("-C", checkout, "checkout", "--detach", tag)
    revision = run_git("-C", checkout, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise RuntimeError(f"could not determine source revision for {checkout}")
    return revision


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
    language_code TEXT NOT NULL,
    language_name TEXT NOT NULL,
    confidence INTEGER NOT NULL,
    note TEXT,
    region TEXT,
    script TEXT,
    profile TEXT,
    transcription TEXT,
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
       p.confidence, p.note, p.region, p.simple_approx,
       p.language_code, p.language_name, p.script, p.profile, p.transcription
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
PRAGMA user_version = 7;
"""


def insert_pronunciations(
    connection: sqlite3.Connection,
    rows,
    source_ids: dict[str, int],
    profile_ids: dict[tuple, int],
    *,
    language_code: str = "en",
    language_name: str = "English",
    script: str | None = None,
    profile_name: str | None = None,
    transcription: str | None = None,
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

        profile = (
            source_id, language_code, language_name, confidence, note, region,
            script, profile_name, transcription, approx,
        )
        profile_id = profile_ids.get(profile)
        if profile_id is None:
            profile_id = len(profile_ids) + 1
            profile_ids[profile] = profile_id
            connection.execute(
                "INSERT INTO pronunciation_profiles "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (profile_id, *profile),
            )

        batch.append((word, ipa, arpabet, simple, profile_id))
        if len(batch) >= 5000:
            flush()
    flush()
    return inserted


def build_database(
    language: WikiPronLanguage,
    wikipron_sources: list[WikiPronSource] | tuple[WikiPronSource, ...],
    output: Path,
    wikipron_release: str,
    wikipron_revision: str,
    generated_date: str | None = None,
    *,
    cmudict: Path | None = None,
    cmudict_revision: str = "",
    supplement: Path | None = None,
    language_hints: Path | None = None,
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
        if language.code == "en":
            if not cmudict or not supplement or not language_hints:
                raise ValueError(
                    "the English pack requires CMUdict, supplement, and "
                    "language-hint inputs"
                )
            insert_pronunciations(
                connection, parse_cmudict(cmudict), source_ids, profile_ids,
                language_code="en", language_name="English", script="Latin",
                profile_name="us", transcription="broad",
            )
            insert_pronunciations(
                connection, parse_supplement(supplement), source_ids,
                profile_ids, language_code="en", language_name="English",
                script="Latin", transcription="broad",
            )
        wikipron_counts = {}
        for source in wikipron_sources:
            wikipron_counts[source.source_id] = insert_pronunciations(
                connection,
                parse_wikipron(source),
                source_ids,
                profile_ids,
                language_code=source.language_code,
                language_name=source.language_name,
                script=source.script,
                profile_name=source.profile,
                transcription=source.transcription,
            )
        if language.code == "en" and language_hints:
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
            "schema_version": "7",
            "language_code": language.code,
            "language_name": language.name,
            "language_iso6393": language.iso6393,
            "language_aliases": ",".join(language.aliases),
            "generated": (
                generated_date
                or dt.datetime.now(dt.timezone.utc).date().isoformat()
            ),
            "base": (
                "CMU Pronouncing Dictionary + project supplement + WikiPron"
                if language.code == "en" else "WikiPron/Wiktionary"
            ),
            "headwords": str(headwords),
            "records": str(records),
            "converter": "tools/build_database.py discovery profile schema v5",
            "wikipron_release": wikipron_release,
            "wikipron_revision": wikipron_revision,
            "wikipron_url": WIKIPRON_URL,
            "wikipron_license": "CC BY-SA 4.0 (Wiktionary data)",
            "wikipron_attribution": (
                "Wiktionary contributors; extraction by the WikiPron project"
            ),
            "wikipron_profiles": str(len(wikipron_sources)),
        }
        if language.code == "en":
            metadata.update({
                "cmudict_revision": cmudict_revision,
                "cmudict_url": "https://github.com/cmusphinx/cmudict",
                "supplement_sha256": sha256(supplement),
                "language_hints_sha256": sha256(language_hints),
            })
        for index, source in enumerate(wikipron_sources, 1):
            key = f"wikipron_profile_{index}"
            metadata[f"{key}_file"] = source.path.name
            metadata[f"{key}_records"] = str(wikipron_counts[source.source_id])
            metadata[f"{key}_script"] = source.script
            metadata[f"{key}_transcription"] = source.transcription
            if source.region:
                metadata[f"{key}_region"] = source.region
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
    write_pack_metadata(language, output.parent / "pack.tsv")
    return headwords, records


def write_pack_metadata(language: WikiPronLanguage, output: Path) -> None:
    """Write a tiny sidecar so KOReader can list packs without opening SQLite."""
    values = {
        "language_code": language.code,
        "language_name": language.name,
        "iso6393": language.iso6393,
        "aliases": ",".join(language.aliases),
        "schema_version": "7",
    }
    temporary = output.with_name(output.name + ".tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="") as sidecar:
            for key, value in values.items():
                if "\t" in value or "\n" in value:
                    raise ValueError(f"invalid pack metadata value: {value!r}")
                sidecar.write(f"{key}\t{value}\n")
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def default_database_path(data_dir: Path, code: str) -> Path:
    return data_dir / code / "pronunciations.sqlite3"


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
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--language", action="append", metavar="CODE",
        help=(
            "base/ISO language code to build; may be repeated "
            "(default: en)"
        ),
    )
    selection.add_argument(
        "--all", action="store_true",
        help="build every usable language discovered in the WikiPron release",
    )
    parser.add_argument(
        "--wikipron-root",
        type=Path,
        help=(
            "use a local WikiPron data/scrape/tsv directory instead of "
            "resolving the latest stable GitHub Release"
        ),
    )
    parser.add_argument(
        "--wikipron-languages", type=Path,
        help="local languages.json override (normally discovered automatically)",
    )
    parser.add_argument(
        "--wikipron-release", default="",
        help="release/tag provenance (required with --wikipron-root)",
    )
    parser.add_argument(
        "--wikipron-revision", default="",
        help="commit provenance (required with --wikipron-root)",
    )
    parser.add_argument(
        "--generated-date",
        type=iso_date,
        help="UTC build date to record (YYYY-MM-DD; set for reproducible builds)",
    )
    parser.add_argument(
        "--output", type=Path,
        help="database path override; valid only when building one language",
    )
    parser.add_argument(
        "--data-dir", type=Path, default=ROOT / "data",
        help="language-pack output root (default: repository data directory)",
    )
    parser.add_argument("--cmudict-revision", default="")
    args = parser.parse_args()

    if args.wikipron_root:
        if not args.wikipron_release or not args.wikipron_revision:
            parser.error(
                "--wikipron-release and --wikipron-revision are required "
                "with --wikipron-root"
            )
        wikipron_root = args.wikipron_root
        wikipron_release = args.wikipron_release
        wikipron_revision = args.wikipron_revision
    else:
        if (args.wikipron_release or args.wikipron_revision
                or args.wikipron_languages):
            parser.error(
                "WikiPron provenance/metadata overrides require --wikipron-root"
            )
        wikipron_checkout = args.sources_dir / "wikipron"
        wikipron_release = latest_github_release()
        wikipron_revision = sync_git_release_checkout(
            WIKIPRON_REPOSITORY, wikipron_checkout, wikipron_release
        )
        wikipron_root = wikipron_checkout / "data" / "scrape" / "tsv"

    languages = discover_wikipron_languages(
        wikipron_root, args.wikipron_languages
    )
    try:
        requested = (
            sorted(languages) if args.all else [
                resolve_requested_language(value, languages)
                for value in (args.language or ["en"])
            ]
        )
    except ValueError as error:
        parser.error(str(error))
    requested = list(dict.fromkeys(requested))
    if args.output and len(requested) != 1:
        parser.error("--output can only be used when building one language")

    cmudict = args.cmudict
    cmudict_revision = args.cmudict_revision
    if "en" in requested:
        if cmudict:
            if not cmudict_revision:
                parser.error("--cmudict-revision is required with --cmudict")
        else:
            if cmudict_revision:
                parser.error("--cmudict-revision requires --cmudict")
            cmudict_checkout = args.sources_dir / "cmudict"
            cmudict_revision = sync_git_checkout(
                CMUDICT_REPOSITORY, cmudict_checkout
            )
            cmudict = cmudict_checkout / "cmudict.dict"
    elif cmudict or cmudict_revision:
        parser.error("CMUdict options only apply when building English")

    print(
        f"Using WikiPron release {wikipron_release} ({wikipron_revision})"
        + (f" and CMUdict {cmudict_revision}" if cmudict else "")
    )
    for code in requested:
        language = languages[code]
        output = args.output or default_database_path(args.data_dir, code)
        headwords, records = build_database(
            language,
            language.sources,
            output,
            wikipron_release,
            wikipron_revision,
            args.generated_date,
            cmudict=cmudict if code == "en" else None,
            cmudict_revision=cmudict_revision if code == "en" else "",
            supplement=args.supplement if code == "en" else None,
            language_hints=args.language_hints if code == "en" else None,
        )
        print(f"built {output}: {headwords} headwords, {records} records")


if __name__ == "__main__":
    main()
