/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 * Phase 9 T1.1: emit one line per catalog pattern with exact A(37#) and the
 * predicted exhaustive bit-reach at 1-GPU-day and 32-GPU-day budgets.
 *
 * Usage:  mkdir -p bench
 *         gp -q -f tools/dump_admissible_at_37hash.gp > bench/admissible_at_37hash.tsv
 *
 * The bench/ directory is generated output and is intentionally not shipped in
 * the public tree.
 *
 * Each emitted line:
 *   pattern <TAB> k <TAB> diameter <TAB> A_37hash <TAB> B_32gpu_days <TAB> B_1gpu_day
 */

\r gp/kt_lib_v1.gp

{
  /* 37# = 2*3*5*7*11*13*17*19*23*29*31*37 = 7420738134810 */
  prim37 = kt_primorial(37);

  /* Useful-candidate budgets per the campaign descent brief §2:
   *   32-GPU-day budget = 1.22e16 useful cands  (full descent campaign)
   *   1-GPU-day budget  = 3.81e14 useful cands  (single-cell unit)
   *
   * Exhaust-depth identity:  raw_integers_covered = 2^B
   *                          useful_cands         = 2^B * A_P# / P#
   * Solving for B:           2^B = budget * P# / A_P#
   *                          B   = log2(budget * P#) - log2(A_P#)
   */
  budget_32d = 1.22e16;
  budget_1d  = 3.81e14;

  /* Iterate the catalog and emit one line per KT16+ pattern. */
  for(i = 1, #KT_CATALOG,
    entry = KT_CATALOG[i];
    name  = entry[1];
    k     = entry[2];
    pat   = entry[3];
    if(k < 16, next());
    diameter = pat[#pat] - pat[1];
    a37 = kt_admissible_count_mod(pat, prim37);
    /* Use floating arithmetic for log2 (gp default precision is high enough). */
    raw_32d = budget_32d * prim37 / a37;
    raw_1d  = budget_1d  * prim37 / a37;
    b32 = log(raw_32d) / log(2.0);
    b1  = log(raw_1d)  / log(2.0);
    printf("%s\t%d\t%d\t%d\t%.4f\t%.4f\n",
           name, k, diameter, a37, b32, b1);
  );
}
\q
