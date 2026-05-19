/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/* Dump KT19_P0 admissible offsets at 37# for parity audit.
 * Uses the same self-contained CRT wheel join as tools/dump_wheel_canonical_hash.gp.
 * Output: tests/wheel_parity_KT19_P0_37.txt
 *   line 1: # primorial=<dec> n_admissible=<dec>
 *   line 2..: <offset_decimal>
 * One offset per line, ascending. */

KT19_P0 = [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76];
PRIMES_37 = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37];

pat_immune(pat, q) =
{
  my(forb = vector(#pat, i, lift(Mod(-pat[i], q))));
  my(forb_set = Set(forb));
  my(out = List());
  for(r = 0, q-1, if(!setsearch(forb_set, r), listput(out, r)));
  Vec(out);
}

wheel_extend_one(wheel, m, q, immune) =
{
  my(out = List());
  for(i = 1, #wheel,
    my(w = wheel[i]);
    for(j = 1, #immune,
      my(r = immune[j]);
      my(off = chinese(Mod(w, m), Mod(r, q)));
      listput(out, lift(off));
    );
  );
  Vec(Set(Vec(out)));
}

wheel_crt_join(pat, prime_list) =
{
  my(m = 1);
  my(wheel = [0]);
  for(i = 1, #prime_list,
    my(q = prime_list[i]);
    my(immune = pat_immune(pat, q));
    if(#immune == 0, return(vector(0)));
    wheel = wheel_extend_one(wheel, m, q, immune);
    m = m * q;
  );
  wheel;
}

prim = prod(i = 1, #PRIMES_37, PRIMES_37[i]);
wheel = wheel_crt_join(KT19_P0, PRIMES_37);
n = #wheel;

print(Strprintf("# primorial=%d n_admissible=%d", prim, n));
for(i = 1, n, print(wheel[i]));

quit;
