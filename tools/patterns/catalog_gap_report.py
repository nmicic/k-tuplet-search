#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
catalog_gap_report.py — Compares KT_PATTERNS[] catalog to enumerated
admissible patterns, produces gap report. (T-PV4)

For each (k, H(k)):
  - Enumerate all canonical admissible patterns at the narrow diameter
  - Check which catalog entries match canonical patterns
  - Identify catalog entries that are reflections of canonical patterns
  - Report missing canonical patterns (catalog gaps)

Usage:
    python3 tools/catalog_gap_report.py --output reports/catalog_completeness.md
    python3 tools/catalog_gap_report.py --self-test
"""

import argparse
import datetime
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_pattern import (_CATALOG_PATTERN_RE, canonical_form, is_admissible,
                               singular_series_log10, lookup_pattern_by_name)
from enumerate_patterns import enumerate_patterns


# Known H(k) values per README.md
H_K = {
    5: 12,
    7: 20,
    9: 30,
    16: 60,
    17: 66,
    18: 70,
    19: 76,
    20: 80,
    21: 84,
    22: 90,
    23: 94,
    24: 100,
}


def load_catalog():
    """Parse src/common/ktuplet_pattern.c, return list of (name, k, diameter, offsets)."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    src = repo_root / "src" / "common" / "ktuplet_pattern.c"
    text = src.read_text()
    out = []
    for m in _CATALOG_PATTERN_RE.finditer(text):
        k = int(m.group(2))
        diameter = int(m.group(3))
        offs = [int(x.strip()) for x in m.group(4).split(",")]
        offs = offs[:k]
        out.append((m.group(5), k, diameter, offs))
    return out


def analyze_k_diameter(k, diameter, catalog_entries_at_kd, verbose=False):
    """For one (k, diameter) cell, enumerate canonical patterns and analyze
    catalog completeness.

    Math: A prime k-tuplet T has a unique difference-pattern D(T). Pattern B
    and its reflection R(B) describe TWO DIFFERENT equivalence classes of
    tuplets — running both finds different tuplets, not duplicates. Full
    catalog coverage of one (k, diameter) cell requires BOTH canonical AND
    reflection of every distinct equivalence class.

    Each canonical pattern P at (k, diameter) defines one equivalence class.
    For asymmetric P (P ≠ R(P)), the class has 2 'directions' — P and R(P).
    For symmetric P, the class has 1 direction.

    Engine completeness: covers a class fully if it stores BOTH P and R(P)
    (asymmetric case) or just P (symmetric case). Half-coverage means the
    engine finds only half the prime tuplets at that class.

    Returns dict with full coverage analysis.
    """
    if verbose:
        print(f"  enumerating k={k} d={diameter}...", file=sys.stderr)
    t0 = time.time()
    enumerated = enumerate_patterns(k, diameter, canonical_only=True)
    elapsed = time.time() - t0
    if verbose:
        print(f"  ...{len(enumerated)} canonical patterns ({elapsed:.1f}s)", file=sys.stderr)

    enumerated_set = set(enumerated)

    # For each enumerated canonical (equivalence class), categorize coverage
    # by whether catalog has canonical-direction, reflection-direction, both, or neither.
    coverage_per_class = {}  # canonical_tuple -> {has_canonical: bool, has_reflection: bool, symmetric: bool, catalog_entries: [names]}
    for canon in enumerated:
        diameter = max(canon)
        refl = tuple(sorted(diameter - b for b in canon))
        symmetric = (canon == refl)
        coverage_per_class[canon] = {
            "symmetric": symmetric,
            "has_canonical_direction": False,
            "has_reflection_direction": False,
            "catalog_entries": [],
        }

    for name, _, _, offs in catalog_entries_at_kd:
        offs_tup = tuple(offs)
        canon = tuple(canonical_form(offs))
        if canon not in coverage_per_class:
            # Catalog has a pattern that's not in our enumeration?
            # Shouldn't happen for known H(k); flag it.
            coverage_per_class[canon] = {
                "symmetric": False,
                "has_canonical_direction": False,
                "has_reflection_direction": False,
                "catalog_entries": [],
                "ANOMALY_not_in_enumeration": True,
            }
        if offs_tup == canon:
            coverage_per_class[canon]["has_canonical_direction"] = True
        else:
            coverage_per_class[canon]["has_reflection_direction"] = True
        coverage_per_class[canon]["catalog_entries"].append(name)

    # Classify each class
    classes_full_coverage = []   # both directions present (or symmetric + canonical present)
    classes_half_coverage = []   # only canonical OR only reflection (asymmetric only)
    classes_no_coverage = []     # neither direction present

    for canon, info in coverage_per_class.items():
        has_c = info["has_canonical_direction"]
        has_r = info["has_reflection_direction"]
        sym = info["symmetric"]
        if sym:
            if has_c:
                classes_full_coverage.append(canon)
            else:
                classes_no_coverage.append(canon)
        else:
            if has_c and has_r:
                classes_full_coverage.append(canon)
            elif has_c or has_r:
                classes_half_coverage.append((canon, "canonical_only" if has_c else "reflection_only"))
            else:
                classes_no_coverage.append(canon)

    return {
        "k": k,
        "diameter": diameter,
        "enumerated_count": len(enumerated),
        "enumerated": [list(p) for p in enumerated],
        "catalog_count": len(catalog_entries_at_kd),
        "classes_full_coverage_count": len(classes_full_coverage),
        "classes_half_coverage_count": len(classes_half_coverage),
        "classes_no_coverage_count": len(classes_no_coverage),
        "classes_half_coverage": [
            {"canonical": list(c), "missing_direction": which}
            for c, which in classes_half_coverage
        ],
        "classes_no_coverage": [list(c) for c in classes_no_coverage],
        "elapsed_s": round(elapsed, 3),
    }


