# Pattern Validation & Enumeration Tools

Generic tooling for validating admissible prime k-tuplet patterns and emitting them in JSON for engine consumption.

> **Authoritative reference**: Norman Luhn's [https://pzktupel.de/ktpatt_hl.php](https://pzktupel.de/ktpatt_hl.php) — published prime k-tuplet patterns, narrow diameters H(k), and Hardy-Littlewood constants for k=2..50. The tools here re-derive admissibility locally so the search engine has a machine-readable JSON catalog; they are **not peer-reviewed**. If output disagrees with ktpatt_hl.php, the tools are wrong. Always cross-check.

Developed for the [kt-tuplet-search](https://github.com/nmicic/k-tuplet-search) project but designed for standalone use.

## Quick start

```bash
# Validate a single pattern
python3 tools/patterns/validate_pattern.py --offsets "0,4,6,10,12,16,24,30,34,40,42,46,52,54,60,66,70,72,76"

# Look up by name (from KT_PATTERNS[] catalog)
python3 tools/patterns/validate_pattern.py --pattern-name KT19_P0

# Enumerate all canonical narrow patterns at k=22
python3 tools/patterns/enumerate_patterns.py --auto-h-k --k 22

# Faster with multiprocessing
python3 tools/patterns/enumerate_patterns.py --auto-h-k --k 25 --workers 8

# List known H(k) values
python3 tools/patterns/enumerate_patterns.py --list-h-k

# Compare engine catalog to enumerated set
python3 tools/patterns/catalog_gap_report.py --output reports/catalog_completeness.md

# Run property tests
python3 tools/patterns/test_pattern_tools.py

# Build and use the FAST C enumerator (~250× faster for k>=22)
make -C tools/patterns                       # build pattern_enum binary
make -C tools/patterns test                  # 14/14 self-tests
./tools/patterns/pattern_enum --k 27 --diameter 120 > reports/k27.json
./tools/patterns/pattern_enum --k 30 --diameter 136 --threads 32 > reports/k30.json
```

## Tool inventory

| Tool | Language | Purpose |
|---|---|---|
| `validate_pattern.py` | Python | Verify admissibility, compute canonical form, singular series |
| `enumerate_patterns.py` | Python | Enumerate all admissible patterns at given (k, diameter); reference impl |
| `pattern_enum.c` + `Makefile` | C + OpenMP | **~250× faster** enumerator for k≥22 production runs |
| `catalog_gap_report.py` | Python | Compare `KT_PATTERNS[]` catalog to enumeration |
| `test_pattern_tools.py` | Python | 15 property/integration tests |
| `low_bit_scan.py` | Python | Exhaustive scan of [0, 2^B) for sporadic high-k tuplets |

All Python tools: stdlib only (no sympy, no numpy required).
C tool: stdlib + libgomp (standard with gcc).

## Math

### Admissibility

A pattern `B = {b_0, b_1, ..., b_{k-1}}` with `0 = b_0 < b_1 < ... < b_{k-1}` is **admissible** iff for every prime `q ≤ max(b_{k-1}, k)`, the set of residues `{b_i mod q}` does NOT cover all of `Z/qZ`. Equivalently, there exists some residue `r` such that no `b_i` is congruent to `−r` mod `q`.

### Forbidden residues

Per prime `q`, the forbidden residue set is `F_q(B) = {(−b_i) mod q : i = 0..k-1}` (deduplicated). A candidate `n` is killed by prime `q` iff `n mod q ∈ F_q(B)`.

### Reflection symmetry

Pattern `B`'s reflection is `R(B) = (0, b_{k-1} − b_{k-2}, b_{k-1} − b_{k-3}, ..., b_{k-1})`. Both `B` and `R(B)` are admissible iff one is. Their singular series (Hardy-Littlewood density) is equal.

**Important**: `B` and `R(B)` describe **distinct equivalence classes of prime k-tuplets**. A prime tuplet `T = {p_0 < ... < p_{k-1}}` has a unique difference pattern `D(T) = (0, p_1−p_0, ..., p_{k-1}−p_0)` matching either `B` or `R(B)` but not both (unless `B == R(B)`, the symmetric case). Searching for both `B` and `R(B)` is two distinct searches, not duplicate work.

### Canonical form

The canonical form of `B` is `min(B, R(B))` lexicographically. For each pair `{B, R(B)}` with `B ≠ R(B)`, exactly one is canonical. Symmetric patterns (`B == R(B)`) are their own canonical.

### Singular series

For an admissible pattern at k members:

```
S(B) = ∏_q ((q − |F_q(B)|) / q) × (q / (q−1))^k
```

Higher S = denser pattern (more expected primes per N). The tool computes `log10(S)` over primes ≤ 10000 by default.

### H(k) — least possible diameter

The minimum diameter over all admissible k-tuplets. Known values:

| k  | H(k) | Status |
|----|------|--------|
| 2  | 2    | proven (twin primes) |
| 3  | 6    | proven |
| 4  | 8    | proven |
| 5  | 12   | proven |
| 6  | 16   | proven |
| 7  | 20   | proven |
| 8  | 26   | proven |
| 9  | 30   | proven |
| 10 | 32   | proven |
| 11 | 36   | proven |
| 12 | 42   | proven |
| 13 | 48   | proven |
| 14 | 50   | proven |
| 15 | 56   | proven |
| 16 | 60   | proven |
| 17 | 66   | proven |
| 18 | 70   | proven |
| 19 | 76   | proven |
| 20 | 80   | proven |
| 21 | 84   | proven |
| 22 | 90   | believed proven |
| 23 | 94   | believed proven |
| 24 | 100  | believed proven |
| 25 | 110  | conjectured (smallest known) |
| 26 | 114  | conjectured |
| 27 | 120  | conjectured |
| 28 | 126  | conjectured |
| 29 | 130  | conjectured |
| 30 | 136  | conjectured |

Source: [Norman Luhn — pzktupel.de/ktpatt_hl.php](https://pzktupel.de/ktpatt_hl.php) (authoritative). OEIS A008407 also lists this sequence but at the time of writing has stale values for k ≥ 29 — cross-check against ktpatt_hl.php first.

For `k ≥ 25`, run `enumerate_patterns.py --auto-h-k --k <K>` to verify the H(k) value (if no patterns exist at the listed H(k), then either H(k) is larger or there's a bug — check ktpatt_hl.php).

## Performance

### Enumeration time at narrow diameter (measured on 4-core box)

| k | diameter | Python single | Python 8 workers | C binary 4 threads | canonical patterns |
|---|---|---|---|---|---|
| 5 | 12 | <0.1 s | — | <0.001 s | 1 |
| 9 | 30 | <0.1 s | — | <0.001 s | 2 |
| 16 | 60 | 0.6 s | — | 0.003 s | 1 |
| 17 | 66 | 1.7 s | — | 0.008 s | 2 |
| 18 | 70 | 3.4 s | — | 0.016 s | 1 |
| 19 | 76 | 9.7 s | — | 0.043 s | 2 |
| 20 | 80 | 19 s | — | 0.077 s | 1 |
| 21 | 84 | 34 s | — | 0.143 s | 1 |
| 22 | 90 | 87 s | 21.5 s | **0.37 s** | 2 |
| 23 | 94 | 152 s | — | 0.63 s | 1 |
| 24 | 100 | 412 s (~7 min) | — | **1.6 s** | 2 |
| 25 | 110 | ~42 min | 640 s (~10.5 min) | **9.8 s** | 9 |
| **26** | **114** | (~14 min @ 4 workers extrap) | TBD | **16.5 s** | **1** |
| **27** | **120** | (~1.3 hr @ 4 workers extrap) | TBD | **79 s** | **4** |
| 28 | 126 | — | — | ~7 min (extrap) | TBD |
| 30 | 136 | — | — | ~3-4 hr (extrap) | TBD |
| 32 | 146 | — | — | ~17 days @ 4 cores → ~2 days @ 32 cores | TBD |
| 33 | 152 | — | — | ~5-10 days @ 32 cores | TBD |
| 36 | 192 | — | — | ~6 months @ 32 cores | TBD |

**C binary speedup**: ~235-258× over Python single-thread, measured at k=22-25.

**Key finding from k=25 enumeration**: 9 canonical patterns at H(25)=110 — substantially more than k=22-24 which had 1-2. **k=26 has only 1; k=27 has 4** (counts non-monotonic; admissibility constraints at primes near diameter dominate).

For multi-thread Python: near-linear speedup up to physical-core count. C binary OpenMP: same scaling, but base timings 200×+ faster. CPU time grows roughly 5-6× per increment of k at narrow diameter regardless of language.

### Memory

Bounded by output size. At narrow diameter, the canonical-pattern count is small (~1-5 per (k, H(k)) for k=16..24). Wider diameters can produce more patterns; output may exceed 1 GiB at k=20+ with diameter `H(k) + 8` and `--no-canonical`.

## Output formats

`enumerate_patterns.py --format` accepts:

- `json` (default) — structured with metadata (k, diameter, count, elapsed, etc.)
- `tsv` — tab-separated values, importable into spreadsheets
- `txt` — one pattern per line, plain text
- `gp` — GP/PARI vector input format

Example GP output (k=7, d=20):

```gp
\\ k=7 diameter=20 count=1
\\ Generated by tools/patterns/enumerate_patterns.py
narrow_patterns_k7 = [
  [0, 2, 6, 8, 12, 18, 20]
];
```

## Validation

Self-tests built into each tool:

```bash
python3 tools/patterns/validate_pattern.py --self-test       # 8/8 PASS
python3 tools/patterns/enumerate_patterns.py --self-test     # 7/7 PASS
python3 tools/patterns/test_pattern_tools.py --quiet         # 15/15 PASS (cross-tool)
```

Property tests assert:
- `canonical_form` is idempotent and reflection-invariant
- Every enumerated pattern is admissible
- `canonical_count ≤ full_count ≤ 2 × canonical_count`
- Singular series matches hand-computed reference values for KT19_P0 and KT22_P1
- Reflections `R(R(P)) == P`
- The engine catalog patterns parse and validate

## What these tools do (and don't claim)

- Emit admissible patterns in JSON for engine consumption (`pattern_enum --format json`).
- Convert formats: `--format gp` (GP/PARI), `--format tsv` (spreadsheet-ready), `--format header` (C struct rows for the engine catalog).
- Provide a local convenience for ordering scan candidates by truncated singular series (`rank_novel_by_density.py`).

**These tools do not** define new patterns, claim novel mathematical results, or replace [pzktupel.de/ktpatt_hl.php](https://pzktupel.de/ktpatt_hl.php) as the reference for admissible k-tuplet patterns and Hardy-Littlewood constants. They are unreviewed local code; bugs land in them before they land on the canonical reference page. Cross-check.

If you find issues, please report at https://github.com/nmicic/k-tuplet-search/issues.

## Known limitations

- **Wider-than-narrow patterns**: tool enumerates at exact diameter only. To find all admissible patterns with diameter ≤ D, run separately at each diameter.
- **Singular series precision**: 10⁴ prime bound by default (gives ~6 significant digits). Use `--ss-prime-bound` for higher precision in `validate_pattern.py`.
- **k > 30 conjectured H(k) absent**: extend `KNOWN_H_K` in source if needed.
- **Multi-process top-level fan-out depth**: 2 levels by default; for k > 28 may want depth 3 (modify `_gen_top_level_prefixes`'s `depth` parameter).

## License

Apache-2.0. See repo LICENSE.
