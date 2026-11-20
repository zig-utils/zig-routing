#!/usr/bin/env python3
"""Derive the compact geocoder tables from Unicode Character Database 18.0.0."""

import argparse
import functools
import hashlib
import struct
from pathlib import Path


VERSION = "18.0.0"
SCALARS = 0x110000
PAGE_SIZE = 256
SCRIPT_CLASSES = {"Greek": 2, "Cyrillic": 3, "Han": 4, "Hiragana": 5, "Katakana": 5, "Hangul": 6}
SOURCES = ("ReadMe.txt", "UnicodeData.txt", "CaseFolding.txt", "Scripts.txt", "DerivedCoreProperties.txt")


def properties(path):
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        key, *values = (field.strip() for field in line.split(";"))
        yield key, values


def bounds(raw):
    start, *end = raw.split("..")
    return int(start, 16), int(end[0] if end else start, 16)


def unicode_data(root):
    classes = bytearray(SCALARS)
    marks = set()
    decomposition = {}
    digits = {}
    range_start = None
    for raw, fields in properties(root / "UnicodeData.txt"):
        cp = int(raw, 16)
        name, category = fields[:2]
        if name.endswith(", First>"):
            range_start = cp
            continue
        first = cp if range_start is None else range_start
        if category[0] in "LN":
            classes[first : cp + 1] = b"\1" * (cp - first + 1)
        if category[0] == "M":
            marks.update(range(first, cp + 1))
        range_start = None
        mapping = fields[4].split()
        if mapping:
            decomposition[cp] = tuple(int(code, 16) for code in mapping if not code.startswith("<"))
        if fields[5]:
            digits[cp] = ord("0") + int(fields[5])

    for raw, (script, *_) in properties(root / "Scripts.txt"):
        kind = SCRIPT_CLASSES.get(script)
        if kind is None:
            continue
        first, last = bounds(raw)
        for cp in range(first, last + 1):
            if classes[cp]:
                classes[cp] = kind
    # Shared Kana iteration and prolonged-sound marks join the Kana run.
    for cp in (*range(0x3031, 0x3036), 0x30FC):
        classes[cp] = SCRIPT_CLASSES["Katakana"]
    return classes, marks, decomposition, digits


def fold_table(root, marks, decomposition, digits):
    case = {
        int(raw, 16): tuple(int(code, 16) for code in mapping.split())
        for raw, (status, mapping, *_) in properties(root / "CaseFolding.txt")
        if status in ("C", "F")
    }
    ignored = set()
    for raw, (prop, *_) in properties(root / "DerivedCoreProperties.txt"):
        if prop == "Default_Ignorable_Code_Point":
            first, last = bounds(raw)
            ignored.update(range(first, last + 1))

    @functools.lru_cache(maxsize=None)
    def decomposed(cp):
        if 0xAC00 <= cp <= 0xD7A3:
            offset = cp - 0xAC00
            onset, remainder = divmod(offset, 21 * 28)
            vowel, final = divmod(remainder, 28)
            return (0x1100 + onset, 0x1161 + vowel) + ((0x11A7 + final,) if final else ())
        if cp in decomposition:
            return tuple(child for part in decomposition[cp] for child in decomposed(part))
        return (cp,)

    replacements = {}
    for cp in sorted(case.keys() | digits.keys() | decomposition.keys() | marks | ignored):
        if 0xAC00 <= cp <= 0xD7A3:
            continue
        folded = (
            digits.get(final, final)
            for part in decomposed(cp)
            if part not in ignored
            for lower in case.get(part, (part,))
            for final in decomposed(lower)
            if final not in marks and final not in ignored
        )
        text = "".join(map(chr, folded)).encode()
        if text != chr(cp).encode():
            replacements[cp] = text
    return replacements


def encode(root):
    if VERSION not in (root / "ReadMe.txt").read_text(encoding="utf-8"):
        raise ValueError(f"expected Unicode {VERSION}")
    for name in ("CaseFolding.txt", "Scripts.txt", "DerivedCoreProperties.txt"):
        if VERSION not in (root / name).read_text(encoding="utf-8").splitlines()[0]:
            raise ValueError(f"{name} belongs to a different release")
    classes, marks, decomposition, digits = unicode_data(root)
    replacements = fold_table(root, marks, decomposition, digits)
    payload = bytearray()
    positions = {b"": 0}
    mapped = bytearray()
    for cp, value in replacements.items():
        if value not in positions:
            positions[value] = len(payload)
            payload.extend(value)
        offset = positions[value]
        if offset >= 1 << 24 or len(value) >= 1 << 8:
            raise ValueError("Unicode fold payload is too large")
        mapped.extend(struct.pack("<II", cp, offset | (len(value) << 24)))

    page_ids = bytearray()
    pages = {}
    for offset in range(0, SCALARS, PAGE_SIZE):
        page = bytes(classes[offset : offset + PAGE_SIZE])
        ordinal = pages.setdefault(page, len(pages))
        page_ids.extend(struct.pack("<H", ordinal))
    header = struct.pack("<8s6I", b"ZRUTABLE", len(replacements), len(payload), len(pages), *map(int, VERSION.split(".")))
    return header + mapped + payload + page_ids + b"".join(pages)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ucd", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parents[2] / "src" / "geocode"
    tables = encode(args.ucd)
    source = "".join(f"{hashlib.sha256((args.ucd / name).read_bytes()).hexdigest()}  {name}\n" for name in SOURCES)
    artifacts = {"unicode-data.bin": tables, "unicode-source.sha256": source.encode()}
    for name, data in artifacts.items():
        target = directory / name
        if args.check:
            if target.read_bytes() != data:
                raise ValueError(f"{name} differs from generated Unicode {VERSION} data")
        else:
            target.write_bytes(data)


if __name__ == "__main__":
    main()
