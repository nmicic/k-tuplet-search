#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
validate_pattern.py — Generic prime k-tuplet pattern validator (T-PV1).

Validates any candidate pattern: admissibility, canonical form, forbidden residues,
singular series. JSON output suitable for tooling pipelines.

Usage:
    python3 tools/validate_pattern.py --offsets "0,4,6,10,12,16,24,30,34,40,42,46,52,54,60,66,70,72,76"
    python3 tools/validate_pattern.py --pattern-name KT19_P0
    python3 tools/validate_pattern.py --offsets-file my_pattern.txt

Exit codes:
    0 = admissible
    1 = not admissible
    2 = input error (bad format, duplicates, etc.)
"""

import argparse
import json
import math
import re
import sys
from pathlib import Path


# Single source of truth for parsing src/common/ktuplet_pattern.c entries.
# Tolerates flexible whitespace and the optional "from kNN_dDDD.json" tail
# emitted by tools/gen_pattern_header.py.
# Groups: 1=name (header comment), 2=k, 3=diameter, 4=offsets, 5=name (struct field)
_CATALOG_PATTERN_RE = re.compile(
    r"/\*\s*(\w+)\s*(?:from\s+\S+\s*)?\*/\s*\{\s*(\d+),\s*(\d+),\s*\{([^}]+)\},\s*\"(\w+)\"\s*\}"
)


def primes_up_to(n):
    """Sieve of Eratosthenes; returns list of primes <= n."""
    if n < 2:
        return []
    sieve = bytearray([1]) * (n + 1)
    sieve[0] = sieve[1] = 0
    for i in range(2, int(n ** 0.5) + 1):
        if sieve[i]:
            for j in range(i * i, n + 1, i):
                sieve[j] = 0
    return [i for i, v in enumerate(sieve) if v]


def validate_input(offsets):
    """Check input format. Returns (sorted_offsets, errors)."""
    errors = []
    if not offsets:
        errors.append("empty offset list")
        return offsets, errors
    if any(not isinstance(b, int) for b in offsets):
        errors.append("non-integer offset")
    if any(b < 0 for b in offsets):
        errors.append("negative offset")
    sorted_offs = sorted(offsets)
    if sorted_offs[0] != 0:
        errors.append(f"first offset must be 0 (got {sorted_offs[0]})")
    if len(set(sorted_offs)) != len(sorted_offs):
        errors.append("duplicate offsets")
    return sorted_offs, errors


def forbidden_residues(offsets, q):
    """Forbidden residue set for prime q: {(-b) mod q for b in offsets}."""
    return sorted({(-b) % q for b in offsets})


def occupied_residues(offsets, q):
    """Occupied residue set: {b mod q for b in offsets}."""
    return sorted({b % q for b in offsets})


def is_admissible(offsets, return_witness=False, prime_bound=None):
    """Check admissibility. A pattern is admissible iff for every prime q,
    the set {b_i mod q} doesn't cover all of Z/qZ (equivalently |F_q| < q).

    Bound: must check primes <= max(diameter, k). For q > diameter, all
    offsets are distinct mod q, so |occupied| = k. If k >= q (only possible
    when q in (diameter, k]), admissibility fails. For q > k, |occupied| = k < q,
    automatic. So checking primes up to max(diameter, k) is sufficient.
    """
    if not offsets:
        return (False, None) if return_witness else False
    diameter = max(offsets)
    k = len(offsets)
    if prime_bound is None:
        prime_bound = max(diameter, k)
    for q in primes_up_to(prime_bound):
        if len(occupied_residues(offsets, q)) == q:
            return (False, q) if return_witness else False
    return (True, None) if return_witness else True


def canonical_form(offsets):
    """Return canonical form: lex-min of pattern and its reflection.
    Reflection of {b_0, ..., b_{k-1}} is {d - b_{k-1-i}} where d = max(b_i).
    """
    diameter = max(offsets)
    reflection = sorted(diameter - b for b in offsets)
    return min(tuple(offsets), tuple(reflection))


def is_canonical(offsets):
    return tuple(offsets) == canonical_form(offsets)


def singular_series_log10(offsets, prime_bound=10000):
    """Log10 of singular series partial product over primes <= prime_bound.

    S(B) = prod_q ((q - omega_q) / q) * (q / (q-1))^k
    log10 S = sum_q [log10((q - omega_q)/q) - k*log10((q-1)/q)]

    Returns -inf if pattern is not admissible at any prime <= prime_bound.
    """
    k = len(offsets)
    log_S = 0.0
    ln10 = math.log(10)
    for q in primes_up_to(prime_bound):
        omega = len(occupied_residues(offsets, q))
        if omega == q:
            return float("-inf")
        log_S += math.log(1 - omega / q) / ln10 - k * math.log(1 - 1 / q) / ln10
    return log_S


def known_h_k():
    """Known minimum diameter H(k) values for small k.
    Source: pzktupel.de/ktpatt_hl.php; values beyond k=24 should still be
    cross-checked before external publication.
    """
    return {
        3: 6, 4: 8, 5: 12, 6: 16, 7: 20, 8: 26, 9: 30, 10: 32,
        11: 36, 12: 42, 13: 48, 14: 50, 15: 56, 16: 60, 17: 66,
        18: 70, 19: 76, 20: 80, 21: 84, 22: 90, 23: 94, 24: 100,
        25: 110, 26: 114, 27: 120, 28: 126, 29: 130, 30: 136,
    }


def iter_catalog_patterns():
    """Yield (name, offsets) entries from src/common/ktuplet_pattern.c."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    src = repo_root / "src" / "common" / "ktuplet_pattern.c"
    if not src.exists():
        return
    text = src.read_text()
    for match in _CATALOG_PATTERN_RE.finditer(text):
        name = match.group(5)
        k = int(match.group(2))
        offsets = [int(x.strip()) for x in match.group(4).split(",")]
        yield name, offsets[:k]  # trim trailing zeros


