#!/usr/bin/env python3
"""Discover, download, and pack MFA/Pynini G2P models for language packs."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import re
import struct
import sys
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO


ROOT = Path(__file__).resolve().parents[1]
OPENFST_MAGIC = 0x7EB2FDD6
OUTPUT_MAGIC = b"KPG2P4\0\0"
WEIGHT_SCALE = 1024
STATE_RECORD_SIZE = 2
ARC_RECORD_SIZE = 10
INFINITE_FINAL = 0xFFFF
STATE_OFFSET_BLOCK = 256
FINAL_RANK_BLOCK = 256
MFA_RELEASES_API = (
    "https://api.github.com/repos/MontrealCorpusTools/mfa-models/releases"
)
MFA_MODELS_URL = "https://github.com/MontrealCorpusTools/mfa-models"
COMPATIBLE_ARCHITECTURES = {"pynini"}
PREFERRED_MODELS = {"en": "english_us_arpa"}


@dataclass(frozen=True)
class MfaModelRelease:
    language_name: str
    model_name: str
    tag: str
    architecture: str
    license: str
    published_at: str
    asset_name: str
    download_url: str
    release_url: str


def read_exact(source: BinaryIO, size: int) -> bytes:
    data = source.read(size)
    if len(data) != size:
        raise ValueError(f"truncated input: expected {size} bytes, found {len(data)}")
    return data


def read_int32(source: BinaryIO) -> int:
    return struct.unpack("<i", read_exact(source, 4))[0]


def read_int64(source: BinaryIO) -> int:
    return struct.unpack("<q", read_exact(source, 8))[0]


def read_openfst_string(source: BinaryIO) -> str:
    length = read_int32(source)
    if length < 0 or length > 1024:
        raise ValueError(f"invalid OpenFst string length: {length}")
    return read_exact(source, length).decode("ascii")


def read_openfst_header(source: BinaryIO) -> tuple[int, int, int]:
    magic = struct.unpack("<I", read_exact(source, 4))[0]
    fst_type = read_openfst_string(source)
    arc_type = read_openfst_string(source)
    version, flags = struct.unpack("<ii", read_exact(source, 8))
    _properties = struct.unpack("<Q", read_exact(source, 8))[0]
    start_state = read_int64(source)
    state_count = read_int64(source)
    arc_count = read_int64(source)

    if magic != OPENFST_MAGIC:
        raise ValueError(f"unexpected OpenFst magic: {magic:#x}")
    if fst_type != "vector" or arc_type != "standard" or version != 2:
        raise ValueError(
            f"unsupported OpenFst format: {fst_type}/{arc_type} version {version}"
        )
    # Symbol tables would follow the states and are deliberately not accepted.
    if flags != 0:
        raise ValueError(f"unsupported embedded OpenFst symbol tables: flags={flags}")
    if not 0 <= start_state < state_count < 0x1000000:
        raise ValueError(
            f"state count/start state cannot use the packed format: "
            f"{state_count}/{start_state}"
        )
    if not 0 <= arc_count < 0x1000000:
        raise ValueError(f"arc count cannot use the packed format: {arc_count}")
    return start_state, state_count, arc_count


def parse_phone_symbols(text: str) -> list[str]:
    symbols: dict[int, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        try:
            symbol, raw_index = line.rsplit("\t", 1)
            index = int(raw_index)
        except ValueError as error:
            raise ValueError(
                f"invalid phone symbol on line {line_number}: {line!r}"
            ) from error
        symbols[index] = symbol

    output = []
    for index in range(1, max(symbols, default=0) + 1):
        symbol = symbols.get(index)
        if symbol == "<UNK>":
            break
        if not symbol:
            raise ValueError(f"missing phone symbol {index}")
        encoded = symbol.encode("utf-8")
        if len(encoded) > 0xFFFF:
            raise ValueError(f"phone symbol is too long: {symbol!r}")
        output.append(symbol)
    if not output:
        raise ValueError("phone symbol table is empty")
    return output


def pack_uint24(value: int) -> bytes:
    if not 0 <= value < 0x1000000:
        raise ValueError(f"value cannot use an unsigned 24-bit field: {value}")
    return bytes((value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF))


def quantize_arc_weight(weight: float) -> int:
    if not math.isfinite(weight):
        raise ValueError(f"non-finite arc weight: {weight}")
    quantized = round(weight * WEIGHT_SCALE)
    if not -0x8000 <= quantized <= 0x7FFF:
        raise ValueError(f"arc weight exceeds the packed range: {weight}")
    return quantized


def quantize_final_weight(weight: float) -> int:
    if math.isinf(weight):
        return INFINITE_FINAL
    if not math.isfinite(weight) or weight < 0:
        raise ValueError(f"unsupported final weight: {weight}")
    quantized = round(weight * WEIGHT_SCALE)
    if quantized >= INFINITE_FINAL:
        raise ValueError(f"final weight exceeds the packed range: {weight}")
    return quantized


def pack_model(
    model_source: BinaryIO,
    phone_symbols: list[str],
) -> tuple[bytes, int, int]:
    start_state, state_count, header_arc_count = read_openfst_header(model_source)
    phone_count = len(phone_symbols)
    if phone_count > 0xFFFF:
        raise ValueError("packed model supports at most 65,535 phones")

    state_offset_bases = bytearray()
    state_offset_deltas = bytearray()
    state_offset_base = 0
    final_bitmap = bytearray((state_count + 7) // 8)
    final_ranks = bytearray()
    final_weights = bytearray()
    final_count = 0
    arcs = bytearray()
    arc_count = 0
    for state in range(state_count):
        if state % STATE_OFFSET_BLOCK == 0:
            state_offset_base = arc_count
            state_offset_bases.extend(pack_uint24(state_offset_base))
        if state % FINAL_RANK_BLOCK == 0:
            final_ranks.extend(pack_uint24(final_count))
        final_weight, state_arc_count = struct.unpack(
            "<fq", read_exact(model_source, 12)
        )
        if not 0 <= state_arc_count <= 255:
            raise ValueError(
                f"state {state} has too many arcs for the packed format: "
                f"{state_arc_count}"
            )
        state_offset_delta = arc_count - state_offset_base
        if state_offset_delta > 0xFFFF:
            raise ValueError(
                f"state-offset block {state // STATE_OFFSET_BLOCK} "
                f"exceeds 16 bits: {state_offset_delta}"
            )
        state_offset_deltas.extend(struct.pack("<H", state_offset_delta))
        packed_final_weight = quantize_final_weight(final_weight)
        if packed_final_weight != INFINITE_FINAL:
            final_bitmap[state // 8] |= 1 << (state % 8)
            final_weights.extend(struct.pack("<H", packed_final_weight))
            final_count += 1

        for _ in range(state_arc_count):
            input_label, output_label, weight, next_state = struct.unpack(
                "<iifi", read_exact(model_source, 16)
            )
            if not 0 <= input_label <= 0x10FFFF:
                raise ValueError(f"unsupported Unicode input label: {input_label}")
            if not 0 <= output_label <= phone_count:
                raise ValueError(f"unknown output phone id: {output_label}")
            if not 0 <= next_state < state_count:
                raise ValueError(f"invalid next state: {next_state}")
            arcs.extend(pack_uint24(input_label))
            arcs.extend(struct.pack("<H", output_label))
            arcs.extend(struct.pack("<h", quantize_arc_weight(weight)))
            arcs.extend(pack_uint24(next_state))
            arc_count += 1
    if state_count % STATE_OFFSET_BLOCK == 0:
        state_offset_base = arc_count
        state_offset_bases.extend(pack_uint24(state_offset_base))
    state_offset_delta = arc_count - state_offset_base
    if state_offset_delta > 0xFFFF:
        raise ValueError(
            f"final state-offset block exceeds 16 bits: {state_offset_delta}"
        )
    state_offset_deltas.extend(struct.pack("<H", state_offset_delta))
    final_ranks.extend(pack_uint24(final_count))

    trailing = model_source.read(1)
    if trailing:
        raise ValueError("unexpected data after OpenFst state records")
    # Some valid VectorFst writers leave the advisory header count at zero;
    # the per-state records remain authoritative. Reject only a stated,
    # nonzero count that disagrees with those records.
    if header_arc_count not in (0, arc_count):
        raise ValueError(
            f"OpenFst header declares {header_arc_count} arcs, found {arc_count}"
        )

    header = struct.pack(
        "<8sIIIHHBBBBI",
        OUTPUT_MAGIC,
        state_count,
        arc_count,
        start_state,
        WEIGHT_SCALE,
        phone_count,
        STATE_RECORD_SIZE,
        ARC_RECORD_SIZE,
        1 if all(re.fullmatch(r"[A-Z]+[012]?", phone) for phone in phone_symbols)
        else 2,
        0,
        final_count,
    )
    phone_table = bytearray()
    for phone in phone_symbols:
        encoded = phone.encode("utf-8")
        phone_table.extend(struct.pack("<H", len(encoded)))
        phone_table.extend(encoded)
    return bytes(
        header + phone_table + state_offset_bases + state_offset_deltas
        + final_bitmap + final_ranks
        + final_weights + arcs
    ), state_count, arc_count


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _body_field(body: str, name: str) -> str:
    match = re.search(
        rf"\*\*{re.escape(name)}:\*\*\s*(?:\[([^\]]+)\]|`([^`]+)`|([^\n]+))",
        body,
        flags=re.IGNORECASE,
    )
    if not match:
        return ""
    return next((value.strip() for value in match.groups() if value), "")


def parse_mfa_release(release: dict) -> MfaModelRelease | None:
    tag = str(release.get("tag_name") or "")
    if (release.get("draft") or release.get("prerelease")
            or not tag.startswith("g2p-") or "-v" not in tag):
        return None
    body = str(release.get("body") or "")
    architecture = _body_field(body, "Architecture").lower()
    language_name = _body_field(body, "Language")
    if architecture not in COMPATIBLE_ARCHITECTURES or not language_name:
        return None
    model_name = tag[4:tag.rfind("-v")]
    assets = [
        asset for asset in release.get("assets") or []
        if str(asset.get("name") or "").lower().endswith(".zip")
        and asset.get("browser_download_url")
    ]
    asset = next(
        (item for item in assets if item.get("name") == f"{model_name}.zip"),
        assets[0] if len(assets) == 1 else None,
    )
    if not asset:
        return None
    return MfaModelRelease(
        language_name=language_name,
        model_name=model_name,
        tag=tag,
        architecture=architecture,
        license=_body_field(body, "License") or "See upstream release",
        published_at=str(release.get("published_at") or ""),
        asset_name=str(asset["name"]),
        download_url=str(asset["browser_download_url"]),
        release_url=str(release.get("html_url") or ""),
    )


def fetch_mfa_models(
    opener=urllib.request.urlopen,
) -> list[MfaModelRelease]:
    models = []
    for page in range(1, 11):
        url = f"{MFA_RELEASES_API}?per_page=100&page={page}"
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "pronunciation.koplugin-language-pack-builder",
        }
        github_token = os.environ.get("GITHUB_TOKEN")
        if github_token:
            headers["Authorization"] = f"Bearer {github_token}"
        request = urllib.request.Request(
            url,
            headers=headers,
        )
        try:
            with opener(request, timeout=30) as response:
                releases = json.load(response)
        except (OSError, ValueError, urllib.error.URLError) as error:
            raise RuntimeError(
                "could not query the official MFA model release catalog; "
                "check network access or use --no-g2p"
            ) from error
        if not isinstance(releases, list):
            raise RuntimeError("GitHub returned an invalid MFA release catalog")
        for release in releases:
            model = parse_mfa_release(release)
            if model:
                models.append(model)
        if len(releases) < 100:
            break
    else:
        raise RuntimeError("MFA release catalog pagination exceeded 1,000 releases")
    return models


def _normalized_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def resolve_mfa_model(
    language_code: str,
    language_name: str,
    models: list[MfaModelRelease],
    preferred_model: str | None = None,
) -> MfaModelRelease | None:
    language_key = _normalized_name(language_name)
    candidates = [
        model for model in models
        if _normalized_name(model.language_name) == language_key
    ]
    if not candidates:
        return None
    preferred = preferred_model or PREFERRED_MODELS.get(language_code)
    if preferred:
        matches = [model for model in candidates if model.model_name == preferred]
        if matches:
            candidates = matches
    else:
        generic_name = re.sub(r"[^a-z0-9]+", "_", language_name.casefold())
        exact = [
            model for model in candidates
            if model.model_name == f"{generic_name}_mfa"
        ]
        if exact:
            candidates = exact
    stable_versions = [
        model for model in candidates
        if re.search(r"-v[0-9]+\.[0-9]+\.[0-9]+$", model.tag)
    ]
    if stable_versions:
        candidates = stable_versions
    return max(
        candidates,
        key=lambda model: (model.published_at, -len(model.model_name), model.tag),
    )


def download_mfa_model(
    model: MfaModelRelease,
    sources_dir: Path,
    opener=urllib.request.urlopen,
) -> Path:
    destination = sources_dir / model.tag / model.asset_name
    if destination.is_file():
        try:
            with zipfile.ZipFile(destination) as archive:
                if archive.testzip() is None:
                    print(f"Using cached MFA model {model.tag}")
                    return destination
        except zipfile.BadZipFile:
            pass
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    request = urllib.request.Request(
        model.download_url,
        headers={"User-Agent": "pronunciation.koplugin-language-pack-builder"},
    )
    print(f"Downloading MFA model {model.tag}")
    try:
        with opener(request, timeout=120) as response, temporary.open("wb") as target:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                target.write(block)
        with zipfile.ZipFile(temporary) as archive:
            corrupt = archive.testzip()
            if corrupt:
                raise ValueError(f"corrupt member {corrupt!r}")
        os.replace(temporary, destination)
    except (OSError, ValueError, zipfile.BadZipFile, urllib.error.URLError) as error:
        raise RuntimeError(
            f"could not download usable MFA model {model.tag} from "
            f"{model.download_url}"
        ) from error
    finally:
        if temporary.exists():
            temporary.unlink()
    return destination


def member_name(archive: zipfile.ZipFile, suffix: str) -> str:
    matches = [name for name in archive.namelist() if name.endswith(suffix)]
    if len(matches) != 1:
        raise ValueError(f"expected one {suffix!r} member, found {matches}")
    return matches[0]


def build_model(model_archive: Path, output: Path) -> tuple[int, int, dict]:
    with zipfile.ZipFile(model_archive) as archive:
        metadata = json.loads(
            archive.read(member_name(archive, "/meta.json")).decode("utf-8")
        )
        if metadata.get("architecture") != "pynini":
            raise ValueError(
                f"expected a Pynini model, found {metadata.get('architecture')!r}"
            )
        phones = parse_phone_symbols(
            archive.read(member_name(archive, "/phones.sym")).decode("utf-8")
        )
        metadata_phones = metadata.get("phones")
        if metadata_phones and set(metadata_phones) != set(phones):
            raise ValueError("metadata and phones.sym list different phones")
        with archive.open(member_name(archive, "/model.fst")) as model_source:
            packed, states, arcs = pack_model(model_source, phones)

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_bytes(packed)
    os.replace(temporary, output)
    return states, arcs, metadata


def normalize_language_code(value: str) -> str:
    code = value.strip().lower().replace("_", "-").split("-", 1)[0]
    if not re.fullmatch(r"[a-z]{2,3}", code):
        raise ValueError(f"invalid base language code: {value!r}")
    return code


def update_pack_metadata(directory: Path) -> None:
    path = directory / "pack.tsv"
    rows: list[tuple[str, str]] = []
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "\t" in line:
                key, value = line.split("\t", 1)
                if key != "g2p_model":
                    rows.append((key, value))
    rows.append(("g2p_model", "g2p.bin"))
    path.write_text(
        "".join(f"{key}\t{value}\n" for key, value in rows),
        encoding="utf-8",
    )


def write_source_metadata(
    directory: Path,
    language: str,
    archive: Path,
    output: Path,
    source_hash: str,
    metadata: dict,
    states: int,
    arcs: int,
    release: MfaModelRelease | None = None,
) -> None:
    model_name = release.model_name if release else str(
        metadata.get("name") or archive.stem
    )
    version = str(metadata.get("version") or "unknown")
    source_project = release.release_url if release else MFA_MODELS_URL
    license_name = release.license if release else "See source model metadata"
    release_lines = [f"Release: {release.tag}"] if release else []
    directory.joinpath("g2p.SOURCE.txt").write_text(
        "\n".join([
            f"Language: {language}",
            f"Model: {model_name}",
            f"Version: {version}",
            *release_lines,
            "Format: compact pronunciation.koplugin KPG2P4 graph",
            f"Source archive: {archive.name}",
            f"Source archive SHA-256: {source_hash}",
            f"Source: {source_project}",
            f"License: {license_name}; see LICENSES.txt when distributing",
            f"Output: {output.name}",
            f"Output size: {output.stat().st_size}",
            f"Output SHA-256: {sha256(output)}",
            f"States: {states}",
            f"Arcs: {arcs}",
            "",
        ]),
        encoding="utf-8",
    )


def build_language_g2p(
    language_code: str,
    language_name: str,
    data_dir: Path,
    sources_dir: Path,
    models: list[MfaModelRelease],
    *,
    output: Path | None = None,
    preferred_model: str | None = None,
    opener=urllib.request.urlopen,
) -> bool:
    model = resolve_mfa_model(
        language_code, language_name, models, preferred_model
    )
    if not model:
        return False
    archive = download_mfa_model(model, sources_dir, opener=opener)
    output = output or data_dir / language_code / "g2p.bin"
    states, arcs, metadata = build_model(archive, output)
    source_hash = sha256(archive)
    write_source_metadata(
        output.parent, language_code, archive, output, source_hash, metadata,
        states, arcs, model,
    )
    update_pack_metadata(output.parent)
    print(
        f"built {output}: {states} states, {arcs} arcs, "
        f"MFA release {model.tag}, source sha256 {source_hash}"
    )
    return True


def read_pack_language_name(data_dir: Path, code: str) -> str:
    path = data_dir / code / "pack.tsv"
    if not path.is_file():
        raise ValueError(
            f"language pack metadata is missing for {code}; build it first "
            f"with tools/build_language_pack.py {code}"
        )
    metadata = dict(
        line.split("\t", 1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if "\t" in line
    )
    name = metadata.get("language_name", "").strip()
    if not name:
        raise ValueError(f"language pack has no language name: {path}")
    return name


def resolve_jobs(
    args: argparse.Namespace, parser: argparse.ArgumentParser
) -> list[tuple[str, Path | None]]:
    if args.models_dir and not args.all:
        parser.error("--models-dir requires --all")
    if args.all and args.output:
        parser.error("--output cannot be combined with --all")
    if args.all:
        if args.language or args.model_archive:
            parser.error(
                "--all cannot be combined with --language or --model-archive"
            )
        if args.models_dir:
            archives = sorted(args.models_dir.glob("*.zip"))
            if not archives:
                parser.error(f"no ZIP model archives found in {args.models_dir}")
            try:
                return [
                    (normalize_language_code(path.stem), path)
                    for path in archives
                ]
            except ValueError as error:
                parser.error(str(error))
        if not args.data_dir.is_dir():
            parser.error(f"language-pack directory does not exist: {args.data_dir}")
        jobs = [
            (path.name, None) for path in sorted(args.data_dir.iterdir())
            if path.is_dir() and re.fullmatch(r"[a-z]{2,3}", path.name)
            and path.joinpath("pack.tsv").is_file()
        ]
        if not jobs:
            parser.error(f"no language packs found in {args.data_dir}")
        return jobs

    archives = args.model_archive or []
    languages = args.language or ["en"]
    if archives and len(languages) != len(archives):
        parser.error("repeat --language once for each --model-archive")
    try:
        jobs = [
            (normalize_language_code(language), archive)
            for language, archive in zip(
                languages, archives or [None] * len(languages), strict=True
            )
        ]
    except ValueError as error:
        parser.error(str(error))
    codes = [code for code, _ in jobs]
    if len(codes) != len(set(codes)):
        parser.error("each base language may be built only once")
    return jobs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--language",
        action="append",
        help="installed base language code; may be repeated (default: en)",
    )
    parser.add_argument(
        "--model-archive",
        action="append",
        type=Path,
        help="local MFA model override; repeat alongside --language",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="build models for every installed language pack",
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        help="legacy local overrides for --all, named CODE.zip",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=ROOT / "data",
        help="language-pack root (default: data)",
    )
    parser.add_argument(
        "--sources-dir",
        type=Path,
        default=ROOT / "pronunciation-sources" / "mfa-models",
        help="download cache for automatically resolved MFA archives",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="single-build output override (default: data/CODE/g2p.bin)",
    )
    parser.add_argument(
        "--expected-sha256",
        action="append",
        help="expected source archive hash; repeat in build order",
    )
    args = parser.parse_args()
    jobs = resolve_jobs(args, parser)
    if args.output and len(jobs) != 1:
        parser.error("--output is only valid for a single language")
    expected_hashes = args.expected_sha256 or []
    if expected_hashes and len(expected_hashes) != len(jobs):
        parser.error("repeat --expected-sha256 once for each model archive")

    automatic = any(archive is None for _, archive in jobs)
    if automatic and expected_hashes:
        parser.error("--expected-sha256 requires local --model-archive inputs")
    models = fetch_mfa_models() if automatic else []
    for index, (language, archive) in enumerate(jobs):
        if archive is None:
            try:
                language_name = read_pack_language_name(args.data_dir, language)
            except ValueError as error:
                parser.error(str(error))
            built = build_language_g2p(
                language, language_name, args.data_dir, args.sources_dir,
                models, output=args.output,
            )
            if not built:
                print(
                    f"No compatible MFA/Pynini G2P model is published for "
                    f"{language_name} ({language}); database/readable data "
                    "remain usable.",
                    file=sys.stderr,
                )
            continue
        if not archive.is_file():
            parser.error(f"model archive does not exist: {archive}")
        source_hash = sha256(archive)
        expected = expected_hashes[index] if expected_hashes else ""
        if expected and source_hash.lower() != expected.lower():
            raise ValueError(
                f"{language} source archive SHA-256 mismatch: expected "
                f"{expected}, found {source_hash}"
            )
        directory = args.data_dir / language
        output = args.output or directory / "g2p.bin"
        states, arcs, metadata = build_model(archive, output)
        directory = output.parent
        write_source_metadata(
            directory, language, archive, output, source_hash, metadata,
            states, arcs,
        )
        update_pack_metadata(directory)
        print(
            f"built {output}: {states} states, {arcs} arcs, "
            f"source sha256 {source_hash}"
        )


if __name__ == "__main__":
    main()
