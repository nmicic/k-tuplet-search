#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
gen_pattern_header.py — regenerates src/common/ktuplet_pattern.{h,c} from
the canonical-pattern catalog produced by tools/patterns/pattern_enum.

Run from repo root:
    python3 tools/gen_pattern_header.py

Source of truth:
    tools/patterns/catalog/k{NN}_d{DDD}.json   (one file per (k, diameter) pair,
                                                emitted by tools/patterns/pattern_enum)

The generator:
  - Reads every k*_d*.json file under the catalog directory.
  - For each canonical B in the catalog, also emits R(B) (the reflection)
    when R(B) != B, so the table includes both search directions per
    equivalence class. This matches the historical records-driven catalog.
  - Sorts (k, offsets) lex within k and assigns KT<k>_P<i>.
  - Cross-checks against records.json: warns if any known-record pattern
    is missing from the generated catalog.
  - Emits a deterministic .h/.c pair (same input -> same output, byte-for-byte).

Authoritative reference:
  Norman Luhn's k-tuplet patterns + Hardy-Littlewood constants page:
    https://pzktupel.de/ktpatt_hl.php
  Always cross-check against that page. This generator and pattern_enum
  are convenience tools that emit the same admissible patterns in JSON
  for engine consumption. They are not peer-reviewed. If anything here
  disagrees with pzktupel.de, pzktupel.de is correct.