def lookup_pattern_by_name(name):
    """Resolve KT-catalog name to offsets. Reads src/common/ktuplet_pattern.c."""
    for catalog_name, offsets in iter_catalog_patterns():
        if catalog_name == name:
            return offsets
    return None


def validate(offsets, prime_bound=None, ss_prime_bound=10000):
    """Full validation. Returns dict suitable for JSON output."""
    sorted_offs, errors = validate_input(offsets)
    if errors:
        return {
            "input_errors": errors,
            "valid_input": False,
        }

    k = len(sorted_offs)
    diameter = max(sorted_offs)
    is_adm, witness = is_admissible(sorted_offs, return_witness=True, prime_bound=prime_bound)

    forbidden = {}
    if diameter < 1000:
        for q in primes_up_to(min(diameter, 100)):
            forbidden[str(q)] = forbidden_residues(sorted_offs, q)

    canon = list(canonical_form(sorted_offs))
    is_canon = (canon == sorted_offs)

    refl = [diameter - b for b in reversed(sorted_offs)]

    ss_log10 = None
    if is_adm:
        ss_log10 = singular_series_log10(sorted_offs, prime_bound=ss_prime_bound)

    h_k = known_h_k().get(k)

    return {
        "valid_input": True,
        "k": k,
        "diameter": diameter,
        "is_admissible": is_adm,
        "is_canonical": is_canon,
        "canonical_form": canon,
        "reflection": refl,
        "forbidden_residues_per_prime": forbidden,
        "singular_series_log10": ss_log10,
        "known_h_k": h_k,
        "is_narrow": (h_k == diameter) if h_k is not None else None,
        "admissibility_witness_prime": witness,
    }