def generate_report(results, output_path):
    """Generate markdown report."""
    today = datetime.date.today().isoformat()
    lines = [
        "# Catalog Completeness Report",
        "",
        f"**Date:** {today}",
        f"**Generated by:** `tools/catalog_gap_report.py`",
        f"**Source catalog:** `src/common/ktuplet_pattern.c` (KT_PATTERNS[])",
        f"**Method:** depth-first enumeration with admissibility pruning",
        f"  (`tools/enumerate_patterns.py`)",
        "",
        "## Methodology",
        "",
        "A prime k-tuplet T has a unique difference-pattern D(T). Pattern B and its reflection",
        "R(B) describe **two distinct equivalence classes** of tuplets: running B finds tuplets",
        "with D(T) = B; running R(B) finds tuplets with D(T) = R(B). For asymmetric B (B ≠ R(B)),",
        "these are different prime tuplets at different positions. The engine running both is",
        "doing legitimate distinct searches, not duplicate work.",
        "",
        "**Full catalog coverage** of (k, diameter) requires BOTH canonical AND reflection of every",
        "distinct equivalence class. **Half coverage** (only one direction) means the engine finds",
        "only half the prime tuplets at that class. **No coverage** means the equivalence class is",
        "entirely missing.",
        "",
        "## Summary table",
        "",
        "| k | H(k) | catalog | classes | full cov | half cov | no cov | search-coverage % |",
        "|---|------|---------|---------|----------|----------|--------|-------------------|",
    ]
    total_full = 0
    total_half = 0
    total_no = 0
    for r in results:
        nf = r["classes_full_coverage_count"]
        nh = r["classes_half_coverage_count"]
        nn = r["classes_no_coverage_count"]
        total = r["enumerated_count"]
        # Search-coverage % = (full*1.0 + half*0.5 + no*0.0) / total
        cov_pct = (nf * 1.0 + nh * 0.5) / total * 100 if total > 0 else 0.0
        total_full += nf
        total_half += nh
        total_no += nn
        lines.append(
            f"| {r['k']} | {r['diameter']} | {r['catalog_count']} | "
            f"{total} | {nf} | {nh} | **{nn}** | {cov_pct:.0f}% |"
        )
    grand_total = total_full + total_half + total_no
    grand_cov_pct = (total_full * 1.0 + total_half * 0.5) / grand_total * 100 if grand_total > 0 else 0.0
    lines += [
        "",
        f"**Total equivalence classes**: {grand_total}",
        f"**Full coverage**: {total_full}, **half coverage**: {total_half}, **no coverage**: {total_no}",
        f"**Aggregate search coverage**: {grand_cov_pct:.1f}%",
        "",
        "## Per-k details",
        "",
    ]
    for r in results:
        lines.append(f"### k={r['k']}, diameter={r['diameter']}")
        lines.append("")
        lines.append(f"- **Catalog entries**: {r['catalog_count']}")
        lines.append(f"- **Distinct equivalence classes (canonical patterns)**: {r['enumerated_count']}")
        lines.append(f"- **Full coverage** (both directions present): {r['classes_full_coverage_count']}")
        lines.append(f"- **Half coverage** (one direction only): {r['classes_half_coverage_count']}")
        lines.append(f"- **No coverage** (entire class missing): {r['classes_no_coverage_count']}")
        lines.append(f"- **Enumeration wallclock**: {r['elapsed_s']}s")
        lines.append("")

        if r["classes_half_coverage"]:
            lines.append("**Half-covered classes** (engine finds only one direction):")
            lines.append("")
            for entry in r["classes_half_coverage"]:
                missing_dir = entry["missing_direction"]
                canon = entry["canonical"]
                if missing_dir == "canonical_only":
                    # catalog has canonical, missing reflection
                    refl = sorted(max(canon) - b for b in canon)
                    lines.append(f"- canonical `{canon}` PRESENT; missing reflection `{refl}`")
                else:
                    # catalog has reflection, missing canonical
                    refl = sorted(max(canon) - b for b in canon)
                    lines.append(f"- reflection `{refl}` PRESENT; missing canonical `{canon}`")
            lines.append("")

        if r["classes_no_coverage"]:
            lines.append("**Uncovered classes** (entire equivalence class missing — both directions):")
            lines.append("")
            for canon in r["classes_no_coverage"]:
                refl = sorted(max(canon) - b for b in canon)
                if list(canon) == refl:
                    lines.append(f"- symmetric: `{canon}`")
                else:
                    lines.append(f"- canonical `{canon}` AND reflection `{refl}`")
            lines.append("")

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text("\n".join(lines))
    return output_path


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--output", default="reports/catalog_completeness.md",
                   help="Output markdown report path")
    p.add_argument("--json-output", help="Also write structured JSON")
    p.add_argument("--max-k", type=int, default=22,
                   help="Max k to enumerate (k=23 ~5min, k=24 ~30min; default 22)")
    p.add_argument("--include-built-ins", action="store_true",
                   help="Include built-in patterns k=5,7,9 (small)")
    p.add_argument("--self-test", action="store_true",
                   help="Run a quick smoke test on small k")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    if args.self_test:
        # Quick smoke: run analysis for k=16, k=17 only.
        catalog = load_catalog()
        results = []
        for k in [16, 17]:
            d = H_K[k]
            cat_kd = [c for c in catalog if c[1] == k and c[2] == d]
            r = analyze_k_diameter(k, d, cat_kd, verbose=True)
            results.append(r)
            print(f"k={k} d={d}: enumerated={r['enumerated_count']} "
                  f"catalog={r['catalog_count']} "
                  f"full={r['classes_full_coverage_count']} "
                  f"half={r['classes_half_coverage_count']} "
                  f"no_coverage={r['classes_no_coverage_count']}")
        return 0

    catalog = load_catalog()
    results = []
    ks = []
    if args.include_built_ins:
        ks += [5, 7, 9]
    ks += [k for k in [16, 17, 18, 19, 20, 21, 22, 23, 24] if k <= args.max_k]

    for k in ks:
        d = H_K[k]
        cat_kd = [c for c in catalog if c[1] == k and c[2] == d]
        r = analyze_k_diameter(k, d, cat_kd, verbose=args.verbose)
        results.append(r)

    out = generate_report(results, args.output)
    print(f"Report written to: {out}", file=sys.stderr)

    if args.json_output:
        Path(args.json_output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json_output).write_text(json.dumps(results, indent=2))
        print(f"JSON written to: {args.json_output}", file=sys.stderr)

    total_full = sum(r["classes_full_coverage_count"] for r in results)
    total_half = sum(r["classes_half_coverage_count"] for r in results)
    total_no = sum(r["classes_no_coverage_count"] for r in results)
    total = total_full + total_half + total_no
    cov = (total_full + 0.5 * total_half) / total * 100 if total else 0
    print(f"\nEquivalence classes: {total} total | "
          f"{total_full} full / {total_half} half / {total_no} no coverage")
    print(f"Aggregate search coverage: {cov:.1f}%")
    return 0 if total_no == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
