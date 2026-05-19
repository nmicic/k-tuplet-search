#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
test_pattern_tools.py — property/integration tests for pattern validation tooling.

Exercises validate_pattern.py + enumerate_patterns.py with mathematical property
assertions that go beyond per-tool self-tests. Catches Fix-B-class bugs:
determinism is checked by per-tool self-tests; *entropy* and *cross-component
invariants* are checked here.

Usage:
    python3 tools/test_pattern_tools.py
    python3 tools/test_pattern_tools.py --quiet  (only print pass/fail summary)
    python3 tools/test_pattern_tools.py --verbose

Exit 0 if all tests pass, 1 otherwise.
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_pattern import (
    canonical_form, is_canonical, is_admissible,
    singular_series_log10, occupied_residues, lookup_pattern_by_name,
    forbidden_residues, primes_up_to, iter_catalog_patterns,
)
from enumerate_patterns import enumerate_patterns


def _run_test(name, fn, verbose=False):
    """Run a test function and capture pass/fail + optional diagnostic."""
    try:
        result = fn()
        if isinstance(result, tuple):
            passed, info = result
        else:
            passed, info = result, None
        return name, passed, info
    except Exception as e:
        return name, False, f"exception: {e}"


# Properties as named functions so they're individually addressable.

def p1_canonical_idempotent():
    """canonical_form is idempotent: f(f(p)) == f(p)."""
    fail = []
    for name in ["KT19_P0", "KT19_P1", "KT22_P0", "KT22_P1", "KT24_P0", "KT5_P0"]:
        p = lookup_pattern_by_name(name)
        if p is None:
            continue
        c1 = tuple(canonical_form(p))
        c2 = tuple(canonical_form(list(c1)))
        if c1 != c2:
            fail.append((name, c1, c2))
    if fail:
        return False, f"failures: {fail}"
    return True, f"6 patterns, all idempotent"


def p2_canonical_reflection_invariant():
    """canonical_form(P) == canonical_form(R(P))."""
    fail = []
    for name in ["KT19_P0", "KT19_P1", "KT22_P0", "KT22_P1", "KT24_P0"]:
        p = lookup_pattern_by_name(name)
        if p is None:
            continue
        refl = sorted(max(p) - b for b in p)
        cp = tuple(canonical_form(p))
        cr = tuple(canonical_form(refl))
        if cp != cr:
            fail.append((name, cp, cr))
    if fail:
        return False, f"failures: {fail}"
    return True, "5 patterns, all reflection-invariant"


def p3_enum_canonical_only_correct():
    """Every pattern in canonical_only=True enumeration IS canonical."""
    bad = []
    for k, d in [(7, 20), (16, 60), (17, 66)]:
        pats = enumerate_patterns(k, d, canonical_only=True)
        for p in pats:
            if not is_canonical(list(p)):
                bad.append((k, d, p))
    if bad:
        return False, f"{len(bad)} non-canonical results found"
    return True, "k=7,16,17 enumerations all canonical"


def p4_enum_admissible():
    """Every enumerated pattern is admissible."""
    bad = []
    for k, d in [(7, 20), (16, 60), (17, 66)]:
        for canon_only in [True, False]:
            pats = enumerate_patterns(k, d, canonical_only=canon_only)
            for p in pats:
                if not is_admissible(list(p)):
                    bad.append((k, d, canon_only, p))
    if bad:
        return False, f"{len(bad)} non-admissible results"
    return True, "all enumerated patterns are admissible"


def p5_canonical_full_count_relation():
    """canonical_count <= full_count <= 2 * canonical_count."""
    fail = []
    for k, d in [(7, 20), (8, 26), (16, 60), (17, 66), (18, 70)]:
        canon = enumerate_patterns(k, d, canonical_only=True)
        full = enumerate_patterns(k, d, canonical_only=False)
        if not (len(canon) <= len(full) <= 2 * len(canon)):
            fail.append((k, d, len(canon), len(full)))
    if fail:
        return False, f"violations: {fail}"
    return True, "k=7,8,16,17,18: canon<=full<=2*canon holds"


