#!/usr/bin/env python3
"""Pack an MFA/Pynini English G2P archive for the dependency-free Lua runtime."""

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
OUTPUT_MAGIC = b"KPG2P3\0\0"
WEIGHT_SCALE = 1024
STATE_RECORD_SIZE = 2
ARC_RECORD_SIZE = 6
INFINITE_FINAL = 0xFFFF
STATE_OFFSET_BLOCK = 256
FINAL_RANK_BLOCK = 256
VALID_INPUT_LABELS = {0, 39, *range(ord("a"), ord("z") + 1)}
EXPECTED_ARCHIVE_SHA256 = (
    "f079ae88f792458fa7c123b256e5b86cc55c29ac2ffc457c673e6c60c36cd143"
)


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
        if not re.fullmatch(r"[A-Z]+[012]?", symbol):
            raise ValueError(f"unsupported phone symbol {index}: {symbol!r}")
        encoded = symbol.encode("ascii")
        if len(encoded) > 255:
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
    if phone_count > 255:
        raise ValueError("packed model supports at most 255 phones")

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
            if input_label not in VALID_INPUT_LABELS:
                raise ValueError(f"unsupported input label: {input_label}")
            if not 0 <= output_label <= phone_count:
                raise ValueError(f"unknown output phone id: {output_label}")
            if not 0 <= next_state < state_count:
                raise ValueError(f"invalid next state: {next_state}")
            input_code = (
                0 if input_label == 0
                else 1 if input_label == 39
                else input_label - 95
            )
            next_state_high, next_state_low = divmod(next_state, 0x10000)
            arcs.extend(bytes((
                input_code | (next_state_high & 0x07) << 5,
                output_label | (next_state_high >> 3) << 7,
            )))
            arcs.extend(struct.pack("<h", quantize_arc_weight(weight)))
            arcs.extend(struct.pack("<H", next_state_low))
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
        "<8sIIIHBBBBI",
        OUTPUT_MAGIC,
        state_count,
        arc_count,
        start_state,
        WEIGHT_SCALE,
        phone_count,
        STATE_RECORD_SIZE,
        ARC_RECORD_SIZE,
        0,
        final_count,
    )
    phone_table = bytearray()
    for phone in phone_symbols:
        encoded = phone.encode("ascii")
        phone_table.append(len(encoded))
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


def build_model(model_archive: Path, output: Path) -> tuple[int, int]:
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
    return states, arcs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model-archive",
        required=True,
        type=Path,
        help="official MFA G2P model ZIP containing model.fst and phones.sym",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "data" / "mfa_english_g2p.bin",
    )
    parser.add_argument(
        "--expected-sha256",
        default=EXPECTED_ARCHIVE_SHA256,
        help="required source archive hash (empty disables the check)",
    )
    args = parser.parse_args()
    source_hash = sha256(args.model_archive)
    if (
        args.expected_sha256
        and source_hash.lower() != args.expected_sha256.lower()
    ):
        raise ValueError(
            f"source archive SHA-256 mismatch: expected {args.expected_sha256}, "
            f"found {source_hash}"
        )
    states, arcs = build_model(args.model_archive, args.output)
    print(
        f"built {args.output}: {states} states, {arcs} arcs, "
        f"source sha256 {source_hash}"
    )


if __name__ == "__main__":
    main()