"""

import glob
import json
import os
import sys
from datetime import datetime, timezone

REPO_ROOT    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_DIR  = os.path.join(REPO_ROOT, "tools", "patterns", "catalog")
NAME_LOCKS   = os.path.join(REPO_ROOT, "tools", "patterns", "name_locks.json")
RECORDS_JSON = os.path.join(REPO_ROOT, "known", "records.json")
OUT_H        = os.path.join(REPO_ROOT, "src", "common", "ktuplet_pattern.h")
OUT_C        = os.path.join(REPO_ROOT, "src", "common", "ktuplet_pattern.c")

KT_MAX_K = 28  # Engine cap. Lowered 2026-05-10 from 32 to 28 after finding that
               # our prior H(k) dict was too wide for k>=29; we've removed all
               # k>28 catalog files. To re-enable k>=29, bump KT_MAX_K and
               # re-enumerate at Luhn-verified narrow diameters
               # (see https://pzktupel.de/ktpatt_hl.php for H(29)=130, etc.).


def reflect(offsets):
    """R(B) for B = [b_0=0, ..., b_{k-1}].  Returns sorted list."""
    last = offsets[-1]
    return sorted(last - b for b in offsets)


def load_catalog(catalog_dir):
    """Read every k*_d*.json file. Return dict[(k, offsets_tuple)] -> source_filename."""
    sources = {}
    files = sorted(glob.glob(os.path.join(catalog_dir, "k*_d*.json")))
    if not files:
        sys.exit(f"ERROR: no catalog files found under {catalog_dir}. "
                 f"Run tools/patterns/pattern_enum to populate it.")

    for path in files:
        with open(path) as f:
            data = json.load(f)
        k = data["k"]
        if k > KT_MAX_K:
            # Catalog files at k > KT_MAX_K are kept on disk for future use
            # but excluded from the engine header. Bumping KT_MAX_K to include
            # them is a deliberate decision (touches every GPU __constant__
            # allocation); do it explicitly when ready, not silently.
            print(f"WARN: {os.path.basename(path)} has k={k} > KT_MAX_K={KT_MAX_K}; "
                  f"SKIPPED from engine header (catalog file kept as-is).",
                  file=sys.stderr)
            continue
        if not data.get("canonical_only", True):
            print(f"WARN: {path} has canonical_only=False; the generator "
                  f"expects canonical-only inputs and will add reflections itself.",
                  file=sys.stderr)
        for entry in data["patterns"]:
            offsets = tuple(entry["offsets"])
            sources.setdefault((k, offsets), os.path.basename(path))
    return sources


def expand_with_reflections(canonicals):
    """Given dict[(k, offsets)] -> source, return dict including reflections.

    For each canonical B with R(B) != B, the reflection is added under the
    same source filename.
    """
    out = dict(canonicals)
    for (k, offsets), src in list(canonicals.items()):
        r = tuple(reflect(list(offsets)))
        if r != offsets and (k, r) not in out:
            out[(k, r)] = src
    return out


def load_name_locks(path):
    """Return dict (k, offsets_tuple) -> locked_name. Empty dict if file absent."""
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        data = json.load(f)
    locks = {}
    for name, offsets in data.get("locks", {}).items():
        m = name.split("_P")
        if len(m) != 2 or not m[0].startswith("KT"):
            sys.exit(f"ERROR: {path} has malformed lock name '{name}'")
        k = int(m[0][2:])
        locks[(k, tuple(offsets))] = name
    return locks


def assign_names(all_patterns, locks):
    """Assign names. Locked (k, offsets) keep their pinned name; remaining
    patterns get KT<k>_P<i> with i taken from the next free index per k.

    Sort within k: locked names first (by their P index), then unlocked patterns
    in lex order. This guarantees stable names across regenerations.
    """
    by_k = {}
    for k, offsets in all_patterns:
        by_k.setdefault(k, []).append(offsets)

    named = []
    for k in sorted(by_k):
        used_indices = set()
        locked_for_k = []
        unlocked_for_k = []
        for offsets in by_k[k]:
            name = locks.get((k, tuple(offsets)))
            if name:
                idx = int(name.split("_P")[1])
                used_indices.add(idx)
                locked_for_k.append((idx, offsets, name))
            else:
                unlocked_for_k.append(offsets)

        # Detect locks that didn't match any enumerated pattern (corruption / catalog gap).
        for (lk, loff), lname in locks.items():
            if lk == k and tuple(loff) not in {tuple(o) for o in by_k[k]}:
                print(f"WARN: lock {lname} (k={k}, offsets={list(loff)}) "
                      f"has no matching pattern in catalog. Engine code "
                      f"referencing this name will return NULL.",
                      file=sys.stderr)

        # Locked entries first, by their P index.
        locked_for_k.sort()
        for _, offsets, name in locked_for_k:
            named.append((k, list(offsets), name))

        # Unlocked entries: sort lex, assign next free P index.
        next_idx = 0
        for offsets in sorted(unlocked_for_k):
            while next_idx in used_indices:
                next_idx += 1
            name = f"KT{k}_P{next_idx}"
            used_indices.add(next_idx)
            named.append((k, list(offsets), name))
            next_idx += 1

    return named


def cross_check_records(named, records_path):
    """Warn (don't fail) if any records.json pattern is missing from the catalog."""
    if not os.path.exists(records_path):
        print(f"NOTE: {records_path} not found; skipping records cross-check.",
              file=sys.stderr)
        return

    with open(records_path) as f:
        records = json.load(f)

    catalog_set = {(k, tuple(offsets)) for k, offsets, _ in named}
    missing = []
    for k_str, v in records.items():
        k = int(k_str)
        for rec in v["records"]:
            t = (k, tuple(rec["offsets"]))
            if t not in catalog_set:
                missing.append(t)

    if missing:
        print(f"WARN: {len(missing)} known-record pattern(s) not in catalog "
              f"(check enumerator coverage):", file=sys.stderr)
        for k, offsets in missing[:10]:
            print(f"  k={k} offsets={list(offsets)}", file=sys.stderr)


PROVENANCE_BLOCK = """\
 * Catalog source of truth: tools/patterns/catalog/k{NN}_d{DDD}.json
 * Catalog generator:       tools/patterns/pattern_enum (C/OpenMP)
 * Header generator:        tools/gen_pattern_header.py
 *
 * Authoritative reference for prime k-tuplet patterns and Hardy-Littlewood
 * constants:  https://pzktupel.de/ktpatt_hl.php   (Norman Luhn)
 *
 * The tools in this repo (pattern_enum, gen_pattern_header.py) are a
 * convenience: they emit the same admissible patterns in machine-readable
 * JSON for engine consumption. They are NOT peer-reviewed; if there is any
 * discrepancy between this generated catalog and pzktupel.de, the canonical
 * pzktupel.de listing is correct and our tools have a bug. Cross-check
 * before publishing or relying on any pattern.
 *
 * Do not edit by hand. Run: python3 tools/gen_pattern_header.py
"""


def write_header(named, out_path, generated_utc):
    diam_summary = sorted({(k, offsets[-1]) for k, offsets, _ in named})
    summary_lines = []
    counts = {}
    for k, _, _ in named:
        counts[k] = counts.get(k, 0) + 1
    for k in sorted(counts):
        d = next(d for kk, d in diam_summary if kk == k)
        summary_lines.append(f" *   k={k:>2}  diameter={d:>3}  patterns={counts[k]}")

    lines = []
    lines.append("/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>")
    lines.append(" * SPDX-License-Identifier: Apache-2.0 */")
    lines.append("/*")
    lines.append(" * ktuplet_pattern.h — k-tuplet admissible-pattern definitions.")
    lines.append(" *")
    lines.append(f" * Generated: {generated_utc}")
    lines.append(f" * Total patterns: {len(named)} across k = "
                 f"{', '.join(str(k) for k in sorted(counts))}")
    lines.append(" *")
    lines.extend(summary_lines)
    lines.append(" *")
    lines.append(PROVENANCE_BLOCK.rstrip())
    lines.append(" */")
    lines.append("")
    lines.append("#ifndef KTUPLET_PATTERN_H")
    lines.append("#define KTUPLET_PATTERN_H")
    lines.append("")
    lines.append("#include <stdint.h>")
    lines.append("")
    lines.append(f"#define KT_MAX_K {KT_MAX_K}")
    lines.append("")
    lines.append("typedef struct {")
    lines.append("    int k;                  /* tuple length */")
    lines.append("    int diameter;           /* offsets[k-1] (offsets[0] is always 0) */")
    lines.append("    int offsets[KT_MAX_K];  /* offsets[0..k-1], strictly increasing, offsets[0]=0 */")
    lines.append('    const char* name;       /* e.g., "KT19_P0" */')
    lines.append("} KTupletPattern;")
    lines.append("")
    lines.append("/* Built-in patterns table — see provenance block at top of this file. */")
    lines.append("extern const KTupletPattern KT_PATTERNS[];")
    lines.append("extern const int KT_PATTERNS_COUNT;")
    lines.append("")
    lines.append("/* Admissibility check: returns 1 if admissible at all primes <= q_max, 0 otherwise.")
    lines.append(" * If not admissible, *bad_q is set to the witness prime (or untouched if NULL).")
    lines.append(" * Caller must pass q_max >= pat->diameter for the result to be a complete")
    lines.append(" * admissibility proof; for q > diameter the test is automatic because")
    lines.append(" * |forbidden_set| <= k < q holds trivially. */")
    lines.append("int kt_pattern_is_admissible(const KTupletPattern* pat, int q_max, int* bad_q);")
    lines.append("")
    lines.append("/* Forbidden-residue computation for prime q against pattern.")
    lines.append(" * Writes deduplicated forbidden residues to out[]. Returns count.")
    lines.append(" * out[] must have capacity >= k. */")
    lines.append("int kt_pattern_forbidden_residues(const KTupletPattern* pat, uint32_t q, uint32_t* out);")
    lines.append("")
    lines.append("/* Lookup by name; returns NULL if not found. */")
    lines.append("const KTupletPattern* kt_pattern_by_name(const char* name);")
    lines.append("")
    lines.append("/* Lookup by (k, offset_array). Order-sensitive; offsets must be sorted. Returns NULL if no exact match. */")
    lines.append("const KTupletPattern* kt_pattern_match(int k, const int* offsets);")
    lines.append("")
    lines.append("#endif /* KTUPLET_PATTERN_H */")
    lines.append("")

    with open(out_path, "w") as f:
        f.write("\n".join(lines))


def write_impl(named, sources, out_path, generated_utc):
    lines = []
    lines.append("/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>")
    lines.append(" * SPDX-License-Identifier: Apache-2.0 */")
    lines.append("/*")
    lines.append(" * ktuplet_pattern.c — pattern table and helper implementations.")
    lines.append(f" * Generated: {generated_utc}")
    lines.append(" *")
    lines.append(PROVENANCE_BLOCK.rstrip())
    lines.append(" */")
    lines.append("")
    lines.append('#include "ktuplet_pattern.h"')
    lines.append("#include <string.h>")
    lines.append("")
    lines.append("const KTupletPattern KT_PATTERNS[] = {")

    for k, offsets, name in named:
        diameter = offsets[-1]
        padded = offsets + [0] * (KT_MAX_K - len(offsets))
        inner = ", ".join(str(x) for x in padded)
        src = sources.get((k, tuple(offsets)), "?")
        lines.append(f'    /* {name:<10} from {src} */ '
                     f'{{ {k}, {diameter}, {{{inner}}}, "{name}" }},')

    lines.append("};")
    lines.append("")
    lines.append(f"const int KT_PATTERNS_COUNT = {len(named)};")
    lines.append("")
    lines.append("/* Forbidden residues for pattern pat at prime q.")
    lines.append(" * Formula: ((q - (b_i % q)) % q) for each offset b_i, deduplicated. */")
    lines.append("int kt_pattern_forbidden_residues(const KTupletPattern* pat, uint32_t q, uint32_t* out) {")
    lines.append("    int count = 0;")
    lines.append("    for (int i = 0; i < pat->k; i++) {")
    lines.append("        uint32_t r = (q - ((uint32_t)pat->offsets[i] % q)) % q;")
    lines.append("        int dup = 0;")
    lines.append("        for (int j = 0; j < count; j++) { if (out[j] == r) { dup = 1; break; } }")
    lines.append("        if (!dup) out[count++] = r;")
    lines.append("    }")
    lines.append("    return count;")
    lines.append("}")
    lines.append("")
    lines.append("int kt_pattern_is_admissible(const KTupletPattern* pat, int q_max, int* bad_q) {")
    lines.append("    uint32_t buf[KT_MAX_K];")
    lines.append("    for (int q = 2; q <= q_max; q++) {")
    lines.append("        int is_prime = 1;")
    lines.append("        for (int d = 2; d * d <= q; d++) { if (q % d == 0) { is_prime = 0; break; } }")
    lines.append("        if (!is_prime) continue;")
    lines.append("        int cnt = kt_pattern_forbidden_residues(pat, (uint32_t)q, buf);")
    lines.append("        if (cnt >= q) { if (bad_q) *bad_q = q; return 0; }")
    lines.append("    }")
    lines.append("    return 1;")
    lines.append("}")
    lines.append("")
    lines.append("const KTupletPattern* kt_pattern_by_name(const char* name) {")
    lines.append("    for (int i = 0; i < KT_PATTERNS_COUNT; i++)")
    lines.append("        if (strcmp(KT_PATTERNS[i].name, name) == 0) return &KT_PATTERNS[i];")
    lines.append("    return NULL;")
    lines.append("}")
    lines.append("")
    lines.append("const KTupletPattern* kt_pattern_match(int k, const int* offsets) {")
    lines.append("    for (int i = 0; i < KT_PATTERNS_COUNT; i++) {")
    lines.append("        if (KT_PATTERNS[i].k != k) continue;")
    lines.append("        int match = 1;")
    lines.append("        for (int j = 0; j < k; j++)")
    lines.append("            if (KT_PATTERNS[i].offsets[j] != offsets[j]) { match = 0; break; }")
    lines.append("        if (match) return &KT_PATTERNS[i];")
    lines.append("    }")
    lines.append("    return NULL;")
    lines.append("}")
    lines.append("")

    with open(out_path, "w") as f:
        f.write("\n".join(lines))


def main():
    canonicals = load_catalog(CATALOG_DIR)
    expanded = expand_with_reflections(canonicals)
    locks = load_name_locks(NAME_LOCKS)
    named = assign_names(set(expanded.keys()), locks)
    cross_check_records(named, RECORDS_JSON)

    # Use a stable date string (no time) so reruns within a day produce identical output.
    generated_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    write_header(named, OUT_H, generated_utc)
    write_impl(named, expanded, OUT_C, generated_utc)

    print(f"Wrote {len(named)} patterns to:")
    print(f"  {OUT_H}")
    print(f"  {OUT_C}")
    print()
    print("Per-k counts:")
    counts = {}
    for k, _, _ in named:
        counts[k] = counts.get(k, 0) + 1
    for k in sorted(counts):
        print(f"  k={k:>2}: {counts[k]} pattern(s)")


if __name__ == "__main__":
    main()