def p6_forbidden_occupied_duality():
    """forbidden_q(P) = {(-r) mod q for r in occupied_q(P)}."""
    fail_count = 0
    for name in ["KT19_P0", "KT22_P0", "KT24_P2"]:
        p = lookup_pattern_by_name(name)
        if p is None:
            continue
        for q in [3, 5, 7, 11, 13, 17, 23, 29, 41, 47]:
            f_set = set(forbidden_residues(p, q))
            o_set = set(occupied_residues(p, q))
            derived = {(-r) % q for r in o_set}
            if f_set != derived:
                fail_count += 1
    if fail_count:
        return False, f"{fail_count} duality violations"
    return True, "30 (pattern, prime) pairs all consistent"


def p7_kt22_reflections_admissible_canonical():
    """The claimed missing k=22 reflections are admissible and have correct canonical mapping."""
    p0 = lookup_pattern_by_name("KT22_P0")
    p1 = lookup_pattern_by_name("KT22_P1")
    if p0 is None or p1 is None:
        return False, "catalog lookup failed"
    r0 = sorted(90 - b for b in p0)
    r1 = sorted(90 - b for b in p1)
    if not is_admissible(r0):
        return False, "R(KT22_P0) not admissible"
    if not is_admissible(r1):
        return False, "R(KT22_P1) not admissible"
    if tuple(canonical_form(r0)) != tuple(p0):
        return False, "canonical(R(KT22_P0)) != KT22_P0"
    if tuple(canonical_form(r1)) != tuple(p1):
        return False, "canonical(R(KT22_P1)) != KT22_P1"
    return True, "R(KT22_P0), R(KT22_P1) admissible & canonical-paired correctly"


def p8_random_bad_patterns_rejected():
    """Random non-admissible patterns are correctly flagged."""
    random.seed(42)
    fail = []
    # Pattern [0,1,2,...,k-1] always fails admissibility for k>=2 at q=2 (k>=3 at q=3 etc.)
    for _ in range(20):
        k = random.randint(3, 10)
        p = list(range(k))
        is_adm = is_admissible(p)
        if is_adm:
            fail.append(p)
    if fail:
        return False, f"{len(fail)} bad patterns falsely accepted"
    return True, "20 sequential bad patterns correctly rejected"


def p9_singular_series_kt19_p0():
    """KT19_P0 singular series log10 ~ 7.768."""
    p = lookup_pattern_by_name("KT19_P0")
    if p is None:
        return False, "catalog lookup failed"
    ss = singular_series_log10(p, prime_bound=10000)
    expected = 7.768
    delta = abs(ss - expected)
    if delta > 0.05:
        return False, f"computed {ss:.4f}, expected ~{expected}, delta {delta:.4f}"
    return True, f"computed {ss:.4f}, delta {delta:.4f}"


def p10_singular_series_kt22_p1():
    """KT22_P1 singular series log10 ~ 9.183."""
    p = lookup_pattern_by_name("KT22_P1")
    if p is None:
        return False, "catalog lookup failed"
    ss = singular_series_log10(p, prime_bound=10000)
    expected = 9.183
    delta = abs(ss - expected)
    if delta > 0.05:
        return False, f"computed {ss:.4f}, expected ~{expected}, delta {delta:.4f}"
    return True, f"computed {ss:.4f}, delta {delta:.4f}"


def p11_catalog_all_admissible():
    """Every catalog pattern in src/common/ktuplet_pattern.c is admissible."""
    catalog = list(iter_catalog_patterns())
    bad = []
    for name, p in catalog:
        if not is_admissible(p):
            bad.append(f"{name}: not admissible")
    if not catalog:
        bad.append("catalog parser found no patterns")
    if bad:
        return False, f"{len(bad)} catalog issues: {bad[:3]}"
    return True, f"all {len(catalog)} catalog patterns admissible"


def p12_enumerator_finds_all_catalog_at_narrow():
    """Every catalog pattern at its narrow diameter is in the enumeration."""
    catalog_at_narrow = {
        16: (60, ["KT16_P0", "KT16_P1"]),
        17: (66, ["KT17_P0", "KT17_P1", "KT17_P2", "KT17_P3"]),
        18: (70, ["KT18_P0", "KT18_P1"]),
    }
    bad = []
    for k, (d, names) in catalog_at_narrow.items():
        # Use canonical_only=False so reflections appear directly
        pats = set(enumerate_patterns(k, d, canonical_only=False))
        for name in names:
            p = lookup_pattern_by_name(name)
            if p is None:
                bad.append(f"{name}: not in catalog")
                continue
            if tuple(p) not in pats:
                bad.append(f"{name}: not in enumeration at k={k} d={d}")
    if bad:
        return False, f"{len(bad)} missing: {bad[:3]}"
    return True, "k=16,17,18 catalog patterns all in enumeration"


