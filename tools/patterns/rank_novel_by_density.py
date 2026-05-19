#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
rank_novel_by_density.py — compute a truncated Hardy-Littlewood singular-
series value per catalog pattern, then rank by E[hits at b=N] so a finite
GPU budget can scan the highest-density patterns first.

NOTE on naming: the filename and CLI flags reference "novel" for historical
reasons. There is nothing novel in the catalog relative to public sources;
all patterns appear in Norman Luhn's authoritative listing at
https://pzktupel.de/ktpatt_hl.php, which also publishes the corresponding
Hardy-Littlewood constants G_k. This script is a local convenience for
ordering scan candidates — it does not replace ktpatt_hl.php as a reference.

Usage:
    python3 tools/patterns/rank_novel_by_density.py
    python3 tools/patterns/rank_novel_by_density.py --bits 64
    python3 tools/patterns/rank_novel_by_density.py --bits 80 --output reports/rank.json
    python3 tools/patterns/rank_novel_by_density.py --bits 64 --tsv

What it computes:
    For each catalog pattern B = {0, b_1, ..., b_{k-1}}, the Hardy-Littlewood
    singular series:
        S(B) = prod_{p prime, p<=p_max}  (1 - nu(p)/p) / (1 - 1/p)^k
    where nu(p) = |{b_i mod p}|. The product converges; truncating at
    p_max=65537 with double-precision floats is sufficient for ordering,
    NOT for publishable absolute values. Cross-check against G_k on
    ktpatt_hl.php before reporting any singular-series number.

    Then the expected count of prime k-tuplets in [0, 2^B):
        E[hits | bits=B] = S(B) * 2^B / (ln 2^B)^k

Tiering (by k-bucket compute cost; within a tier sort by E[hits] desc):
    Tier 1: k<=24   (cheapest; closest to non-trivial E)
    Tier 2: 25..27  (~10x compute)
    Tier 3: 28+     (days per pattern; defer or pick top-N within budget)
