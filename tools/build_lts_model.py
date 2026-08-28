#!/usr/bin/env python3
"""Re-encode CMU Flite's US-English LTS decision trees for the Lua runtime."""

from __future__ import annotations

import argparse
import re
import struct
from pathlib import Path


MAGIC = b"KPLTS1\0\0"
STATE_WITH_BRANCHES = re.compile(
    r"^\s*(\d+)\s*,\s*'(.)'\s*,\s*"
    r"(LTS_STATE_[A-Za-z0-9_]+)\s*,\s*"
    r"(LTS_STATE_[A-Za-z0-9_]+)\s*,\s*$"
)
STATE_WITH_BYTES = re.compile(
    r"^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"
    r"\s*,\s*(\d+)\s*,\s*(\d+)\s*,?\s*$"
)


def state_addresses(header: str) -> dict[str, int]:
    addresses = {}
    for name, low, high in re.findall(
        r"#define\s+(LTS_STATE_[A-Za-z0-9_]+)\s+"
        r"0x([0-9a-fA-F]+),0x([0-9a-fA-F]+)",
        header,
    ):
        addresses[name] = int(low, 16) + 256 * int(high, 16)
    if not addresses:
        raise ValueError("no LTS state addresses found")
    return addresses


def model_states(model_source: str, addresses: dict[str, int]) -> bytes:
    match = re.search(
        r"const\s+cst_lts_model\s+cmu_lts_model\[\]\s*=\s*\{"
        r"(.*?)\n\};",
        model_source,
        re.DOTALL,
    )
    if not match:
        raise ValueError("cmu_lts_model initializer not found")

    output = bytearray()
    for raw_line in match.group(1).splitlines():
        line = re.sub(r"/\*.*?\*/", "", raw_line).strip()
        if not line:
            continue
        branch = STATE_WITH_BRANCHES.fullmatch(line)
        if branch:
            feature = int(branch.group(1))
            value = ord(branch.group(2))
            on_true = addresses[branch.group(3)]
            on_false = addresses[branch.group(4)]
            output.extend(struct.pack("<BBHH", feature, value, on_true, on_false))
            continue
        byte_state = STATE_WITH_BYTES.fullmatch(line)
        if byte_state:
            values = [int(value) for value in byte_state.groups()]
            if any(value > 255 for value in values):
                raise ValueError(f"state byte out of range: {raw_line}")
            output.extend(values)
            continue
        raise ValueError(f"unrecognized model state: {raw_line}")

    if len(output) % 6:
        raise ValueError("model length is not a multiple of six bytes")
    return bytes(output)


def phone_table(rules_source: str) -> list[str]:
    match = re.search(
        r"cmu_lts_phone_table\[[^]]+\]\s*=\s*\{(.*?)\n\};",
        rules_source,
        re.DOTALL,
    )
    if not match:
        raise ValueError("CMU LTS phone table not found")
    phones = re.findall(r'"([^"]+)"', match.group(1))
    if not phones or len(phones) > 255:
        raise ValueError("invalid CMU LTS phone table")
    return phones


def letter_indexes(rules_source: str) -> list[int]:
    match = re.search(
        r"cmu_lts_letter_index\[[^]]+\]\s*=\s*\{(.*?)\n\};",
        rules_source,
        re.DOTALL,
    )
    if not match:
        raise ValueError("CMU LTS letter index not found")
    indexes = [
        int(value)
        for value in re.findall(r"(\d+)\s*,\s*/\*\s*[a-z]\s*\*/", match.group(1))
    ]
    if len(indexes) != 26:
        raise ValueError(f"expected 26 letter indexes, found {len(indexes)}")
    return indexes


def build_model(flite_root: Path, output: Path) -> tuple[int, int]:
    cmulex = flite_root / "lang" / "cmulex"
    model_source = (cmulex / "cmu_lts_model.c").read_text(encoding="utf-8")
    header = (cmulex / "cmu_lts_model.h").read_text(encoding="utf-8")
    rules_source = (cmulex / "cmu_lts_rules.c").read_text(encoding="utf-8")

    states = model_states(model_source, state_addresses(header))
    phones = phone_table(rules_source)
    indexes = letter_indexes(rules_source)
    state_count = len(states) // 6
    if state_count > 65535:
        raise ValueError("LTS model has too many states for the portable format")

    data = bytearray(MAGIC)
    data.extend(struct.pack("<HBB", state_count, len(indexes), len(phones)))
    data.extend(struct.pack("<" + "H" * len(indexes), *indexes))
    for phone in phones:
        encoded = phone.encode("ascii")
        if len(encoded) > 255:
            raise ValueError(f"phone table entry is too long: {phone!r}")
        data.extend(struct.pack("<B", len(encoded)))
        data.extend(encoded)
    data.extend(states)

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(output)
    return state_count, len(phones)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flite", required=True, type=Path,
                        help="path to the pinned CMU Flite source checkout")
    parser.add_argument("--output", type=Path,
                        default=Path("data/cmu_flite_lts.bin"))
    args = parser.parse_args()
    states, phones = build_model(args.flite, args.output)
    print(f"built {args.output}: {states} states, {phones} phone outputs")


if __name__ == "__main__":
    main()