def p13_canonical_form_monotone_under_reflection():
    """min(P, R(P)) == canonical_form(P) by construction; sanity check."""
    bad = []
    for name in ["KT19_P0", "KT19_P1", "KT19_P2", "KT19_P3", "KT22_P0"]:
        p = lookup_pattern_by_name(name)
        if p is None:
            continue
        refl = sorted(max(p) - b for b in p)
        expected = min(tuple(p), tuple(refl))
        actual = tuple(canonical_form(p))
        if expected != actual:
            bad.append((name, expected, actual))
    if bad:
        return False, f"violations: {bad}"
    return True, "5 patterns, canonical_form == min(P, R(P))"


def p14_primes_up_to_correct():
    """primes_up_to is correct for small inputs (sanity check on prime sieve)."""
    expected = {
        10: [2, 3, 5, 7],
        20: [2, 3, 5, 7, 11, 13, 17, 19],
        100: [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97],
    }
    for n, exp in expected.items():
        got = primes_up_to(n)
        if got != exp:
            return False, f"primes_up_to({n}): got {got}, expected {exp}"
    return True, "primes_up_to correct at n=10, 20, 100"


def p15_reflection_of_reflection_is_identity():
    """R(R(P)) == P for any pattern P."""
    bad = []
    for name in ["KT19_P0", "KT22_P1", "KT24_P2"]:
        p = lookup_pattern_by_name(name)
        if p is None:
            continue
        d = max(p)
        r = sorted(d - b for b in p)
        rr = sorted(d - b for b in r)
        if list(p) != rr:
            bad.append((name, p, rr))
    if bad:
        return False, f"violations: {bad}"
    return True, "3 patterns, R(R(P)) == P holds"


ALL_TESTS = [
    ("P1 canonical_form idempotent", p1_canonical_idempotent),
    ("P2 canonical_form reflection-invariant", p2_canonical_reflection_invariant),
    ("P3 enum canonical_only=True yields canonical patterns", p3_enum_canonical_only_correct),
    ("P4 every enumerated pattern is admissible", p4_enum_admissible),
    ("P5 canonical/full count relationship", p5_canonical_full_count_relation),
    ("P6 forbidden/occupied residue duality", p6_forbidden_occupied_duality),
    ("P7 KT22 reflections admissible & canonical-paired", p7_kt22_reflections_admissible_canonical),
    ("P8 random bad patterns rejected (entropy/negative case)", p8_random_bad_patterns_rejected),
    ("P9 KT19_P0 singular series log10 ~7.768", p9_singular_series_kt19_p0),
    ("P10 KT22_P1 singular series log10 ~9.183", p10_singular_series_kt22_p1),
    ("P11 every catalog pattern is admissible", p11_catalog_all_admissible),
    ("P12 enumerator finds every catalog pattern at narrow diameter", p12_enumerator_finds_all_catalog_at_narrow),
    ("P13 canonical_form == min(P, R(P))", p13_canonical_form_monotone_under_reflection),
    ("P14 primes_up_to correct (sieve sanity)", p14_primes_up_to_correct),
    ("P15 R(R(P)) == P (reflection involution)", p15_reflection_of_reflection_is_identity),
]


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--quiet", action="store_true", help="only summary")
    p.add_argument("--verbose", action="store_true", help="extra detail")
    args = p.parse_args()

    if not args.quiet:
        print(f"Running {len(ALL_TESTS)} property tests...\n")

    n_pass = 0
    n_fail = 0
    for name, fn in ALL_TESTS:
        n, passed, info = _run_test(name, fn)
        if passed:
            n_pass += 1
            if not args.quiet:
                detail = f" ({info})" if info and args.verbose else ""
                print(f"  [PASS] {n}{detail}")
        else:
            n_fail += 1
            if not args.quiet:
                detail = f" ({info})" if info else ""
                print(f"  [FAIL] {n}{detail}")
            else:
                # always print failures even in quiet mode
                detail = f" ({info})" if info else ""
                print(f"  [FAIL] {n}{detail}", file=sys.stderr)

    if not args.quiet:
        print(f"\n  {n_pass}/{len(ALL_TESTS)} PASS")
    else:
        print(f"{n_pass}/{len(ALL_TESTS)} PASS", file=sys.stderr if n_fail else sys.stdout)

    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
