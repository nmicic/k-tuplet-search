/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * dump_wheel_canonical_hash.gp - emit canonical FNV-1a-64 hashes of the
 * CRT-built admissibility wheels for a fixed set of (pattern, prime_list)
 * pairs. The output is pasted into src/cuda/kt_wheel.c as the
 * kt_canonical_wheel_hashes[] table. Runtime asserts the C side matches.
 *
 * Self-contained: re-implements forbidden / immune / wheel_extend /
 * wheel_crt_join inline for parity with the C implementation.
 *
 * FNV-1a-64 byte order MUST match kt_wheel.c:kt_wheel_fnv1a64_u64_array
 * (each u64 emitted as 8 little-endian bytes).
 */

pat_forbidden(pat, q) =
{
  my(s = List());
  for(i = 1, #pat, listput(s, ((q - (pat[i] % q)) % q)));
  Vec(Set(Vec(s)));
}

pat_immune(pat, q) =
{
  my(fbd = Set(pat_forbidden(pat, q)));
  my(out = List());
  for(r = 0, q-1, if(!setsearch(fbd, r), listput(out, r)));
  Vec(out);
}

wheel_extend_one(wheel, m, q, immune) =
{
  my(out = List());
  for(i = 1, #wheel,
    my(a = wheel[i]);
    for(j = 1, #immune,
      my(b = immune[j]);
      my(x = lift(chinese(Mod(a, m), Mod(b, q))));
      listput(out, x);
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

PATTERNS = [ \
  ["KT5_P0",  [0, 2, 6, 8, 12]], \
  ["KT9_P0",  [0, 2, 6, 8, 12, 18, 20, 26, 30]], \
  ["KT17_P0", [0, 2, 6, 12, 14, 20, 24, 26, 30, 36, 42, 44, 50, 54, 56, 62, 66]], \
  ["KT19_P0", [0, 4, 6, 10, 12, 16, 24, 30, 34, 40, 42, 46, 52, 54, 60, 66, 70, 72, 76]], \
  ["KT22_P0", [0, 2, 6, 8, 12, 20, 26, 30, 36, 38, 42, 48, 50, 56, 62, 66, 68, 72, 78, 80, 86, 90]] ];

pat_lookup(name) =
{
  for(i = 1, #PATTERNS, if(PATTERNS[i][1] == name, return(PATTERNS[i][2])));
  error("unknown pattern: ", name);
}

TESTS = [ \
  ["KT5_P0",  [2,3,5,7,11]], \
  ["KT9_P0",  [2,3,5,7,11]], \
  ["KT17_P0", [2,3,5,7,11,13]], \
  ["KT19_P0", [2,3,5,7,11,13]], \
  ["KT19_P0", [2,3,5,7,11,13,17,19,23,29,31,37]], \
  ["KT22_P0", [2,3,5,7,11,13,17,19,23,29,31,37]] ];

print("# Canonical wheel hashes - paste into src/cuda/kt_wheel.c");
print("# pattern_name | n_primes | primes | n_admissible | fnv1a64_hash_hex");
print("");

emit_one(name, primes) =
{
  my(pat = pat_lookup(name));
  my(wheel = wheel_crt_join(pat, primes));
  my(n = #wheel);
  my(prod = prod(i = 1, #primes, primes[i]));
  my(arr = vector(n, i, wheel[i]));
  my(h = fnv1a64_u64_array(arr));
  printf("# %s primes=%s primorial=%d n_admissible=%d hash=0x%016x\n", name, Str(primes), prod, n, h);
  my(plit = "{");
  for(i = 1, #primes, plit = Str(plit, primes[i], if(i < #primes, ",", "")));
  plit = Str(plit, "}");
  printf("    { \"%s\", %d, %s, %d, 0x%016xULL },\n", name, #primes, plit, n, h);
}

emit_one(TESTS[1][1], TESTS[1][2]);
emit_one(TESTS[2][1], TESTS[2][2]);
emit_one(TESTS[3][1], TESTS[3][2]);
emit_one(TESTS[4][1], TESTS[4][2]);
emit_one(TESTS[5][1], TESTS[5][2]);
emit_one(TESTS[6][1], TESTS[6][2]);

print("");
quit;