def parse_offsets_arg(s):
    """Parse comma-separated or whitespace-separated offsets."""
    s = s.strip().strip("[](){}")
    parts = s.replace(",", " ").split()
    return [int(p) for p in parts]


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    src = p.add_mutually_exclusive_group(required=False)
    src.add_argument("--offsets", help="Comma-separated offsets, e.g. '0,4,6,10'")
    src.add_argument("--offsets-file", help="File containing offsets")
    src.add_argument("--pattern-name", help="KT-catalog pattern name, e.g. KT19_P0")
    p.add_argument("--prime-bound", type=int, default=None,
                   help="Prime bound for admissibility check (default: diameter)")
    p.add_argument("--ss-prime-bound", type=int, default=10000,
                   help="Prime bound for singular series (default: 10000)")
    p.add_argument("--self-test", action="store_true",
                   help="Run built-in tests and exit")
    args = p.parse_args()

    if args.self_test:
        return run_self_tests()

    if args.offsets:
        offsets = parse_offsets_arg(args.offsets)
    elif args.offsets_file:
        offsets = parse_offsets_arg(Path(args.offsets_file).read_text())
    elif args.pattern_name:
        offsets = lookup_pattern_by_name(args.pattern_name)
        if offsets is None:
            print(f"Pattern '{args.pattern_name}' not found in KT_PATTERNS[]",
                  file=sys.stderr)
            return 2
    else:
        p.error("must specify --offsets, --offsets-file, or --pattern-name")

    result = validate(offsets, prime_bound=args.prime_bound,
                      ss_prime_bound=args.ss_prime_bound)
    print(json.dumps(result, indent=2))

    if not result.get("valid_input", False):
        return 2
    return 0 if result["is_admissible"] else 1


def run_self_tests():
    """Built-in tests (TPV1-T1..T6)."""
    tests = []

    # TPV1-T1: KT19_P0 valid
    kt19_p0 = [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76]
    r = validate(kt19_p0)
    tests.append(("TPV1-T1 KT19_P0 admissible+canonical", r["is_admissible"] and r["is_canonical"]
                  and r["k"] == 19 and r["diameter"] == 76))

    # TPV1-T2: non-admissible patterns flagged with witness prime.
    # [0,1,2] fails at q=2 (covers Z/2Z); [0,2,4,6,8] fails at q=3 (covers Z/3Z).
    r1 = validate([0, 1, 2])
    r2 = validate([0, 2, 4, 6, 8])
    tests.append(("TPV1-T2a [0,1,2] not admissible (witness q=2)",
                  not r1["is_admissible"] and r1["admissibility_witness_prime"] == 2))
    tests.append(("TPV1-T2b [0,2,4,6,8] not admissible (witness q=3)",
                  not r2["is_admissible"] and r2["admissibility_witness_prime"] == 3))

    # TPV1-T3: duplicates rejected
    r = validate([0, 2, 4, 4, 6])
    tests.append(("TPV1-T3 duplicates rejected", not r["valid_input"]))

    # TPV1-T4: unsorted auto-sorts
    r = validate([4, 0, 6])
    tests.append(("TPV1-T4 unsorted auto-sorts to [0,4,6]",
                  r["valid_input"] and r["canonical_form"] == [0, 2, 6]))
    # canonical of [0,4,6] is min of [0,4,6] and reflection [0,2,6] = [0,2,6]

    # TPV1-T5: KT22_P1 reflection has KT22_P1 as canonical
    kt22_p1 = [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84, 90]
    refl_kt22_p1 = sorted(90 - b for b in kt22_p1)
    r = validate(refl_kt22_p1)
    canon = r.get("canonical_form")
    tests.append(("TPV1-T5 KT22_P1 reflection canonicalizes to KT22_P1",
                  canon == kt22_p1))

    # TPV1-T6: singular series for KT22_P1 finite
    r = validate(kt22_p1)
    ss = r.get("singular_series_log10")
    tests.append(("TPV1-T6 KT22_P1 singular series finite",
                  ss is not None and math.isfinite(ss) and 5.0 < ss < 15.0))

    # Bonus: every engine catalog pattern admissible
    catalog = list(iter_catalog_patterns())
    catalog_ok = bool(catalog)
    for name, offs in catalog:
        r = validate(offs)
        if not r["is_admissible"]:
            print(f"  FAIL: {name} not admissible")
            catalog_ok = False
    tests.append((f"TPV1-bonus all {len(catalog)} catalog patterns admissible", catalog_ok))

    print("validate_pattern.py self-tests:")
    for name, passed in tests:
        status = "PASS" if passed else "FAIL"
        print(f"  [{status}] {name}")
    n_pass = sum(1 for _, p in tests if p)
    print(f"\n  {n_pass}/{len(tests)} PASS")
    return 0 if n_pass == len(tests) else 1


if __name__ == "__main__":
    sys.exit(main())
