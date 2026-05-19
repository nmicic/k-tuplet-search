#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
parse_records_json.py — emit a flat record manifest for the kt_gmp_v1
--validate-known harness.

Input:  known/records.json
Output: tools/records_manifest.tsv
         (k\tpattern\tbase_dec\tdigits\tdate\tauthor\tbits)

The pattern column is the canonical name from src/common/ktuplet_pattern.c
(e.g. KT17_P0); resolution is by exact offsets-list match. If a record's
offsets do not match any catalog pattern, the row is emitted with
pattern="UNKNOWN" and a warning is printed to stderr — but the script
exits 0 so partial manifests are usable.
"""
from __future__ import annotations
import json, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
RECORDS_JSON = ROOT / "known/records.json"
PATTERN_HEADER = ROOT / "src/common/ktuplet_pattern.c"
OUT_TSV = ROOT / "tools/records_manifest.tsv"


def load_catalog() -> list[tuple[str, list[int]]]:
    """Parse KT_PATTERNS[] from ktuplet_pattern.c (cheap regex parse)."""
    text = PATTERN_HEADER.read_text()
    out: list[tuple[str, list[int]]] = []
    for line in text.splitlines():
        if "/* KT" not in line or "{" not in line:
            continue
        # /* KT19_P0 */ { 19, 76, {0, 4, ...}, "KT19_P0" },
        try:
            name = line.split('"')[1]
            offsets_part = line.split("{", 2)[2].split("}")[0]
            offsets = [int(x.strip()) for x in offsets_part.split(",") if x.strip()]
            k = int(line.split("{", 1)[1].split(",")[0])
            out.append((name, offsets[:k]))
        except (IndexError, ValueError):
            continue
    return out


def main() -> int:
    catalog = load_catalog()
    by_offsets: dict[tuple[int, ...], str] = {tuple(o): n for n, o in catalog}

    data = json.loads(RECORDS_JSON.read_text())
    rows: list[str] = ["k\tpattern\tbase_dec\tdigits\tdate\tauthor\tbits"]
    unknown = 0
    for k_str in sorted(data.keys(), key=int):
        recs = data[k_str].get("records", [])
        for rec in recs:
            offsets = tuple(rec["offsets"])
            name = by_offsets.get(offsets)
            if name is None:
                unknown += 1
                name = "UNKNOWN"
                print(f"WARN: no catalog match for k={k_str} offsets={list(offsets)[:5]}...",
                      file=sys.stderr)
            base = int(rec["base"])
            rows.append(f"{k_str}\t{name}\t{rec['base']}\t{rec['digits']}\t"
                        f"{rec['date']}\t{rec['author']}\t{base.bit_length()}")
    OUT_TSV.write_text("\n".join(rows) + "\n")
    print(f"Wrote {len(rows)-1} records to {OUT_TSV} ({unknown} UNKNOWN)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
