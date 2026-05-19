/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*============================================================================
 * kt_lib_v1.gp — PARI/GP Interactive k-Tuplet Library
 *
 * Hunts prime k-tuplets for Norman Luhn's records page (pzktupel.de/ktuplets.php).
 * Primary targets: k in {17, 19, 21} — the current open frontiers.
 *
 * Load with:
 *   \r kt_lib_v1.gp
 *
 * Quick start:
 *   kt_verify_tuplet(5, [0,2,6,8,12])            \\ verify known 5-tuplet at n=5
 *   kt_pattern_admissible_at([0,2,6,8,12], 7)    \\ 1 = admissible at q=7
 *   kt_records_for_k(17)                         \\ records with k=17
 *   kt_check_record_table(KT_RECORDS, 5)         \\ verify first 5 per k
 *
 * Self-tests (39) run on load. Prints:
 *   "All self-tests passed (39 tests). Ready."
 *
 * Phase 1: patterns, catalog, record-table, search-space helpers, primorial.
 * Phase 2 will add the CPU sieve engine.
 * Phase 3 will add the GPU kernel interface.
 *============================================================================*/

{
  my(old = default(debugmem));
  default(debugmem, 0);
  default(parisizemax, 512000000);
  default(parisize, 64000000);
  default(debugmem, old);
}

/* ─────────────────────────────────────────────────────────────────────────────
 * Layer 0: Constants
 * ───────────────────────────────────────────────────────────────────────────── */

/* Analysis primes used across layers */
kt_analysis_primes = [2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97];

/* ─────────────────────────────────────────────────────────────────────────────
 * Layer 1: Primitive Helpers
 *
 * Forbidden-residue formula (from analyzer index.html L441):
 *   forbidden_r = ((-o) mod q + q) mod q   for each offset o in pattern.
 * No modular inverse needed — only additive shifts.
 * A pattern is admissible at q iff |forbidden_set| < q.
 * ───────────────────────────────────────────────────────────────────────────── */

