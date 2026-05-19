/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * dump_filter_mask_hashes.gp - canonical FNV-1a-64 hashes for the Phase 3c
 * filter-mask arrays (L2, ext-L2, line-sieve) for fixed (pattern, prime-list)
 * pairs. Output is pasted into src/cuda/kt_wheel.c as the
 * kt_canonical_filter_hashes[] table. Runtime asserts agreement.
 *
 * Mask construction mirrors kt_forbidden_mask_u64 / _u128 / _packed in
 * src/cuda/kt_wheel.c. FNV-1a-64 byte order matches kt_wheel_fnv1a64_u64_array
 * (each u64 emitted as 8 little-endian bytes).
 *
 * Filter prime bands (Phase 3c, k-tuplet baseline; 37# wheel covers ≤37):
 *   L2:     {41, 43, 47, 53, 59, 61}      (6 primes, q < 64)
 *   ext-L2: {67, 71, 73, 79, 83, 89, 97}  (7 primes, q < 128)
 *   line:   primes 101..863               (125 primes, packed bitvec, 14 u64s)
 */

L2_PRIMES     = [41, 43, 47, 53, 59, 61];
EXT_L2_PRIMES = [67, 71, 73, 79, 83, 89, 97];
LINE_KILL_WORDS = 14;

/* Build line primes as primes(p) with 101 <= p <= 863. */
build_line_primes() =
{
  my(out = List());
  forprime(p = 101, 863, listput(out, p));
  Vec(out);
}

LINE_PRIMES = build_line_primes();

PATTERNS = [ \
  ["KT19_P0", [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76]], \
  ["KT22_P0", [0, 2, 6, 8, 12, 20, 26, 30, 36, 38, 42, 48, 50, 56, 62, 66, 68, 72, 78, 80, 86, 90]] ];

pat_lookup(name) =
{
  for(i = 1, #PATTERNS, if(PATTERNS[i][1] == name, return(PATTERNS[i][2])));
  error("unknown pattern: ", name);
}

mask_u64(pat, q) =
{
  my(m = 0);
  for(i = 1, #pat,
    my(r = (q - (pat[i] % q)) % q);
    m = bitor(m, 1 << r);
  );
  m;
}

mask_u128(pat, q) =
{
  my(lo = 0, hi = 0);
  for(i = 1, #pat,
    my(r = (q - (pat[i] % q)) % q);
    if(r < 64, lo = bitor(lo, 1 << r), hi = bitor(hi, 1 << (r - 64)));
  );
  [lo, hi];
}

mask_packed(pat, q, words) =
{
  my(out = vector(words, i, 0));
  for(i = 1, #pat,
    my(r = (q - (pat[i] % q)) % q);
    my(w = (r >> 6) + 1);
    my(b = bitand(r, 63));
    out[w] = bitor(out[w], 1 << b);
  );
  out;
}

fnv1a64_u64_array(arr) =
{
  my(h = 0xcbf29ce484222325);
  my(prime = 0x100000001b3);
  my(mask64 = 1<<64);
  for(i = 1, #arr,
    my(v = arr[i]);
    for(b = 0, 7,
      my(byte = bitand(v >> (8*b), 0xff));
      h = bitxor(h, byte);
      h = (h * prime) % mask64;
    );
  );
  h;
}

popcount_u64(v) =
{
  my(c = 0);
  while(v > 0, if(bitand(v, 1), c = c + 1); v = v >> 1);
  c;
}

emit_one(name) =
{
  my(pat = pat_lookup(name));

  /* L2: 6 u64 masks */
  my(l2 = vector(#L2_PRIMES, i, mask_u64(pat, L2_PRIMES[i])));
  my(l2_hash = fnv1a64_u64_array(l2));

  /* ext-L2: 14 u64s (lo, hi for each prime) */
  my(extl2 = List());
  for(i = 1, #EXT_L2_PRIMES,
    my(p = mask_u128(pat, EXT_L2_PRIMES[i]));
    listput(extl2, p[1]);
    listput(extl2, p[2]);
  );
  extl2 = Vec(extl2);
  my(extl2_hash = fnv1a64_u64_array(extl2));

  /* line-sieve: 125 * 14 u64s, flat */
  my(line = List());
  for(i = 1, #LINE_PRIMES,
    my(packed = mask_packed(pat, LINE_PRIMES[i], LINE_KILL_WORDS));
    for(w = 1, LINE_KILL_WORDS, listput(line, packed[w]));
  );
  line = Vec(line);
  my(line_hash = fnv1a64_u64_array(line));

  printf("# %s\n", name);
  printf("#   L2 popcounts: ");
  for(i = 1, #l2, printf("%d ", popcount_u64(l2[i])));
  printf("\n");
  printf("#   ext-L2 popcount sum: %d\n", sum(i = 1, #extl2, popcount_u64(extl2[i])));
  printf("#   line popcount sum:   %d\n", sum(i = 1, #line,  popcount_u64(line[i])));
  printf("#   l2_hash=0x%016x  ext_l2_hash=0x%016x  line_hash=0x%016x\n",
         l2_hash, extl2_hash, line_hash);
  printf("    { \"%s\", 0x%016xULL, 0x%016xULL, 0x%016xULL },\n",
         name, l2_hash, extl2_hash, line_hash);
}

print("# Canonical filter-mask hashes - paste into src/cuda/kt_wheel.c");
print("# pattern | l2_hash | ext_l2_hash | line_hash");
printf("# (LINE_PRIMES count: %d, expected 125)\n", #LINE_PRIMES);
print("");

emit_one("KT19_P0");
emit_one("KT22_P0");

print("");
quit;
