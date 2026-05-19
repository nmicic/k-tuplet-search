# HOWTO: kt_lib_v1.gp — Interactive k-Tuplet Toolkit

A practical guide to the PARI/GP library for prime k-tuplet exploration,
pattern analysis, record verification, and search-space planning.
Primary record-search examples: k ∈ {19, 20, 21}; known-record replay covers
k=16..21.

---

## Quick Start

Install PARI/GP first if `gp` is not already available:

```bash
sudo apt install -y pari-gp
```

```bash
gp -q
\r kt_lib_v1.gp
```

39 self-tests run automatically. You should see:

```
  All self-tests passed (39 tests). Ready.
```

**Minimal smoke check:**

```gp
kt_verify_tuplet(5, [0,2,6,8,12])        \\ should return 1 (5,7,11,13,17 all prime)
kt_pattern_admissible_at([0,2,6,8,12], 7) \\ should return 1
kt_pattern_by_name("KT19_P0")             \\ should return [name, k, offsets]
```

---

## Table of Contents

1. [Pattern Fundamentals](#1-pattern-fundamentals)
2. [Admissibility and Forbidden Residues](#2-admissibility-and-forbidden-residues)
3. [Pattern Catalog](#3-pattern-catalog)
4. [Record Verification](#4-record-verification)
5. [Search-Space Planning](#5-search-space-planning)
6. [Primorial Wheel Construction](#6-primorial-wheel-construction)
7. [Function Reference](#7-function-reference)

---

## 1. Pattern Fundamentals

A prime k-tuplet is a set of k primes of the form `{n + b_0, n + b_1, ..., n + b_{k-1}}`
where `[b_0,...,b_{k-1}]` is an admissible pattern with `b_0 = 0`.

```gp
\\ Diameter (last offset)
kt_pattern_diameter([0, 2, 6, 8, 12])      \\ = 12

\\ Mirror a pattern: d - b_{k-1-i}
kt_mirror_pattern([0, 2, 6, 8, 12])        \\ = [0, 4, 6, 10, 12]

\\ Verify a known tuple at n=5 (checks isprime for all k members)
kt_verify_tuplet(5, [0, 2, 6, 8, 12])      \\ = 1 (5,7,11,13,17 all prime)
```

---

## 2. Admissibility and Forbidden Residues

A pattern is admissible at prime q iff not all residue classes mod q are covered
by its "forbidden residue" set. The forbidden residue for offset b_i at prime q is:

```
r_i = ((-b_i) mod q + q) mod q
```

This is exactly the formula from the analyzer (index.html line 441).

```gp
\\ Forbidden residues for k=5 at q=7: {0,1,2,5,6} (5 out of 7 classes blocked)
kt_pattern_forbidden([0, 2, 6, 8, 12], 7)      \\ = [0, 1, 2, 5, 6]

\\ Admissible: |forbidden| = 5 < 7 (residues 3,4 survive)
kt_pattern_admissible_at([0, 2, 6, 8, 12], 7)  \\ = 1

\\ Immune residues: classes where no member is divisible by q
kt_immune_residue_set([0, 2, 6, 8, 12], 7)     \\ = [3, 4]
```

**Why q > diameter is always admissible:** For `q > max(b_i)`, all offsets are distinct
mod q, giving at most k forbidden residues among q ≥ k+1 classes — admissibility is
automatic. The interesting constraint is for small primes `q ≤ k`.

---

## 3. Pattern Catalog

The GP catalog contains 25 planning/record-analysis patterns: 3 small patterns
(k=5,7,9), 16 record-derived patterns (k=16..21), and 6 high-k patterns
(k=22..24). The CUDA engine catalog is larger (97 patterns across k=3..28);
use `src/common/ktuplet_pattern.c` or `./kt_filter_v8 --list-patterns` for
the full engine list.

All GP catalog patterns are verified admissible for primes ≤ 101.

```gp
\\ List all catalog entries
KT_CATALOG

\\ Look up by name
kt_pattern_by_name("KT19_P0")           \\ [name, k, [offsets]]
kt_pattern_by_name("KT99_P0")           \\ 0 (not found)

\\ All patterns for k=17 (returns 4)
kt_pattern_unique_for_k(17)

\\ All patterns for k=19 (returns 4; H(19)=76, not 80)
kt_pattern_unique_for_k(19)
```

Pattern IDs use stable form `KT<k>_P<n>` where n is 0-indexed in lexicographic
order of the offset array per k.

---

## 4. Record Verification

Load the record table first, then verify:

```gp
\r gp/records.gp            \\ defines KT_RECORDS (227 records)

\\ Records for k=21
kt_records_for_k(21)

\\ Verify first 5 records per k (fast, ~seconds)
kt_check_record_table(KT_RECORDS, 5)    \\ returns [passed, failed, total]

\\ Verify all 227 records (may take minutes for large primes)
kt_check_record_table(KT_RECORDS, 0)
```

**Manual spot check:**

```gp
\\ Chermoni & Wroblewski 2015 k=21 record
kt_verify_tuplet(39433867730216371575457664399,
  [0,2,8,12,14,18,24,30,32,38,42,44,50,54,60,68,72,74,78,80,84])
\\ should return 1
```

---

## 5. Search-Space Planning

```gp
\\ How many prefix bits to fix for a given GPU budget?
\\ 90-bit search, k=19, 50G candidates/sec, 60 seconds
kt_prefix_bits_for_budget(90, 19, 50e9, 60)   \\ returns ~49

\\ Post-sieve survival fraction for k=19 after small-prime filtering
kt_sieve_survival_rate(kt_pattern_by_name("KT19_P0")[3], 97)

\\ Compare filtering efficiency for k=5 vs k=19
my(r5  = kt_sieve_survival_rate([0,2,6,8,12], 97));
my(r19 = kt_sieve_survival_rate(kt_pattern_by_name("KT19_P0")[3], 97));
printf("k=5 survival: %f, k=19 survival: %f\n", r5, r19);
```

---

## 6. Primorial Wheel Construction

```gp
\\ Primorials
kt_primorial(11)    \\ 2310 = 2*3*5*7*11
kt_primorial(13)    \\ 30030

\\ Admissible wheel positions mod 2310 for k=5 pattern
\\ (12 classes — these are the starting points for the wheel)
kt_admissible_count_mod([0, 2, 6, 8, 12], 2310)   \\ = 12
kt_admissible_offsets_mod([0, 2, 6, 8, 12], 2310)  \\ vector of 12 residues

\\ For larger primorials, use count (enumeration is slow)
kt_admissible_count_mod([0, 2, 6, 8, 12], kt_primorial(13))   \\ = 96
```

The admissible count equals `P# × ∏_q (1 − |forbidden_q| / q)` over primes q|P#.

---

## 7. Function Reference

### Layer 1 — Primitives

| Function | Description |
|----------|-------------|
| `kt_pattern_diameter(pat)` | Last offset (diameter) |
| `kt_pattern_forbidden(pat, q)` | Forbidden residues mod q (sorted, deduplicated) |
| `kt_pattern_admissible_at(pat, q)` | 1 if admissible at prime q |
| `kt_immune_residue_set(pat, q)` | Admissible residue classes mod q |
| `kt_verify_tuplet(n, pat)` | isprime for all k members at base n |
| `kt_mirror_pattern(pat)` | Reflected pattern (sorted `[d-b_i]`) |

### Layer 2 — Catalog

| Function | Description |
|----------|-------------|
| `KT_CATALOG` | Vector of `[name, k, [offsets]]`, 25 entries |
| `kt_pattern_by_name(name)` | Lookup by name string, returns entry or 0 |
| `kt_pattern_unique_for_k(k)` | All catalog entries for given k |

### Layer 3 — Record Table

Requires `\r gp/records.gp` before use.

| Function | Description |
|----------|-------------|
| `KT_RECORDS` | Full record table after loading records.gp |
| `kt_records_for_k(k)` | Records for given k |
| `kt_check_record_table(recs, {max=5})` | Verify records, returns `[passed, failed, total]` |

### Layer 4 — Search-Space Helpers

| Function | Description |
|----------|-------------|
| `kt_prefix_bits_for_budget(n_bits, k, tput, sec)` | Prefix bit count for GPU campaign |
| `kt_sieve_survival_rate(pat, q_max)` | Post-sieve survival fraction |

### Layer 5 — Primorial Helpers

| Function | Description |
|----------|-------------|
| `kt_primorial(n)` | Product of primes ≤ n |
| `kt_admissible_count_mod(pat, primorial)` | Count of wheel positions mod primorial |
| `kt_admissible_offsets_mod(pat, primorial)` | Enumerate wheel positions (small primorials only) |

---

## Cheat Sheet

```gp
\r kt_lib_v1.gp                              \\ load library (39 tests)
\r gp/records.gp                             \\ load record table

\\ -- Verify records --
kt_verify_tuplet(5, [0,2,6,8,12])           \\ quick check known 5-tuple
kt_check_record_table(KT_RECORDS, 5)        \\ verify 5 per k

\\ -- Explore patterns --
KT_CATALOG                                  \\ see all 25 GP catalog patterns
kt_pattern_unique_for_k(19)                 \\ 4 patterns for k=19
kt_pattern_by_name("KT21_P0")              \\ look up by name
kt_mirror_pattern(kt_pattern_by_name("KT17_P3")[3])  \\ = KT17_P1

\\ -- Admissibility analysis --
kt_pattern_forbidden([0,2,6,8,12], 7)      \\ = [0,1,2,5,6]
kt_immune_residue_set([0,2,6,8,12], 7)     \\ = [3,4]

\\ -- Plan GPU campaign --
kt_prefix_bits_for_budget(90, 19, 50e9, 60)  \\ ~49 prefix bits
kt_sieve_survival_rate(kt_pattern_by_name("KT19_P0")[3], 97)

\\ -- Primorial wheel --
kt_primorial(13)                            \\ 30030 = 13#
kt_admissible_count_mod([0,2,6,8,12], 2310) \\ 12 wheel positions
```
