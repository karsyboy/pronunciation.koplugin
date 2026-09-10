#!/usr/bin/env python3
"""Pack one or more MFA/Pynini G2P archives for the Lua runtime."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import re
import struct
import zipfile
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
) -> None:
    model_name = str(metadata.get("name") or archive.stem)
    version = str(metadata.get("version") or "unknown")
    directory.joinpath("g2p.SOURCE.txt").write_text(
        "\n".join([
            f"Language: {language}",
            f"Model: {model_name}",
            f"Version: {version}",
            "Format: compact pronunciation.koplugin KPG2P4 graph",
            f"Source archive: {archive.name}",
            f"Source archive SHA-256: {source_hash}",
            "Source project: https://github.com/MontrealCorpusTools/mfa-models",
            "License: see the source model metadata and LICENSES.txt",
            f"Output: {output.name}",
            f"Output size: {output.stat().st_size}",
            f"Output SHA-256: {sha256(output)}",
            f"States: {states}",
            f"Arcs: {arcs}",
            "",
        ]),
        encoding="utf-8",
    )


def resolve_jobs(
    args: argparse.Namespace, parser: argparse.ArgumentParser
) -> list[tuple[str, Path]]:
    if args.models_dir and not args.all:
        parser.error("--models-dir requires --all")
    if args.all and args.output:
        parser.error("--output cannot be combined with --all")
    if args.all:
        if args.language or args.model_archive:
            parser.error(
                "--all cannot be combined with --language or --model-archive"
            )
        if not args.models_dir:
            parser.error("--all requires --models-dir")
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

    archives = args.model_archive or []
    if not archives:
        parser.error("at least one --model-archive is required (or use --all)")
    languages = args.language or (["en"] if len(archives) == 1 else [])
    if len(languages) != len(archives):
        parser.error("repeat --language once for each --model-archive")
    try:
        jobs = [
            (normalize_language_code(language), archive)
            for language, archive in zip(languages, archives, strict=True)
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
        help="base language code; repeat alongside --model-archive",
    )
    parser.add_argument(
        "--model-archive",
        action="append",
        type=Path,
        help="official MFA G2P model ZIP containing model.fst and phones.sym",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="build every CODE.zip archive found in --models-dir",
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        help="directory used by --all; archive filenames are base codes",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=ROOT / "data",
        help="language-pack root (default: data)",
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

    for index, (language, archive) in enumerate(jobs):
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
