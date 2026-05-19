#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""fetch_records.py — download and parse k-tuplet records from pzktupel.de.

Fetches the historical record pages for k=16..21 from Norman Luhn's site
(https://pzktupel.de/KTHIST/) and writes known/records.json.

All records and credit belong to Norman Luhn and the original discoverers.
See known/README.md for attribution.

Usage:
    python3 tools/fetch_records.py [--output known/records.json] [--dry-run]
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "known" / "records.json"

BASE_URL = "https://pzktupel.de/KTHIST/kt{:03d}.php"
K_VALUES = [16, 17, 18, 19, 20, 21]

# Precomputed primorials (product of primes up to p).
PRIMORIALS: dict[int, int] = {
    2: 2, 3: 6, 5: 30, 7: 210, 11: 2310, 13: 30030, 17: 510510,
    19: 9699690, 23: 223092870, 29: 6469693230, 31: 200560490130,
    37: 7420738134810, 41: 304250263527210, 43: 13082761331670030,
    47: 614889782588491410, 53: 32589158477190044730,
    59: 1922760350154212438530, 61: 117288381359406169597530,
    67: 7858321551080267055879090, 71: 557742830140805851925900690,
    73: 40729680599249024150621323470, 79: 3217644767340672907899084554130,
    83: 267064515689275851355624017992790,
}


def primorial(p: int) -> int:
    if p not in PRIMORIALS:
        raise ValueError(f"Primorial {p}# not precomputed — add to PRIMORIALS dict")
    return PRIMORIALS[p]


def fetch_page(k: int) -> str:
    url = BASE_URL.format(k)
    print(f"  fetching {url} ...", file=sys.stderr)
    req = urllib.request.Request(url, headers={"User-Agent": "kt-search/1.0 (record-corpus fetch)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    # Try UTF-8, fall back to latin-1
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


# Matches a record line containing "+ d, d = ..."
# Two forms:
#   MULT • PRIMO# + OFFSET + d, d = OFFSETS (DIGITS digits, DATE, AUTHOR )
#   BASE + d, d = OFFSETS (DIGITS digits, DATE, AUTHOR )
#
# The bullet char may appear as &bullet; or the literal •.

_RE_PRIMORIAL = re.compile(
    r"(\d[\d\s]*)"          # group 1: multiplier (may have spaces from HTML)
    r"\s*[•&](?:bullet;)?\s*"  # bullet entity or char
    r"(\d+)#\s*\+\s*"       # group 2: primorial prime p
    r"(\d[\d\s]*)"          # group 3: offset added to mult*p#
    r"\s*\+\s*d,\s*d\s*=\s*"
    r"([\d,\s]+)"           # group 4: offsets list
    r"\s*\((\d+)\s*digits?,\s*([^,)]+),\s*([^)]+?)\s*\)"  # digits, date, author
)

_RE_DIRECT = re.compile(
    r"(\d[\d\s]+)"          # group 1: base integer (may contain spaces from line breaks)
    r"\s*\+\s*d,\s*d\s*=\s*"
    r"([\d,\s]+)"           # group 2: offsets list
    r"\s*\((\d+)\s*digits?,\s*([^,)]+),\s*([^)]+?)\s*\)"  # digits, date, author
)


def strip_html(s: str) -> str:
    """Remove simple HTML tags and decode basic entities."""
    s = re.sub(r"<[^>]+>", " ", s)
    s = s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    s = s.replace("&bullet;", "•").replace("&#183;", "•")
    s = s.replace("\xa0", " ")
    return s


def parse_offsets(raw: str) -> list[int]:
    return [int(x.strip()) for x in raw.split(",") if x.strip().isdigit()]


def parse_page(html: str, k: int) -> list[dict]:
    """Parse one KTHIST page and return a list of record dicts."""
    records = []
    # Work line by line; each record ends with <P> or <p>
    # Join all text between <P> tags as potential record lines
    # Strip all tags first, then split on newlines and look for "+ d, d ="
    text = strip_html(html)
    # Each record is a paragraph; split on runs of whitespace containing newlines
    # but keep content together
    lines = [ln.strip() for ln in text.splitlines()]
    # Rejoin into one string and split on paragraph breaks (empty lines or •)
    blob = " ".join(lines)
    # Split roughly on record boundaries: each one contains "+ d, d ="
    # Use a sliding approach: find all occurrences of the pattern
    seen_bases: set[str] = set()

    # Try primorial form first on the whole blob
    for m in _RE_PRIMORIAL.finditer(blob):
        mult_raw, p_str, offset_raw, offsets_raw, digits_str, date_raw, author_raw = m.groups()
        mult = int(mult_raw.replace(" ", ""))
        p = int(p_str)
        offset = int(offset_raw.replace(" ", ""))
        base_int = mult * primorial(p) + offset
        base_str = str(base_int)
        if base_str in seen_bases:
            continue
        seen_bases.add(base_str)
        offsets = parse_offsets(offsets_raw)
        records.append({
            "base": base_str,
            "offsets": offsets,
            "digits": int(digits_str),
            "date": date_raw.strip(),
            "author": author_raw.strip(),
        })

    # Try direct form — but skip spans already matched by primorial regex
    # Build a version with primorial matches blanked out
    blob_no_prim = _RE_PRIMORIAL.sub("MATCHED", blob)
    for m in _RE_DIRECT.finditer(blob_no_prim):
        base_raw, offsets_raw, digits_str, date_raw, author_raw = m.groups()
        base_str = base_raw.replace(" ", "")
        if not base_str.isdigit():
            continue
        if base_str in seen_bases:
            continue
        seen_bases.add(base_str)
        offsets = parse_offsets(offsets_raw)
        records.append({
            "base": base_str,
            "offsets": offsets,
            "digits": int(digits_str),
            "date": date_raw.strip(),
            "author": author_raw.strip(),
        })

    # Sort ascending by digit count, then base string length, then base value
    records.sort(key=lambda r: (r["digits"], len(r["base"]), r["base"]))
    print(f"    k={k}: {len(records)} records parsed", file=sys.stderr)
    return records


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", default=str(DEFAULT_OUTPUT),
                    help="output path for records.json (default: known/records.json)")
    ap.add_argument("--dry-run", action="store_true",
                    help="fetch and parse but do not write output")
    ap.add_argument("--k", type=int, nargs="+", default=K_VALUES,
                    help="k values to fetch (default: 16 17 18 19 20 21)")
    args = ap.parse_args()

    print("Fetching k-tuplet records from pzktupel.de ...", file=sys.stderr)
    result: dict[str, dict] = {}
    for k in args.k:
        html = fetch_page(k)
        recs = parse_page(html, k)
        result[str(k)] = {"records": recs}

    total = sum(len(v["records"]) for v in result.values())
    print(f"Total: {total} records across k={args.k}", file=sys.stderr)

    if args.dry_run:
        print("--dry-run: not writing output", file=sys.stderr)
        return

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
    print(f"Written: {out_path} ({out_path.stat().st_size} bytes)", file=sys.stderr)


if __name__ == "__main__":
    main()
