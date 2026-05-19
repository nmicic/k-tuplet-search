#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
enumerate_patterns.py — Enumerate all admissible prime k-tuplet patterns
at given (k, diameter) with admissibility pruning. (T-PV3)

Algorithm: depth-first construction with incremental forbidden-set tracking.
Prunes any branch that violates admissibility at any prime <= max(k, diameter).

For k >= 22 single-threaded enumeration becomes slow. --workers N forks
top-level (b_1, b_2) prefixes across N processes in parallel. Pure
embarrassingly-parallel — each worker independent.

Usage:
    python3 tools/enumerate_patterns.py --k 22 --diameter 90
    python3 tools/enumerate_patterns.py --auto-h-k --k 25 --workers 8
    python3 tools/enumerate_patterns.py --k 16 --diameter 60 --output reports/k16_d60.json
    python3 tools/enumerate_patterns.py --self-test
    python3 tools/enumerate_patterns.py --auto-h-k --k 24 --format tsv

Output formats: json (default), tsv, txt, gp (GP/PARI vec input).

References:
    OEIS A008407 — least possible diameter of admissible k-tuple
    Norman Luhn, https://pzktupel.de/ktpatt_hl.php — narrow admissibles

Acknowledgments: this tool was developed for the kt-tuplet-search project
to verify catalog completeness of `KT_PATTERNS[]`. Generic enough for
external use; cite the project if useful.
"""

import argparse
import json
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

# Local imports
sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_pattern import primes_up_to, canonical_form  # noqa


# H(k) — least possible diameter of admissible k-tuple.
# k=2..24 are believed proven; k=25+ are conjectured (smallest known
# admissible; not proven minimal). Source: OEIS A008407 + Norman Luhn
# pzktupel.de.
#
# For k>=25 the values may be improved by enumeration with the tool itself
# (--auto-h-k will use this table; if no patterns are found at H(k),
# the actual H(k) is larger).
KNOWN_H_K = {
    # Proven (k <= 24)
    2: 2, 3: 6, 4: 8, 5: 12, 6: 16, 7: 20, 8: 26, 9: 30,
    10: 32, 11: 36, 12: 42, 13: 48, 14: 50, 15: 56, 16: 60,
    17: 66, 18: 70, 19: 76, 20: 80, 21: 84, 22: 90, 23: 94,
    24: 100,
    # Per Luhn ktpatt_hl.php (cross-validated 2026-05-10, commit b3c4e72).
    # OEIS A008407 appears stale at k>=29; Luhn's narrower values
    # cross-confirmed by exact-offset re-enumeration at k=29 d=130.
    25: 110, 26: 114, 27: 120, 28: 126, 29: 130, 30: 136,
    31: 140, 32: 146, 33: 152, 34: 156, 35: 158,
    36: 162, 37: 168, 38: 176, 39: 182, 40: 186,
    41: 188, 42: 196, 43: 200, 44: 210, 45: 212,
    46: 216, 47: 226, 48: 236, 49: 240, 50: 246,
}


def enumerate_patterns(k, diameter, canonical_only=True, verbose=False):
    """Enumerate all admissible k-tuplet patterns at exact (k, diameter).

    Returns list of tuples of offsets.
    Patterns are diameter-canonical (b_{k-1} == diameter).
    Optionally filtered to canonical-form-only (under reflection).
    """
    if k < 2:
        raise ValueError("k must be >= 2")
    if diameter < k - 1:
        return []  # impossible (need at least k distinct integers in [0, diameter])

    prime_bound = max(diameter, k)
    primes = primes_up_to(prime_bound)

    # Initial state: prefix = [0]; for each prime q, occupied = {0}.
    initial_occupied = {q: frozenset({0}) for q in primes}

    out = []
    counter = [0]
    last_print = [time.time()]
    start = time.time()

    def recurse(prefix, max_offset, occupied):
        # prefix: tuple of offsets so far, including b_0 = 0
        # max_offset: prefix[-1]
        # occupied: dict of frozenset of residues mod q for each prime q
        n_more = k - len(prefix)
        if n_more == 0:
            # complete pattern; assert b_{k-1} == diameter
            if max_offset == diameter:
                if not canonical_only or list(prefix) == list(canonical_form(list(prefix))):
                    out.append(prefix)
            return

        # next offset must be in [max_offset+1, diameter - (n_more - 1)]
        # (need n_more more offsets, the last must be <= diameter)
        lo = max_offset + 1
        hi = diameter - (n_more - 1)
        # If we still need more offsets and the last one must hit diameter,
        # the second-to-last must be <= diameter-1, etc.
        # When n_more == 1, this offset must equal diameter exactly.
        if n_more == 1:
            lo = hi = diameter

        for next_off in range(lo, hi + 1):
            counter[0] += 1
            if verbose and counter[0] % 1_000_000 == 0:
                now = time.time()
                if now - last_print[0] > 5:
                    elapsed = now - start
                    print(f"  [enumerate] depth={len(prefix)} explored={counter[0]:,} "
                          f"found={len(out):,} elapsed={elapsed:.1f}s", file=sys.stderr)
                    last_print[0] = now

            # Compute new occupied sets
            new_occupied = {}
            admissible = True
            for q, occ in occupied.items():
                r = next_off % q
                if r in occ:
                    new_occupied[q] = occ
                else:
                    new_occ = occ | {r}
                    if len(new_occ) == q:
                        # Adding next_off would cover all residues mod q
                        admissible = False
                        break
                    new_occupied[q] = frozenset(new_occ)
            if admissible:
                recurse(prefix + (next_off,), next_off, new_occupied)

    recurse((0,), 0, initial_occupied)
    return out


def _enumerate_from_prefix(args):
    """Worker for multiprocessing: enumerate from a fixed prefix.

    args = (k, diameter, prefix_tuple, canonical_only)
    Returns list of complete pattern tuples extending prefix.
    """
    k, diameter, prefix, canonical_only = args
    primes = primes_up_to(max(diameter, k))

    # Initialize occupied per prime from prefix
    occupied = {q: frozenset(b % q for b in prefix) for q in primes}
    # Verify prefix itself is admissible (should be by construction)
    for q, occ in occupied.items():
        if len(occ) == q:
            return []

    out = []
    n_more = k - len(prefix)
    if n_more == 0:
        if max(prefix) == diameter:
            if not canonical_only or list(prefix) == list(canonical_form(list(prefix))):
                out.append(prefix)
        return out

    def recurse(p, max_off, occ):
        n_left = k - len(p)
        if n_left == 0:
            if max_off == diameter:
                if not canonical_only or list(p) == list(canonical_form(list(p))):
                    out.append(p)
            return
        lo = max_off + 1
        hi = diameter - (n_left - 1)
        if n_left == 1:
            lo = hi = diameter
        for nxt in range(lo, hi + 1):
            new_occ = {}
            ok = True
            for q, o in occ.items():
                r = nxt % q
                if r in o:
                    new_occ[q] = o
                else:
                    no = o | {r}
                    if len(no) == q:
                        ok = False
                        break
                    new_occ[q] = frozenset(no)
            if ok:
                recurse(p + (nxt,), nxt, new_occ)

    recurse(prefix, prefix[-1] if prefix else 0, occupied)
    return out


def _gen_top_level_prefixes(k, diameter, depth=2):
    """Generate top-level prefixes of given depth, all admissible.

    Used to fan out work across multiprocessing pool. Each prefix is a
    tuple (0, b_1, b_2, ...) of length `depth+1`.
    """
    primes = primes_up_to(max(diameter, k))
    prefixes = [(0,)]
    for _ in range(depth):
        new_prefixes = []
        for pfx in prefixes:
            occ = {q: frozenset(b % q for b in pfx) for q in primes}
            n_more = k - len(pfx)
            if n_more <= 0:
                continue
            lo = pfx[-1] + 1
            hi = diameter - (n_more - 1)
            for nxt in range(lo, hi + 1):
                # quick admissibility check
                ok = True
                for q, o in occ.items():
                    r = nxt % q
                    if r not in o and len(o) + 1 == q:
                        ok = False
                        break
                if ok:
                    new_prefixes.append(pfx + (nxt,))
        prefixes = new_prefixes
    return prefixes


def enumerate_patterns_parallel(k, diameter, canonical_only=True, workers=4,
                                fanout_depth=2, verbose=False):
    """Multi-process enumeration. Splits work at top-level prefixes."""
    prefixes = _gen_top_level_prefixes(k, diameter, depth=fanout_depth)
    if verbose:
        print(f"  [parallel] {len(prefixes)} top-level prefixes, {workers} workers",
              file=sys.stderr)
    if not prefixes:
        return []

    args = [(k, diameter, pfx, canonical_only) for pfx in prefixes]
    with mp.Pool(workers) as pool:
        results = []
        completed = 0
        for r in pool.imap_unordered(_enumerate_from_prefix, args):
            results.extend(r)
            completed += 1
            if verbose and completed % max(1, len(prefixes) // 20) == 0:
                pct = 100 * completed / len(prefixes)
                print(f"  [parallel] {completed}/{len(prefixes)} prefixes done ({pct:.0f}%), "
                      f"{len(results)} patterns so far", file=sys.stderr)
    # Sort for deterministic output
    return sorted(set(results))


def enumerate_to_file(k, diameter, output_path, canonical_only=True, verbose=False,
                      workers=1, output_format="json"):
    """Run enumeration and write output in the requested format."""
    start = time.time()
    if workers > 1:
        patterns = enumerate_patterns_parallel(k, diameter,
                                                canonical_only=canonical_only,
                                                workers=workers,
                                                verbose=verbose)
    else:
        patterns = enumerate_patterns(k, diameter, canonical_only=canonical_only,
                                      verbose=verbose)
    elapsed = time.time() - start

    result_dict = {
        "k": k,
        "diameter": diameter,
        "exhaustive": True,
        "canonical_only": canonical_only,
        "total_count": len(patterns),
        "elapsed_s": round(elapsed, 3),
        "workers": workers,
        "tool_version": "1.1",
        "h_k_known": KNOWN_H_K.get(k),
        "is_narrow": (KNOWN_H_K.get(k) == diameter) if KNOWN_H_K.get(k) is not None else None,
        "patterns": [
            {"offsets": list(p), "name_suggestion": f"KT{k}_P{i}"}
            for i, p in enumerate(patterns)
        ],
    }

    if output_path:
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        if output_format == "json":
            Path(output_path).write_text(json.dumps(result_dict, indent=2))
        elif output_format == "tsv":
            lines = ["#k\tdiameter\tpattern_index\toffsets"]
            for i, p in enumerate(patterns):
                lines.append(f"{k}\t{diameter}\t{i}\t{','.join(str(b) for b in p)}")
            Path(output_path).write_text("\n".join(lines) + "\n")
        elif output_format == "txt":
            lines = [f"# k={k} diameter={diameter} count={len(patterns)} elapsed={elapsed:.1f}s",
                     f"# Generated by tools/enumerate_patterns.py"]
            for i, p in enumerate(patterns):
                lines.append(f"KT{k}_P{i}: " + ", ".join(str(b) for b in p))
            Path(output_path).write_text("\n".join(lines) + "\n")
        elif output_format == "gp":
            lines = [f"\\\\ k={k} diameter={diameter} count={len(patterns)}",
                     f"\\\\ Generated by tools/enumerate_patterns.py",
                     f"narrow_patterns_k{k} = ["]
            for i, p in enumerate(patterns):
                comma = "," if i < len(patterns) - 1 else ""
                lines.append(f"  [{', '.join(str(b) for b in p)}]{comma}")
            lines.append("];")
            Path(output_path).write_text("\n".join(lines) + "\n")
        else:
            raise ValueError(f"unknown format: {output_format}")
    return result_dict


def run_self_tests():
    """T-PV3 self-tests."""
    from validate_pattern import lookup_pattern_by_name, canonical_form, is_admissible

    tests = []

    # TPV3-T1: k=5 d=12 → KT5_P0 present
    pats = enumerate_patterns(5, 12, canonical_only=True)
    kt5_p0_canon = tuple(canonical_form(lookup_pattern_by_name("KT5_P0")))
    tests.append((f"TPV3-T1 k=5 d=12 -> {len(pats)} canonical, KT5_P0 in: {kt5_p0_canon in pats}",
                  kt5_p0_canon in pats))

    # TPV3-T2: k=7 d=20 → KT7_P0 present
    pats = enumerate_patterns(7, 20, canonical_only=True)
    kt7_p0_canon = tuple(canonical_form(lookup_pattern_by_name("KT7_P0")))
    tests.append((f"TPV3-T2 k=7 d=20 -> {len(pats)} canonical, KT7_P0 in: {kt7_p0_canon in pats}",
                  kt7_p0_canon in pats))

    # TPV3-T3: k=9 d=30 → KT9_P0 present (multiple canonical patterns expected)
    pats = enumerate_patterns(9, 30, canonical_only=True)
    kt9_p0_canon = tuple(canonical_form(lookup_pattern_by_name("KT9_P0")))
    tests.append((f"TPV3-T3 k=9 d=30 -> {len(pats)} canonical, KT9_P0 in: {kt9_p0_canon in pats}",
                  kt9_p0_canon in pats))

    # TPV3-T4: every enumerated pattern is admissible (sanity)
    sample_pats = enumerate_patterns(8, 26, canonical_only=True)
    all_adm = all(is_admissible(list(p)) for p in sample_pats)
    tests.append((f"TPV3-T4 every k=8 d=26 enumerated pattern is admissible ({len(sample_pats)} pats)",
                  all_adm))

    # TPV3-T5: k=16 d=60 → KT16_P0 and KT16_P1 both present
    pats = set(enumerate_patterns(16, 60, canonical_only=True))
    p0_canon = tuple(canonical_form(lookup_pattern_by_name("KT16_P0")))
    p1_canon = tuple(canonical_form(lookup_pattern_by_name("KT16_P1")))
    has_p0 = p0_canon in pats
    has_p1 = p1_canon in pats
    tests.append((f"TPV3-T5 k=16 d=60 -> {len(pats)} canonical (KT16_P0:{has_p0}, KT16_P1:{has_p1})",
                  has_p0 and has_p1))

    # TPV3-T6: every catalog pattern at narrow diameter is in enumeration (k=16, 17)
    catalog_at_narrow = {
        16: ["KT16_P0", "KT16_P1"],
        17: ["KT17_P0", "KT17_P1", "KT17_P2", "KT17_P3"],
    }
    h_k_for = {16: 60, 17: 66}
    all_ok = True
    for k, names in catalog_at_narrow.items():
        d = h_k_for[k]
        pats = set(enumerate_patterns(k, d, canonical_only=True))
        for name in names:
            offs = lookup_pattern_by_name(name)
            canon = tuple(canonical_form(offs))
            if canon not in pats:
                print(f"  MISS: {name} (canonical {canon}) not in k={k} d={d} enumeration", file=sys.stderr)
                all_ok = False
    tests.append(("TPV3-T6 all catalog k=16,17 patterns in enumeration", all_ok))

    # TPV3-T7: non-canonical enumeration count = canonical count + symmetric_count
    # (informational; just verify the non-canonical mode produces ≥ canonical count)
    canon = enumerate_patterns(7, 20, canonical_only=True)
    full = enumerate_patterns(7, 20, canonical_only=False)
    tests.append((f"TPV3-T7 k=7 d=20: canonical {len(canon)} <= full {len(full)} <= 2*canonical",
                  len(canon) <= len(full) <= 2 * len(canon)))

    print("enumerate_patterns.py self-tests:")
    for name, passed in tests:
        status = "PASS" if passed else "FAIL"
        print(f"  [{status}] {name}")
    n_pass = sum(1 for _, p in tests if p)
    print(f"\n  {n_pass}/{len(tests)} PASS")
    return 0 if n_pass == len(tests) else 1


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--k", type=int, help="k-tuplet size")
    p.add_argument("--diameter", type=int, help="exact diameter (b_{k-1})")
    p.add_argument("--auto-h-k", action="store_true",
                   help="use known H(k) value as diameter (k=2..30 supported)")
    p.add_argument("--no-canonical", action="store_true",
                   help="emit non-canonical patterns too (keeps reflections)")
    p.add_argument("--output", help="write output to this path")
    p.add_argument("--format", choices=["json", "tsv", "txt", "gp"], default="json",
                   help="output format (default: json)")
    p.add_argument("--workers", type=int, default=1,
                   help="parallel worker processes (default: 1, single-threaded)")
    p.add_argument("--verbose", action="store_true",
                   help="print progress to stderr during long enumerations")
    p.add_argument("--list-h-k", action="store_true",
                   help="print known H(k) table and exit")
    p.add_argument("--self-test", action="store_true",
                   help="run built-in tests and exit")
    args = p.parse_args()

    if args.list_h_k:
        print("Known H(k) — least possible diameter of admissible k-tuple:")
        print(f"  Source: OEIS A008407 + Norman Luhn pzktupel.de")
        print(f"  k=2..24: believed proven; k=25..30: conjectured (smallest known)")
        print()
        for k in sorted(KNOWN_H_K.keys()):
            note = "" if k <= 24 else "  (conjectured)"
            print(f"  H({k:2d}) = {KNOWN_H_K[k]}{note}")
        return 0

    if args.self_test:
        return run_self_tests()

    if args.k is None:
        p.error("--k required (or use --self-test or --list-h-k)")

    if args.auto_h_k:
        if args.k not in KNOWN_H_K:
            p.error(f"--auto-h-k: no known H(k) for k={args.k} "
                    f"(supported: {sorted(KNOWN_H_K.keys())})")
        diameter = KNOWN_H_K[args.k]
        if args.diameter is not None and args.diameter != diameter:
            p.error(f"--auto-h-k conflicts with --diameter (would be H({args.k})={diameter})")
    elif args.diameter is None:
        p.error("either --diameter or --auto-h-k required")
    else:
        diameter = args.diameter

    if args.workers < 1:
        args.workers = max(1, os.cpu_count() or 1)

    canonical_only = not args.no_canonical
    result = enumerate_to_file(args.k, diameter, args.output,
                               canonical_only=canonical_only,
                               verbose=args.verbose,
                               workers=args.workers,
                               output_format=args.format)
    if args.output:
        print(f"wrote {args.output}: {result['total_count']} patterns "
              f"in {result['elapsed_s']}s (workers={result['workers']})",
              file=sys.stderr)
    else:
        if args.format == "json":
            print(json.dumps(result, indent=2))
        else:
            # For non-json formats without output path, print summary to stderr
            print(f"  found {result['total_count']} patterns at k={args.k} "
                  f"d={diameter} in {result['elapsed_s']}s", file=sys.stderr)
            for pat in result["patterns"]:
                print(", ".join(str(b) for b in pat["offsets"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
