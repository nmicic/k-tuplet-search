#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
low_bit_scan.py — Exhaustive low-bit-range scan for prime k-tuplets at all
admissible patterns. Targets the asymmetric strategy: HL predicts smallest
k-tuplet at very high bits, but sporadic small examples might exist at
LOW bits that nobody systematically scans because "expected hits = 0".

Math is asymmetric in our favor at high k:
- HL density at k>=22 in [0, 2^64) is ~10^-9 per pattern
- But scanning [0, 2^64) at appropriate wheel is days-not-years
- Cost is bounded; payoff (any non-trivial high-k hit below 2^64) is
  potentially useful evidence
- Nobody else does this scan because their compute budgets target
  HL-predicted ranges (very high bits)

Usage:
    python3 tools/low_bit_scan.py --offsets "0,2,6,..." --max-bits 64
    python3 tools/low_bit_scan.py --pattern-name KT22_P1 --max-bits 64
    python3 tools/low_bit_scan.py --enum-narrow --k 25 --max-bits 64
    python3 tools/low_bit_scan.py --self-test
"""

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_pattern import (primes_up_to, occupied_residues, lookup_pattern_by_name,
                               canonical_form, is_admissible)


# Deterministic Miller-Rabin witnesses for various ranges.
# (Pomerance-Selfridge-Wagstaff and successors)
# For n < 3,317,044,064,679,887,385,961,981 (~ 2^81.4):
#   witnesses [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37] are sufficient.
DET_WITNESSES_2_81 = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]


def is_prime_deterministic(n, witnesses=DET_WITNESSES_2_81):
    """Deterministic Miller-Rabin for n < 2^81. Pure Python."""
    if n < 2:
        return False
    # Quick small-prime check
    SMALL_PRIMES = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47,
                    53, 59, 61, 67, 71, 73, 79, 83, 89, 97)
    for p in SMALL_PRIMES:
        if n == p:
            return True
        if n % p == 0:
            return False
    # Write n-1 = d * 2^r with d odd
    d = n - 1
    r = 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for a in witnesses:
        if a >= n:
            continue
        x = pow(a, d, n)
        if x == 1 or x == n - 1:
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def all_members_prime(base, offsets):
    """Test if all k members (base + b_i) are prime."""
    for b in offsets:
        if not is_prime_deterministic(base + b):
            return False
    return True


def compute_admissibles(offsets, primorial_n):
    """Compute admissible residues mod primorial of first N primes.

    Returns (primorial_value, sorted list of admissible residues).
    """
    primes_list = []
    p = 2
    while len(primes_list) < primorial_n:
        if is_prime_deterministic(p):
            primes_list.append(p)
        p += 1

    primorial = 1
    for p in primes_list:
        primorial *= p

    # Forbidden residues per prime
    forbidden_per_p = {}
    for p in primes_list:
        forbidden_per_p[p] = set((-b) % p for b in offsets)

    # Enumerate admissibles via CRT-like construction
    # For small primorial we can iterate; for large we'd need streaming
    if primorial > 10**8:
        raise ValueError(f"Primorial {primorial} too large for direct enumeration; "
                         f"use lower --primorial-n")

    admissibles = []
    for r in range(primorial):
        ok = True
        for p in primes_list:
            if r % p in forbidden_per_p[p]:
                ok = False
                break
        if ok:
            admissibles.append(r)

    return primorial, admissibles


def scan_pattern(offsets, max_bits, primorial_n=5, verbose=False, progress_cb=None):
    """Scan [0, 2^max_bits) for prime k-tuplets at the given pattern.

    Returns list of dicts: {base, members, hit_index}.
    """
    n_max = 1 << max_bits
    primorial, admissibles = compute_admissibles(offsets, primorial_n)

    if verbose:
        print(f"  primorial={primorial} ({primorial_n}#), "
              f"admissibles={len(admissibles)}", file=sys.stderr)
        n_periods = n_max // primorial
        n_candidates = len(admissibles) * n_periods
        print(f"  n_periods={n_periods:,}, n_candidates={n_candidates:,}",
              file=sys.stderr)
        # Subtract candidates where members include the small primes themselves
        # (legitimate; each small prime is itself prime)
        if max(offsets) < 100:
            print(f"  WARN: max offset {max(offsets)} < 100, "
                  f"some hits may include small-prime members", file=sys.stderr)

    hits = []
    last_progress = time.time()
    n_tested = 0
    skipped_low = 0

    # Skip candidates where any member is itself one of the small primes used
    # in the wheel (otherwise we'd report n=2 with member 2+offset=prime as "hit")
    # — but we DO want hits where members include small primes naturally.
    # The wheel admissibility already handles this correctly: r=0 mod 2 means
    # n=0,2,4,... and the "hit" at n=2 with member 2 being prime is legit.
    # So no special filtering needed; just report all hits.

    for r in admissibles:
        n = r
        while n < n_max:
            n_tested += 1
            # Skip n=0 and very small n where members <= 1 (not prime)
            if n + max(offsets) >= 2:  # at least 2 to be possibly prime
                if all_members_prime(n, offsets):
                    members = tuple(n + b for b in offsets)
                    hits.append({"base": n, "members": list(members),
                                 "hit_index": len(hits)})
                    if verbose:
                        print(f"  HIT #{len(hits)}: base={n} members={members}",
                              file=sys.stderr)
            n += primorial

            # Progress reporting
            if verbose and time.time() - last_progress > 5:
                pct = 100 * n / n_max
                rate = n_tested / max(1, time.time() - last_progress)
                print(f"  [scan] n={n:.2e}/2^{max_bits} ({pct:.1f}%), "
                      f"tested={n_tested:,}, hits={len(hits)}",
                      file=sys.stderr)
                last_progress = time.time()

    return hits, n_tested


def run_self_tests():
    """T-LBS self-tests."""
    tests = []

    # Test 1: KT5_P0 hits at low bases
    # Smallest twin-prime-like 5-tuplet: must find some
    kt5 = lookup_pattern_by_name("KT5_P0")
    hits, _ = scan_pattern(kt5, 16, primorial_n=4)  # search up to 2^16=65536
    tests.append((f"T-LBS-1 KT5_P0 to 2^16: {len(hits)} hits found (expect >=1)",
                  len(hits) >= 1))

    # Test 2: deterministic Miller-Rabin sanity
    primes_known = [2, 3, 5, 7, 11, 13, 9999999967, 18446744073709551557]  # last is 2^64-59 (prime)
    composites_known = [4, 6, 9, 25, 49, 91, 561, 1729]  # 561 and 1729 are Carmichael
    p_ok = all(is_prime_deterministic(n) for n in primes_known)
    c_ok = all(not is_prime_deterministic(n) for n in composites_known)
    tests.append((f"T-LBS-2 Miller-Rabin sanity: primes correct={p_ok}, composites correct={c_ok}",
                  p_ok and c_ok))

    # Test 3: KT7_P0 first hit known historically (5,7,11,13,17,23,...)
    # The smallest prime 7-tuplet of pattern KT7_P0 = (0,2,6,8,12,18,20)
    # is 11 + (0,2,6,8,12,18,20) = (11,13,17,19,23,29,31) — all prime
    kt7 = lookup_pattern_by_name("KT7_P0")
    hits, _ = scan_pattern(kt7, 8, primorial_n=4)
    found_11 = any(h["base"] == 11 for h in hits)
    tests.append((f"T-LBS-3 KT7_P0 finds smallest at base=11: {found_11}",
                  found_11))

    print("low_bit_scan.py self-tests:")
    for name, passed in tests:
        status = "PASS" if passed else "FAIL"
        print(f"  [{status}] {name}")
    n_pass = sum(1 for _, p in tests if p)
    print(f"\n  {n_pass}/{len(tests)} PASS")
    return 0 if n_pass == len(tests) else 1


def parse_offsets(s):
    s = s.strip().strip("[](){}")
    parts = s.replace(",", " ").split()
    return [int(p) for p in parts]


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    src = p.add_mutually_exclusive_group(required=False)
    src.add_argument("--offsets", help="Pattern offsets, comma-separated")
    src.add_argument("--pattern-name", help="KT-catalog pattern name")
    src.add_argument("--enum-narrow", action="store_true",
                     help="Enumerate all narrow canonical patterns at --k and scan each")
    p.add_argument("--k", type=int, help="k value (with --enum-narrow)")
    p.add_argument("--max-bits", type=int,
                   help="Scan range [0, 2^max-bits). 81 max for deterministic primality. "
                        "Required unless --self-test.")
    p.add_argument("--primorial-n", type=int, default=5,
                   help="Number of primes in wheel modulus (default 5 = 11#=2310)")
    p.add_argument("--output", help="Output JSON path for hits")
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()

    if args.self_test:
        return run_self_tests()

    if args.max_bits is None:
        p.error("--max-bits is required (or use --self-test)")
    if args.max_bits >= 82:
        p.error("--max-bits >= 82 not supported (deterministic primality limit)")

    # Determine patterns to scan
    pattern_list = []  # list of (name, offsets)
    if args.offsets:
        offs = parse_offsets(args.offsets)
        pattern_list.append(("custom", offs))
    elif args.pattern_name:
        offs = lookup_pattern_by_name(args.pattern_name)
        if offs is None:
            print(f"Pattern '{args.pattern_name}' not found", file=sys.stderr)
            return 2
        pattern_list.append((args.pattern_name, offs))
    elif args.enum_narrow:
        if args.k is None:
            p.error("--enum-narrow requires --k")
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from enumerate_patterns import enumerate_patterns, KNOWN_H_K
        if args.k not in KNOWN_H_K:
            p.error(f"k={args.k} not in KNOWN_H_K table")
        d = KNOWN_H_K[args.k]
        if args.verbose:
            print(f"Enumerating canonical narrow patterns at k={args.k} d={d}...",
                  file=sys.stderr)
        canonicals = enumerate_patterns(args.k, d, canonical_only=False)
        for i, p_offs in enumerate(canonicals):
            pattern_list.append((f"k{args.k}_d{d}_P{i}", list(p_offs)))
    else:
        p.error("specify --offsets, --pattern-name, --enum-narrow, or --self-test")

    all_results = []
    total_hits = 0
    total_tested = 0
    t0 = time.time()
    for name, offs in pattern_list:
        if args.verbose:
            print(f"=== Pattern {name}: k={len(offs)}, "
                  f"diameter={max(offs)} ===", file=sys.stderr)
        if not is_admissible(offs):
            print(f"  [SKIP] not admissible", file=sys.stderr)
            continue
        hits, n_tested = scan_pattern(offs, args.max_bits, args.primorial_n,
                                       verbose=args.verbose)
        total_hits += len(hits)
        total_tested += n_tested
        all_results.append({
            "pattern_name": name,
            "k": len(offs),
            "diameter": max(offs),
            "offsets": list(offs),
            "max_bits": args.max_bits,
            "primorial_n": args.primorial_n,
            "n_tested": n_tested,
            "n_hits": len(hits),
            "hits": hits,
        })

    elapsed = time.time() - t0
    summary = {
        "scan_range": f"[0, 2^{args.max_bits})",
        "patterns_scanned": len(all_results),
        "total_n_tested": total_tested,
        "total_hits": total_hits,
        "elapsed_s": round(elapsed, 3),
        "tool_version": "1.0",
        "results": all_results,
    }

    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(summary, indent=2))
        print(f"wrote {args.output}: {total_hits} hits across "
              f"{len(all_results)} patterns in {elapsed:.1f}s",
              file=sys.stderr)
    else:
        print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