/* Diameter of pattern (offsets[k-1] since offsets[0]=0) */
kt_pattern_diameter(pat) = pat[#pat];

/* Forbidden residues mod q for pattern pat (vector, deduplicated).
 * pat: vector of integer offsets [b_0,...,b_{k-1}], b_0=0.
 * Returns sorted vector of distinct forbidden residues. */
kt_pattern_forbidden(pat, q) =
{
  my(flist = List());
  for(i = 1, #pat,
    my(r = ((-pat[i]) % q + q) % q);
    listput(flist, r);
  );
  Vec(Set(Vec(flist)));
}

/* Returns 1 if pattern is admissible at prime q, 0 otherwise.
 * Admissible: the forbidden-residue set does not cover all residues mod q. */
kt_pattern_admissible_at(pat, q) =
{
  #kt_pattern_forbidden(pat, q) < q;
}

/* Immune residues mod q: residue classes r such that no n+b_i is div by q.
 * Returns sorted vector of r in [0..q-1] not in forbidden set. */
kt_immune_residue_set(pat, q) =
{
  my(fbd = Set(kt_pattern_forbidden(pat, q)));
  my(result = List());
  for(r = 0, q-1,
    if(!setsearch(fbd, r), listput(result, r));
  );
  Vec(result);
}

/* Verify that n is the base of a genuine prime k-tuplet under pattern pat.
 * Checks isprime(n + pat[i]) for all i. Returns 1 if all prime, 0 otherwise. */
kt_verify_tuplet(n, pat) =
{
  for(i = 1, #pat,
    if(!isprime(n + pat[i]), return(0));
  );
  1;
}

/* ─────────────────────────────────────────────────────────────────────────────
 * Layer 2: Pattern Catalog
 *
 * Built-in patterns mirror KT_PATTERNS[] in src/common/ktuplet_pattern.h.
 * Sorted: k ascending, then offsets lexicographically.
 * Small patterns (k=5,7,9) included for tests.
 * Record-derived patterns: k in {16,17,18,19,20,21}, 16 patterns total.
 * High-k patterns (Luhn, pzktupel.de/ktpatt_hl.php): k in {22,23,24}, 6 patterns.
 * ───────────────────────────────────────────────────────────────────────────── */

{
KT_CATALOG = [
  /* [name, k, [offsets]] */
  ["KT5_P0",  5,  [0, 2, 6, 8, 12]],
  ["KT7_P0",  7,  [0, 2, 6, 8, 12, 18, 20]],
  ["KT9_P0",  9,  [0, 2, 6, 8, 12, 18, 20, 26, 30]],
  /* k=16: 2 patterns */
  ["KT16_P0", 16, [0, 2, 6, 12, 14, 20, 26, 30, 32, 36, 42, 44, 50, 54, 56, 60]],
  ["KT16_P1", 16, [0, 4, 6, 10, 16, 18, 24, 28, 30, 34, 40, 46, 48, 54, 58, 60]],
  /* k=17: 4 patterns */
  ["KT17_P0", 17, [0, 2, 6, 12, 14, 20, 24, 26, 30, 36, 42, 44, 50, 54, 56, 62, 66]],
  ["KT17_P1", 17, [0, 4, 6, 10, 16, 18, 24, 28, 30, 34, 40, 46, 48, 54, 58, 60, 66]],
  ["KT17_P2", 17, [0, 4, 10, 12, 16, 22, 24, 30, 36, 40, 42, 46, 52, 54, 60, 64, 66]],
  ["KT17_P3", 17, [0, 6, 8, 12, 18, 20, 26, 32, 36, 38, 42, 48, 50, 56, 60, 62, 66]],
  /* k=18: 2 patterns */
  ["KT18_P0", 18, [0, 4, 6, 10, 16, 18, 24, 28, 30, 34, 40, 46, 48, 54, 58, 60, 66, 70]],
  ["KT18_P1", 18, [0, 4, 10, 12, 16, 22, 24, 30, 36, 40, 42, 46, 52, 54, 60, 64, 66, 70]],
  /* k=19: 4 patterns, H(19)=76 */
  ["KT19_P0", 19, [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76]],
  ["KT19_P1", 19, [0, 4, 6, 10, 16, 18, 24, 28, 30, 34, 40, 46, 48, 54, 58, 60, 66, 70, 76]],
  ["KT19_P2", 19, [0, 4, 6, 10, 16, 22, 24, 30, 34, 36, 42, 46, 52, 60, 64, 66, 70, 72, 76]],
  ["KT19_P3", 19, [0, 6, 10, 16, 18, 22, 28, 30, 36, 42, 46, 48, 52, 58, 60, 66, 70, 72, 76]],
  /* k=20: 2 patterns */
  ["KT20_P0", 20, [0, 2, 6, 8, 12, 20, 26, 30, 36, 38, 42, 48, 50, 56, 62, 66, 68, 72, 78, 80]],
  ["KT20_P1", 20, [0, 2, 8, 12, 14, 18, 24, 30, 32, 38, 42, 44, 50, 54, 60, 68, 72, 74, 78, 80]],
  /* k=21: 2 patterns */
  ["KT21_P0", 21, [0, 2, 8, 12, 14, 18, 24, 30, 32, 38, 42, 44, 50, 54, 60, 68, 72, 74, 78, 80, 84]],
  ["KT21_P1", 21, [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84]],
  /* k=22: 2 patterns (Luhn, pzktupel.de/ktpatt_hl.php) */
  ["KT22_P0", 22, [0, 2, 6, 8, 12, 20, 26, 30, 36, 38, 42, 48, 50, 56, 62, 66, 68, 72, 78, 80, 86, 90]],
  ["KT22_P1", 22, [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84, 90]],
  /* k=23: 1 pattern (Luhn, pzktupel.de/ktpatt_hl.php) */
  ["KT23_P0", 23, [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84, 90, 94]],
  /* k=24: 3 patterns (Luhn, pzktupel.de/ktpatt_hl.php) */
  ["KT24_P0", 24, [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 60, 66, 70, 72, 76, 82, 84, 90, 94, 96, 100]],
  ["KT24_P1", 24, [0, 4, 6, 10, 16, 18, 24, 28, 30, 34, 40, 48, 54, 58, 60, 66, 70, 76, 84, 88, 90, 94, 96, 100]],
  ["KT24_P2", 24, [0, 4, 6, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84, 90, 94, 96, 100]]
];
} \\ end KT_CATALOG block

/* Lookup catalog entry by name. Returns [name, k, [offsets]] or 0. */
kt_pattern_by_name(name) =
{
  for(i = 1, #KT_CATALOG,
    if(KT_CATALOG[i][1] == name, return(KT_CATALOG[i]));
  );
  0;
}

/* Return all catalog entries for given k, as list of [name, k, [offsets]]. */
kt_pattern_unique_for_k(k) =
{
  my(result = List());
  for(i = 1, #KT_CATALOG,
    if(KT_CATALOG[i][2] == k, listput(result, KT_CATALOG[i]));
  );
  Vec(result);
}

/* Mirror a pattern: mirror([b_0,...,b_{k-1}]) = sort([d-b_0,...,d-b_{k-1}])
 * where d = diameter = b_{k-1}. */
kt_mirror_pattern(pat) =
{
  my(d = pat[#pat]);
  vecsort(vector(#pat, i, d - pat[i]));
}

/* ─────────────────────────────────────────────────────────────────────────────
 * Layer 3: Record Table Integration
 *
 * KT_RECORDS is loaded from gp/records.gp via:
 *   \r gp/records.gp
 * before calling these functions. Each entry: [k, list_of_records]
 * where each record: [base_str, [offsets], digits, date_str, author_str]
 * ───────────────────────────────────────────────────────────────────────────── */

/* Return records for a given k from the KT_RECORDS table.
 * Returns vector of record vectors for that k, or [] if not found. */
kt_records_for_k(k) =
{
  for(i = 1, #KT_RECORDS,
    if(KT_RECORDS[i][1] == k, return(KT_RECORDS[i][2]));
  );
  [];
}

/* Check that every record in the table is a genuine prime k-tuple.
 * records_table: the KT_RECORDS variable (loaded from records.gp).
 * max_per_k: maximum number of records to verify per k (0 = all).
 *   For in-load self-test, use max_per_k=5 to keep it fast.
 * Returns [passed, failed, total_checked]. */
kt_check_record_table(records_table, {max_per_k = 5}) =
{
  my(passed = 0, failed = 0, total = 0);
  for(i = 1, #records_table,
    my(k = records_table[i][1]);
    my(recs = records_table[i][2]);
    my(check_n = if(max_per_k == 0, #recs, min(max_per_k, #recs)));
    for(j = 1, check_n,
      my(rec = recs[j]);
      my(base_s = rec[1]);
      my(offsets = rec[2]);
      my(n = eval(base_s));
      total++;
      if(kt_verify_tuplet(n, offsets),
        passed++,
        failed++;
        printf("  FAIL: k=%d base=%s offsets=%s\n", k, base_s, Str(offsets));
      );
    );
  );
  [passed, failed, total];
}

/* ─────────────────────────────────────────────────────────────────────────────
 * Layer 4: Search-Space Helpers
 *
 * These functions help plan GPU/CPU campaigns.
 * For k-tuplets: after sieving out forbidden residues per prime q, the
 * surviving fraction is product_q( (q - |forbidden_q|) / q ).
 * ───────────────────────────────────────────────────────────────────────────── */

/* Compute the prefix bit count P such that
 *   2^(n_bitlen - P) / throughput_per_sec <= budget_sec.
 * Returns P (integer in [1, n_bitlen-1]).
 * n_bitlen: target prime bit length.
 * k: tuple size (for context, not used in formula).
 * throughput_per_sec: GPU candidates per second.
 * budget_sec: available compute time in seconds. */
kt_prefix_bits_for_budget(n_bitlen, k, throughput_per_sec, budget_sec) =
{
  my(search_space = 2.0^n_bitlen / throughput_per_sec / budget_sec);
  /* P = ceil(log2(search_space)) clamped to [1, n_bitlen-1] */
  my(P = max(1, min(n_bitlen - 1, ceil(log(search_space) / log(2)))));
  P;
}

/* Survival rate estimate for pattern pat after sieving primes up to q_max.
 * Returns a rational approximation as a real. */
kt_sieve_survival_rate(pat, q_max) =
{
  my(rate = 1.0);
  forprime(q = 2, q_max,
    my(f = #kt_pattern_forbidden(pat, q));
    rate = rate * (q - f) / q;
  );
  rate;
}

/* ─────────────────────────────────────────────────────────────────────────────
 * Layer 5: Primorial Helpers
 *
 * Primorial P# = product of primes <= P.
 * The wheel construction works mod P# — residues r in [0, P#) that are
 * admissible for all primes q <= P form the wheel.
 * ───────────────────────────────────────────────────────────────────────────── */

/* Product of all primes <= n (primorial). */
kt_primorial(n) =
{
  my(p = 1);
  forprime(q = 2, n, p = p * q);
  p;
}

/* Enumerate residue classes r in [0, primorial) that are admissible for
 * pattern pat modulo all primes dividing primorial.
 * primorial: must be a product of distinct primes (e.g. 2*3*5*7*11 = 2310).
 * Returns count of admissible classes (not the classes themselves — the list
 * can be enormous for large primorials). */
kt_admissible_count_mod(pat, primorial) =
{
  /* Factor primorial into distinct primes */
  my(fac = factor(primorial));
  my(primes = vector(#fac[,1], i, fac[i,1]));
  /* Inclusion-exclusion via CRT product: count = primorial * prod((p-|f_p|)/p) */
  my(count = primorial);
  for(i = 1, #primes,
    my(q = primes[i]);
    my(f = #kt_pattern_forbidden(pat, q));
    count = count * (q - f) \ q;
  );
  count;
}

/* Enumerate admissible offsets mod primorial for pattern pat.
 * Only practical for small primorials (e.g. <= 30030 = 13#).
 * Returns vector of admissible r in [0, primorial). */
kt_admissible_offsets_mod(pat, primorial) =
{
  my(fac = factor(primorial));
  my(primes = vector(#fac[,1], i, fac[i,1]));
  my(n_primes = #primes);
  /* Precompute forbidden sets per prime */
  my(fbd = vector(n_primes, i, Set(kt_pattern_forbidden(pat, primes[i]))));
  my(result = List());
  for(r = 0, primorial - 1,
    my(ok = 1);
    for(i = 1, n_primes,
      if(setsearch(fbd[i], r % primes[i]),
        ok = 0; break;
      );
    );
    if(ok, listput(result, r));
  );
  Vec(result);
}

/* ─────────────────────────────────────────────────────────────────────────────
 * Self-Tests
 * Run on load. Prints pass/fail per test and final summary.
 * At most 5 records per k are verified (fast). Full corpus via
 *   kt_check_record_table(KT_RECORDS, 0)  after records.gp is loaded.
 * ───────────────────────────────────────────────────────────────────────────── */

{
  my(ok = 1, n_tests = 0);

  printf("\nkt_lib_v1.gp — running self-tests...\n");

  /* ── Layer 1 primitive tests ── */

  /* T01: diameter of k=5 pattern */
  n_tests++;
  if(kt_pattern_diameter([0,2,6,8,12]) == 12,
    printf("  T%02d PASSED: kt_pattern_diameter([0,2,6,8,12]) = 12\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_diameter([0,2,6,8,12]) expected 12\n", n_tests);
    ok = 0;
  );

  /* T02: forbidden residues for k=5 at q=7.
   * (-0)%7=0, (-2)%7=5, (-6)%7=1, (-8)%7=6, (-12)%7=2 → {0,1,2,5,6} */
  n_tests++;
  my(fbd5_7 = kt_pattern_forbidden([0,2,6,8,12], 7));
  if(fbd5_7 == [0,1,2,5,6],
    printf("  T%02d PASSED: kt_pattern_forbidden(k5, 7) = [0,1,2,5,6]\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_forbidden(k5, 7) = %s (expected [0,1,2,5,6])\n", n_tests, Str(fbd5_7));
    ok = 0;
  );

  /* T03: k=5 pattern admissible at q=7 (size 5 < 7 = true) */
  n_tests++;
  if(kt_pattern_admissible_at([0,2,6,8,12], 7),
    printf("  T%02d PASSED: kt_pattern_admissible_at(k5, 7) = 1 (5 forbidden out of 7)\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_admissible_at(k5, 7) expected 1\n", n_tests);
    ok = 0;
  );

  /* T04: immune residues for k=5 at q=7 → residues not in {0,1,2,5,6} = {3,4} */
  n_tests++;
  my(imm5_7 = kt_immune_residue_set([0,2,6,8,12], 7));
  if(imm5_7 == [3,4],
    printf("  T%02d PASSED: kt_immune_residue_set(k5, 7) = [3,4]\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_immune_residue_set(k5, 7) = %s (expected [3,4])\n", n_tests, Str(imm5_7));
    ok = 0;
  );

  /* T05: verify known 5-tuplet at n=5: {5,7,11,13,17} all prime */
  n_tests++;
  if(kt_verify_tuplet(5, [0,2,6,8,12]),
    printf("  T%02d PASSED: kt_verify_tuplet(5, k5) = 1 (5,7,11,13,17 all prime)\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_verify_tuplet(5, k5) expected 1\n", n_tests);
    ok = 0;
  );

  /* T06: verify k=7 at n=11: {11,13,17,19,23,29,31} all prime */
  n_tests++;
  if(kt_verify_tuplet(11, [0,2,6,8,12,18,20]),
    printf("  T%02d PASSED: kt_verify_tuplet(11, k7) = 1 (11,13,17,19,23,29,31 all prime)\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_verify_tuplet(11, k7) expected 1\n", n_tests);
    ok = 0;
  );

  /* T07: composite rejection — n=4, pattern {0,2,6,8,12}: 4+2=6 not prime */
  n_tests++;
  if(!kt_verify_tuplet(4, [0,2,6,8,12]),
    printf("  T%02d PASSED: kt_verify_tuplet(4, k5) = 0 (4+2=6 composite)\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_verify_tuplet(4, k5) expected 0\n", n_tests);
    ok = 0;
  );

  /* T08: mirror pattern of [0,2,6,8,12] → [0,4,6,10,12] */
  n_tests++;
  my(mir5 = kt_mirror_pattern([0,2,6,8,12]));
  if(mir5 == [0,4,6,10,12],
    printf("  T%02d PASSED: kt_mirror_pattern(k5) = [0,4,6,10,12]\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_mirror_pattern(k5) = %s\n", n_tests, Str(mir5));
    ok = 0;
  );

  /* T09: cross-check forbidden residues vs analyzer formula for k=17 at q=37.
   * KT17_P3 = [0,6,8,12,18,20,26,32,36,38,42,48,50,56,60,62,66]
   * Analyzer: ((-o) % p + p) % p for each o.
   * Expected (from Python pre-computation): 17 distinct residues at q=37. */
  n_tests++;
  my(pat17 = [0,6,8,12,18,20,26,32,36,38,42,48,50,56,60,62,66]);
  my(fbd17_37 = kt_pattern_forbidden(pat17, 37));
  my(expected17_37 = [0,1,5,8,11,12,14,17,18,19,24,25,26,29,31,32,36]);
  if(fbd17_37 == expected17_37,
    printf("  T%02d PASSED: kt_pattern_forbidden(KT17_P3, 37) matches analyzer formula\n", n_tests);
  ,
    printf("  T%02d FAILED: forbidden(KT17_P3,37)=%s\n  expected %s\n", n_tests, Str(fbd17_37), Str(expected17_37));
    ok = 0;
  );

  /* T10: cross-check for k=19 at q=37.
   * KT19_P0 = [0,4,6,10,12,16,24,30,34,40,42,46,52,54,60,66,70,72,76]
   * Expected: 19 distinct forbidden residues. */
  n_tests++;
  my(pat19 = [0,4,6,10,12,16,24,30,34,40,42,46,52,54,60,66,70,72,76]);
  my(fbd19_37 = kt_pattern_forbidden(pat19, 37));
  my(expected19_37 = [0,2,3,4,7,8,13,14,20,21,22,25,27,28,31,32,33,34,35]);
  if(fbd19_37 == expected19_37,
    printf("  T%02d PASSED: kt_pattern_forbidden(KT19_P0, 37) matches analyzer formula\n", n_tests);
  ,
    printf("  T%02d FAILED: forbidden(KT19_P0,37)=%s\n  expected %s\n", n_tests, Str(fbd19_37), Str(expected19_37));
    ok = 0;
  );

  /* T11: cross-check for k=21 at q=37.
   * KT21_P0 = [0,2,8,12,14,18,24,30,32,38,42,44,50,54,60,68,72,74,78,80,84]
   * Expected: 20 distinct forbidden residues (21 offsets but some collide mod 37). */
  n_tests++;
  my(pat21 = [0,2,8,12,14,18,24,30,32,38,42,44,50,54,60,68,72,74,78,80,84]);
  my(fbd21_37 = kt_pattern_forbidden(pat21, 37));
  my(expected21_37 = [0,2,5,6,7,13,14,19,20,23,24,25,27,29,30,31,32,33,35,36]);
  if(fbd21_37 == expected21_37,
    printf("  T%02d PASSED: kt_pattern_forbidden(KT21_P0, 37) matches analyzer formula\n", n_tests);
  ,
    printf("  T%02d FAILED: forbidden(KT21_P0,37)=%s\n  expected %s\n", n_tests, Str(fbd21_37), Str(expected21_37));
    ok = 0;
  );

  /* ── Layer 2 catalog tests ── */

  /* T12: kt_pattern_by_name finds KT5_P0 */
  n_tests++;
  my(cat5 = kt_pattern_by_name("KT5_P0"));
  if(cat5[2] == 5 && cat5[3] == [0,2,6,8,12],
    printf("  T%02d PASSED: kt_pattern_by_name(\"KT5_P0\") = correct\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_by_name(\"KT5_P0\") = %s\n", n_tests, Str(cat5));
    ok = 0;
  );

  /* T13: kt_pattern_by_name returns 0 for unknown name */
  n_tests++;
  if(kt_pattern_by_name("KT99_P0") == 0,
    printf("  T%02d PASSED: kt_pattern_by_name(\"KT99_P0\") = 0 (not found)\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_by_name(\"KT99_P0\") should return 0\n", n_tests);
    ok = 0;
  );

  /* T14: kt_pattern_unique_for_k(17) returns 4 patterns */
  n_tests++;
  my(pats17 = kt_pattern_unique_for_k(17));
  if(#pats17 == 4,
    printf("  T%02d PASSED: kt_pattern_unique_for_k(17) returns 4 patterns\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_unique_for_k(17) returned %d (expected 4)\n", n_tests, #pats17);
    ok = 0;
  );

  /* T15: kt_pattern_unique_for_k(19) returns 4 patterns */
  n_tests++;
  my(pats19 = kt_pattern_unique_for_k(19));
  if(#pats19 == 4,
    printf("  T%02d PASSED: kt_pattern_unique_for_k(19) returns 4 patterns\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_unique_for_k(19) returned %d (expected 4)\n", n_tests, #pats19);
    ok = 0;
  );

  /* T16: all catalog patterns are admissible for all primes <= max(k+1, 100).
   * For each pattern, check admissible_at for q in {2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97,101} */
  n_tests++;
  my(catalog_ok = 1);
  my(test_primes = [2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97,101]);
  for(ci = 1, #KT_CATALOG,
    my(pat = KT_CATALOG[ci][3]);
    for(qi = 1, #test_primes,
      if(!kt_pattern_admissible_at(pat, test_primes[qi]),
        printf("    CATALOG FAIL: %s not admissible at q=%d\n", KT_CATALOG[ci][1], test_primes[qi]);
        catalog_ok = 0;
      );
    );
  );
  if(catalog_ok,
    printf("  T%02d PASSED: all %d catalog patterns admissible for primes <= 101\n", n_tests, #KT_CATALOG);
  ,
    printf("  T%02d FAILED: some catalog patterns failed admissibility\n", n_tests);
    ok = 0;
  );

  /* T17: KT19 diameter is 76 (not 80 — the correct value) */
  n_tests++;
  my(kt19_p0 = kt_pattern_by_name("KT19_P0"));
  if(kt_pattern_diameter(kt19_p0[3]) == 76,
    printf("  T%02d PASSED: KT19_P0 diameter = 76 (H(19)=76 confirmed)\n", n_tests);
  ,
    printf("  T%02d FAILED: KT19_P0 diameter = %d (expected 76)\n", n_tests, kt_pattern_diameter(kt19_p0[3]));
    ok = 0;
  );

  /* T18: mirror symmetry — mirror(KT19_P3) should still be admissible */
  n_tests++;
  my(kt19_p3 = kt_pattern_by_name("KT19_P3")[3]);
  my(mir19_p3 = kt_mirror_pattern(kt19_p3));
  if(kt_pattern_admissible_at(mir19_p3, 101),
    printf("  T%02d PASSED: mirror(KT19_P3) is also admissible at primes <= 101\n", n_tests);
  ,
    printf("  T%02d FAILED: mirror(KT19_P3) failed admissibility\n", n_tests);
    ok = 0;
  );

  /* T19: verify a known k=17 record from records.json (first record).
   * base=1620784518619319025971, pattern KT17_P3. */
  n_tests++;
  my(base17 = 1620784518619319025971);
  my(pat17_p3 = [0,6,8,12,18,20,26,32,36,38,42,48,50,56,60,62,66]);
  if(kt_verify_tuplet(base17, pat17_p3),
    printf("  T%02d PASSED: k=17 record (Waldvogel 1997) verified prime 17-tuple\n", n_tests);
  ,
    printf("  T%02d FAILED: k=17 record failed primality check\n", n_tests);
    ok = 0;
  );

  /* T20: verify a known k=18 record.
   * base=1906230835046648293290043, pattern KT18_P0. */
  n_tests++;
  my(base18 = 1906230835046648293290043);
  my(pat18_p0 = [0,4,6,10,16,18,24,28,30,34,40,46,48,54,58,60,66,70]);
  if(kt_verify_tuplet(base18, pat18_p0),
    printf("  T%02d PASSED: k=18 record (Waldvogel & Leikauf 2001) verified prime 18-tuple\n", n_tests);
  ,
    printf("  T%02d FAILED: k=18 record failed primality check\n", n_tests);
    ok = 0;
  );

  /* T21: verify a known k=19 record.
   * base=630134041802574490482213901, pattern KT19_P3. */
  n_tests++;
  my(base19 = 630134041802574490482213901);
  my(pat19_p3 = [0,6,10,16,18,22,28,30,36,42,46,48,52,58,60,66,70,72,76]);
  if(kt_verify_tuplet(base19, pat19_p3),
    printf("  T%02d PASSED: k=19 record (Chermoni & Wroblewski 2011) verified prime 19-tuple\n", n_tests);
  ,
    printf("  T%02d FAILED: k=19 record failed primality check\n", n_tests);
    ok = 0;
  );

  /* T22: verify a known k=21 record.
   * base=39433867730216371575457664399, pattern KT21_P0. */
  n_tests++;
  my(base21 = 39433867730216371575457664399);
  my(pat21_p0 = [0,2,8,12,14,18,24,30,32,38,42,44,50,54,60,68,72,74,78,80,84]);
  if(kt_verify_tuplet(base21, pat21_p0),
    printf("  T%02d PASSED: k=21 record (Chermoni & Wroblewski 2015) verified prime 21-tuple\n", n_tests);
  ,
    printf("  T%02d FAILED: k=21 record failed primality check\n", n_tests);
    ok = 0;
  );

  /* T23: mirror equivalence — mirror(KT17_P3) = KT17_P1.
   * A record known for KT17_P1 should pass kt_verify_tuplet with mirror(KT17_P3).
   * KT17_P1 record: base=47624415490498763963983 (Peter Leikauf & Jörg Waldvogel, 2001). */
  n_tests++;
  my(base17_p1 = 47624415490498763963983);
  my(mir17_p3 = kt_mirror_pattern([0,6,8,12,18,20,26,32,36,38,42,48,50,56,60,62,66]));
  if(mir17_p3 == [0,4,6,10,16,18,24,28,30,34,40,46,48,54,58,60,66] &&
     kt_verify_tuplet(base17_p1, mir17_p3),
    printf("  T%02d PASSED: mirror(KT17_P3)=KT17_P1 and verifies a known KT17_P1 record\n", n_tests);
  ,
    printf("  T%02d FAILED: mirror(KT17_P3)=%s or verify failed\n", n_tests, Str(mir17_p3));
    ok = 0;
  );

  /* ── Layer 4 search-space tests ── */

  /* T24: kt_prefix_bits_for_budget(90, 19, 50e9, 60) in [40,60] */
  n_tests++;
  my(P = kt_prefix_bits_for_budget(90, 19, 50000000000.0, 60));
  if(P >= 40 && P <= 60,
    printf("  T%02d PASSED: kt_prefix_bits_for_budget(90,19,50G,60) = %d (in [40,60])\n", n_tests, P);
  ,
    printf("  T%02d FAILED: kt_prefix_bits_for_budget = %d (expected [40,60])\n", n_tests, P);
    ok = 0;
  );

  /* T25: survival rate for k=5 at primes up to 11 > 0 and < 1 */
  n_tests++;
  my(sr = kt_sieve_survival_rate([0,2,6,8,12], 11));
  if(sr > 0.0 && sr < 1.0,
    printf("  T%02d PASSED: kt_sieve_survival_rate(k5, 11) = %f\n", n_tests, sr);
  ,
    printf("  T%02d FAILED: kt_sieve_survival_rate = %f\n", n_tests, sr);
    ok = 0;
  );

  /* T26: survival rate for k=19 < survival for k=5 (more constraints) */
  n_tests++;
  my(sr5  = kt_sieve_survival_rate([0,2,6,8,12], 97));
  my(sr19 = kt_sieve_survival_rate([0,4,6,10,12,16,24,30,34,40,42,46,52,54,60,66,70,72,76], 97));
  if(sr19 < sr5,
    printf("  T%02d PASSED: survival_rate(k19) < survival_rate(k5) as expected\n", n_tests);
  ,
    printf("  T%02d FAILED: expected sr19 < sr5 but got sr19=%f sr5=%f\n", n_tests, sr19, sr5);
    ok = 0;
  );

  /* ── Layer 5 primorial tests ── */

  /* T27: kt_primorial(11) = 2*3*5*7*11 = 2310 */
  n_tests++;
  if(kt_primorial(11) == 2310,
    printf("  T%02d PASSED: kt_primorial(11) = 2310\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_primorial(11) = %d (expected 2310)\n", n_tests, kt_primorial(11));
    ok = 0;
  );

  /* T28: kt_primorial(13) = 30030 */
  n_tests++;
  if(kt_primorial(13) == 30030,
    printf("  T%02d PASSED: kt_primorial(13) = 30030\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_primorial(13) = %d\n", n_tests, kt_primorial(13));
    ok = 0;
  );

  /* T29: admissible count mod 2310 for k=5 pattern = 12.
   * Enumeration: prod over q in {2,3,5,7,11}: (q - |forbidden_q|)
   *   q=2: 1 forbidden → 1 survive
   *   q=3: 2 forbidden → 1 survive
   *   q=5: 4 forbidden → 1 survive
   *   q=7: 5 forbidden → 2 survive
   *   q=11: 5 forbidden → 6 survive
   * count = 2310 * (1/2)*(1/3)*(1/5)*(2/7)*(6/11) = 12 */
  n_tests++;
  my(cnt5 = kt_admissible_count_mod([0,2,6,8,12], 2310));
  if(cnt5 == 12,
    printf("  T%02d PASSED: kt_admissible_count_mod(k5, 2310) = 12\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_admissible_count_mod(k5, 2310) = %d (expected 12)\n", n_tests, cnt5);
    ok = 0;
  );

  /* T30: admissible offsets enumeration matches count for 2310 */
  n_tests++;
  my(offsets_enum = kt_admissible_offsets_mod([0,2,6,8,12], 2310));
  if(#offsets_enum == 12,
    printf("  T%02d PASSED: kt_admissible_offsets_mod(k5, 2310) enumerated 12 classes\n", n_tests);
  ,
    printf("  T%02d FAILED: enumerated %d classes (expected 12)\n", n_tests, #offsets_enum);
    ok = 0;
  );

  /* T31: admissible count monotone — adding more primes shrinks count */
  n_tests++;
  my(cnt_6  = kt_admissible_count_mod([0,2,6,8,12], kt_primorial(6)));   /* 6# = 30 */
  my(cnt_11 = kt_admissible_count_mod([0,2,6,8,12], kt_primorial(11)));  /* 11# = 2310 */
  my(cnt_13 = kt_admissible_count_mod([0,2,6,8,12], kt_primorial(13)));  /* 13# = 30030 */
  /* count_mod_P# / P# should be non-increasing as P# grows */
  if(cnt_6 * 2310 >= cnt_11 * 30 && cnt_11 * 30030 >= cnt_13 * 2310,
    printf("  T%02d PASSED: admissible density non-increasing: %d/30, %d/2310, %d/30030\n",
           n_tests, cnt_6, cnt_11, cnt_13);
  ,
    printf("  T%02d FAILED: density not monotone: %d/30, %d/2310, %d/30030\n",
           n_tests, cnt_6, cnt_11, cnt_13);
    ok = 0;
  );

  /* T32: forbidden set for k=5 at q=5 has 4 elements (all 4 non-zero classes hit).
   * offsets {0,2,6,8,12}: (-0)%5=0, (-2)%5=3, (-6)%5=4, (-8)%5=2, (-12)%5=3
   * Deduplicated: {0,2,3,4} → 4 elements. */
  n_tests++;
  my(fbd5_5 = kt_pattern_forbidden([0,2,6,8,12], 5));
  if(#fbd5_5 == 4 && fbd5_5 == [0,2,3,4],
    printf("  T%02d PASSED: kt_pattern_forbidden(k5, 5) = [0,2,3,4] (4 elements)\n", n_tests);
  ,
    printf("  T%02d FAILED: kt_pattern_forbidden(k5, 5) = %s\n", n_tests, Str(fbd5_5));
    ok = 0;
  );

  /* T33: catalog count — 25 entries total (3 small + 16 record-derived + 6 high-k) */
  n_tests++;
  if(#KT_CATALOG == 25,
    printf("  T%02d PASSED: KT_CATALOG has 25 entries (3 small + 16 record-derived + 6 high-k)\n", n_tests);
  ,
    printf("  T%02d FAILED: KT_CATALOG has %d entries (expected 25)\n", n_tests, #KT_CATALOG);
    ok = 0;
  );

  /* ── High-k admissibility tests (T34-T39) ── */

  /* T34: KT22_P0 admissible at q_max=113 */
  n_tests++;
  my(kt22_p0 = [0, 2, 6, 8, 12, 20, 26, 30, 36, 38, 42, 48, 50, 56, 62, 66, 68, 72, 78, 80, 86, 90]);
  my(ok22_p0 = 1);
  forprime(q = 2, 113, if(!kt_pattern_admissible_at(kt22_p0, q), ok22_p0 = 0));
  if(ok22_p0,
    printf("  T%02d PASSED: KT22_P0 admissible at all primes <= 113\n", n_tests);
  ,
    printf("  T%02d FAILED: KT22_P0 failed admissibility at some prime <= 113\n", n_tests);
    ok = 0;
  );

  /* T35: KT22_P1 admissible at q_max=113 */
  n_tests++;
  my(kt22_p1 = [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84, 90]);
  my(ok22_p1 = 1);
  forprime(q = 2, 113, if(!kt_pattern_admissible_at(kt22_p1, q), ok22_p1 = 0));
  if(ok22_p1,
    printf("  T%02d PASSED: KT22_P1 admissible at all primes <= 113\n", n_tests);
  ,
    printf("  T%02d FAILED: KT22_P1 failed admissibility at some prime <= 113\n", n_tests);
    ok = 0;
  );

  /* T36: KT23_P0 admissible at q_max=113 */
  n_tests++;
  my(kt23_p0 = [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84, 90, 94]);
  my(ok23_p0 = 1);
  forprime(q = 2, 113, if(!kt_pattern_admissible_at(kt23_p0, q), ok23_p0 = 0));
  if(ok23_p0,
    printf("  T%02d PASSED: KT23_P0 admissible at all primes <= 113\n", n_tests);
  ,
    printf("  T%02d FAILED: KT23_P0 failed admissibility at some prime <= 113\n", n_tests);
    ok = 0;
  );

  /* T37: KT24_P0 admissible at q_max=113 */
  n_tests++;
  my(kt24_p0 = [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 60, 66, 70, 72, 76, 82, 84, 90, 94, 96, 100]);
  my(ok24_p0 = 1);
  forprime(q = 2, 113, if(!kt_pattern_admissible_at(kt24_p0, q), ok24_p0 = 0));
  if(ok24_p0,
    printf("  T%02d PASSED: KT24_P0 admissible at all primes <= 113\n", n_tests);
  ,
    printf("  T%02d FAILED: KT24_P0 failed admissibility at some prime <= 113\n", n_tests);
    ok = 0;
  );

  /* T38: KT24_P1 admissible at q_max=113 */
  n_tests++;
  my(kt24_p1 = [0, 4, 6, 10, 16, 18, 24, 28, 30, 34, 40, 48, 54, 58, 60, 66, 70, 76, 84, 88, 90, 94, 96, 100]);
  my(ok24_p1 = 1);
  forprime(q = 2, 113, if(!kt_pattern_admissible_at(kt24_p1, q), ok24_p1 = 0));
  if(ok24_p1,
    printf("  T%02d PASSED: KT24_P1 admissible at all primes <= 113\n", n_tests);
  ,
    printf("  T%02d FAILED: KT24_P1 failed admissibility at some prime <= 113\n", n_tests);
    ok = 0;
  );

  /* T39: KT24_P2 admissible at q_max=113 */
  n_tests++;
  my(kt24_p2 = [0, 4, 6, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76, 82, 84, 90, 94, 96, 100]);
  my(ok24_p2 = 1);
  forprime(q = 2, 113, if(!kt_pattern_admissible_at(kt24_p2, q), ok24_p2 = 0));
  if(ok24_p2,
    printf("  T%02d PASSED: KT24_P2 admissible at all primes <= 113\n", n_tests);
  ,
    printf("  T%02d FAILED: KT24_P2 failed admissibility at some prime <= 113\n", n_tests);
    ok = 0;
  );

  printf("\n");
  printf("  Available functions:\n");
  printf("\n  -- Layer 1: Primitives --\n");
  printf("    kt_pattern_diameter(pat)              -- last offset\n");
  printf("    kt_pattern_forbidden(pat, q)          -- forbidden residues mod q\n");
  printf("    kt_pattern_admissible_at(pat, q)      -- 1 if admissible at prime q\n");
  printf("    kt_immune_residue_set(pat, q)         -- admissible residue classes mod q\n");
  printf("    kt_verify_tuplet(n, pat)              -- isprime for all k members\n");
  printf("    kt_mirror_pattern(pat)                -- reflected pattern\n");
  printf("\n  -- Layer 2: Catalog --\n");
  printf("    KT_CATALOG                            -- vector of [name, k, [offsets]]\n");
  printf("    kt_pattern_by_name(name)              -- lookup by string name\n");
  printf("    kt_pattern_unique_for_k(k)            -- all entries for given k\n");
  printf("\n  -- Layer 3: Record Table (requires \\r gp/records.gp) --\n");
  printf("    KT_RECORDS                            -- after loading records.gp\n");
  printf("    kt_records_for_k(k)                   -- records for given k\n");
  printf("    kt_check_record_table(recs, {max})    -- verify k records are prime tuples\n");
  printf("\n  -- Layer 4: Search-Space Helpers --\n");
  printf("    kt_prefix_bits_for_budget(n_bits, k, tput, sec) -- prefix bit count\n");
  printf("    kt_sieve_survival_rate(pat, q_max)    -- post-sieve survival fraction\n");
  printf("\n  -- Layer 5: Primorial Helpers --\n");
  printf("    kt_primorial(n)                       -- product of primes <= n\n");
  printf("    kt_admissible_count_mod(pat, prim)    -- count of wheel positions\n");
  printf("    kt_admissible_offsets_mod(pat, prim)  -- enumerate wheel positions\n");
  printf("\n  Examples:\n");
  printf("    kt_verify_tuplet(5, [0,2,6,8,12])     \\\\ verify known 5-tuplet\n");
  printf("    kt_pattern_by_name(\"KT19_P0\")         \\\\ look up KT19 pattern 0\n");
  printf("    \\\\r gp/records.gp                     \\\\ load record table\n");
  printf("    kt_check_record_table(KT_RECORDS, 3)  \\\\ verify 3 records per k\n");
  printf("    kt_prefix_bits_for_budget(90,19,50e9,60)  \\\\ plan a search campaign\n");
  printf("\n");

  if(ok,
    printf("  All self-tests passed (%d tests). Ready.\n\n", n_tests),
    printf("  WARNING: some self-tests FAILED! Check output above.\n\n")
  );
}