"""

import argparse
import glob
import json
import math
import os
import sys

REPO_ROOT   = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG_DIR = os.path.join(REPO_ROOT, "tools", "patterns", "catalog")

# Historical artifact: this set originally filtered "patterns not in Luhn's
# catalog" out as "novel". Luhn's ktpatt_hl.php covers everything we have, so
# the filter is a no-op in practice. Kept only for the --include-luhn flag's
# negation; harmless when LUHN_AT_K is empty.
LUHN_AT_K = {}

# Truncation for the singular-series product. p_max=65537 is comfortably
# above any b_{k-1} we'll see (k=31 narrow ~ d=146); the tail
# prod_{p>p_max} (1 - k/p)/(1 - 1/p)^k = 1 + O(1/p_max) for p>diameter
# so log10 ranking is stable to ~6 decimals.
P_MAX = 65537


def primes_up_to(n):
    sieve = [True] * (n + 1)
    sieve[0] = sieve[1] = False
    for i in range(2, int(n**0.5) + 1):
        if sieve[i]:
            for j in range(i*i, n + 1, i):
                sieve[j] = False
    return [p for p, ok in enumerate(sieve) if ok]


def log10_singular_series(offsets, primes):
    """Return log10(S(B)) for offsets B (sorted, B[0]=0) using primes <= p_max."""
    k = len(offsets)
    log_S = 0.0
    for p in primes:
        nu = len(set(b % p for b in offsets))
        if nu == p:
            return float("-inf")  # not admissible at p; S(B) = 0
        # log[(1 - nu/p) / (1 - 1/p)^k] = log(1 - nu/p) - k * log(1 - 1/p)
        log_factor = math.log(1.0 - nu / p) - k * math.log(1.0 - 1.0 / p)
        log_S += log_factor
    return log_S / math.log(10.0)


def expected_hits_log10(log10_S, k, bits):
    """log10(E[hits below 2^bits]) using HL prediction."""
    log10_N = bits * math.log10(2.0)
    log_lnN = math.log10(bits * math.log(2.0))  # log10(ln 2^bits)
    return log10_S + log10_N - k * log_lnN


def tier(k, log10_E):
    """Practical scan tier. Reflects compute cost (which is dominated by k)
    not just expected hits, because at high k narrow E[hits] at b=64 is
    universally tiny — but lower-k novel territory is still cheaper to scan
    and the Poisson tail there is closest to "non-trivial". Within a tier,
    rank by log10_E.

      Tier 1: k=22..24 novel — 4 patterns, hours per pattern, biggest E[hits]
      Tier 2: k=25..27       — 28 patterns, ~10x compute, still tractable
      Tier 3: k=28..31       — 280 patterns, days+ per pattern, defer or
                                pick top-N by log10_E within budget
    """
    if k <= 24:
        return 1
    if k <= 27:
        return 2
    return 3


def load_catalog():
    """Yield (k, offsets_tuple, source_filename) for every catalog entry,
    including reflections (because the .h/.c table includes them)."""
    seen = set()
    out = []
    for path in sorted(glob.glob(os.path.join(CATALOG_DIR, "k*_d*.json"))):
        d = json.load(open(path))
        k = d["k"]
        for entry in d["patterns"]:
            offs = tuple(sorted(entry["offsets"]))
            if (k, offs) not in seen:
                seen.add((k, offs))
                out.append((k, offs, os.path.basename(path)))
            last = offs[-1]
            refl = tuple(sorted(last - x for x in offs))
            if refl != offs and (k, refl) not in seen:
                seen.add((k, refl))
                out.append((k, refl, os.path.basename(path) + " (reflection)"))
    return out


def name_for(k, offsets, ktuplet_pattern_c):
    """Lookup the KT<k>_P<i> name for (k, offsets) in the generated header."""
    import re
    nums_str = "{" + ", ".join(str(x) for x in list(offsets) + [0] * (32 - len(offsets))) + "}"
    pattern = re.compile(rf"\b(KT{k}_P\d+)\b\s*(?:from\s+\S+\s*)?\*/\s*\{{\s*{k}\s*,\s*\d+\s*,\s*{re.escape(nums_str)}")
    m = pattern.search(ktuplet_pattern_c)
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bits", type=int, default=64,
                    help="bit-range of the planned scan (default: 64)")
    ap.add_argument("--output", type=str, default=None,
                    help="path for JSON output (default: stdout-only summary)")
    ap.add_argument("--tsv", action="store_true",
                    help="emit machine-readable TSV alongside the human summary")
    ap.add_argument("--include-luhn", action="store_true",
                    help="also rank Luhn-known patterns (default: novel only)")
    ap.add_argument("--p-max", type=int, default=P_MAX,
                    help=f"prime cap for singular-series product (default: {P_MAX})")
    ap.add_argument("--min-k", type=int, default=22,
                    help="minimum k to include (default: 22; novel territory starts here)")
    args = ap.parse_args()

    primes = primes_up_to(args.p_max)
    print(f"# Computing singular series with primes <= {args.p_max} "
          f"({len(primes)} primes), bits={args.bits}",
          file=sys.stderr)

    cat = load_catalog()
    hdr_path = os.path.join(REPO_ROOT, "src", "common", "ktuplet_pattern.c")
    hdr_text = open(hdr_path).read() if os.path.exists(hdr_path) else ""

    rows = []
    for k, offsets, source in cat:
        if k < args.min_k:
            continue
        if not args.include_luhn and offsets in LUHN_AT_K.get(k, set()):
            continue
        log10_S = log10_singular_series(offsets, primes)
        if log10_S == float("-inf"):
            continue  # not admissible (shouldn't happen — catalog is admissible)
        log10_E = expected_hits_log10(log10_S, k, args.bits)
        name = name_for(k, offsets, hdr_text) or "?"
        rows.append({
            "name": name,
            "k": k,
            "diameter": offsets[-1],
            "offsets": list(offsets),
            "source": source,
            "log10_singular_series": round(log10_S, 4),
            f"log10_expected_hits_b{args.bits}": round(log10_E, 4),
            f"expected_hits_b{args.bits}": 10 ** log10_E,
            "tier": tier(k, log10_E),
        })

    # Sort: by tier ascending, then by E[hits] descending within tier.
    rows.sort(key=lambda r: (r["tier"], -r[f"log10_expected_hits_b{args.bits}"]))

    # Stdout summary
    print(f"\n{'rank':>4}  {'name':<10}  {'k':>2}  {'tier':>4}  "
          f"{'log10(S)':>9}  {'log10(E_hits)':>13}  {'E_hits @ b='+str(args.bits):>17}")
    print("-" * 76)
    for i, r in enumerate(rows, start=1):
        E = r[f"expected_hits_b{args.bits}"]
        e_str = f"{E:.3e}" if E < 1.0 else f"{E:.2f}"
        print(f"{i:>4}  {r['name']:<10}  {r['k']:>2}  {r['tier']:>4}  "
              f"{r['log10_singular_series']:>9.4f}  "
              f"{r[f'log10_expected_hits_b{args.bits}']:>13.4f}  "
              f"{e_str:>17}")

    # Tier counts
    tier_count = {1: 0, 2: 0, 3: 0}
    for r in rows:
        tier_count[r["tier"]] += 1
    print("-" * 76)
    print(f"\nTier counts (novelty={'all' if args.include_luhn else 'novel only'}, bits={args.bits}):")
    print(f"  Tier 1 (E>=0.01, scan now):       {tier_count[1]:>4}")
    print(f"  Tier 2 (1e-6<=E<0.01, scan next): {tier_count[2]:>4}")
    print(f"  Tier 3 (E<1e-6, defer):           {tier_count[3]:>4}")
    print(f"  TOTAL:                            {sum(tier_count.values()):>4}")

    if args.output:
        with open(args.output, "w") as f:
            json.dump({
                "bits": args.bits,
                "p_max": args.p_max,
                "min_k": args.min_k,
                "include_luhn": args.include_luhn,
                "ranked": rows,
                "tier_counts": tier_count,
            }, f, indent=2)
        print(f"\nWrote ranked output: {args.output}", file=sys.stderr)

    if args.tsv:
        import io
        tsv_path = (args.output or "rank_novel.tsv").replace(".json", ".tsv")
        with open(tsv_path, "w") as f:
            cols = ["rank", "name", "k", "tier", "log10_S", f"log10_E_b{args.bits}",
                    f"E_b{args.bits}", "diameter", "source"]
            f.write("\t".join(cols) + "\n")
            for i, r in enumerate(rows, start=1):
                f.write("\t".join([
                    str(i), r["name"], str(r["k"]), str(r["tier"]),
                    f"{r['log10_singular_series']:.4f}",
                    f"{r[f'log10_expected_hits_b{args.bits}']:.4f}",
                    f"{r[f'expected_hits_b{args.bits}']:.6e}",
                    str(r["diameter"]), r["source"],
                ]) + "\n")
        print(f"Wrote TSV: {tsv_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
