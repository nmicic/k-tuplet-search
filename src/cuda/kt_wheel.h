/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_wheel.h - admissibility-wheel CRT-join builder (Phase 3b).
 *
 * Pure-C public surface (no nvcc-only types). Parity is checked against the
 * retained GP helpers and generated wheel fixtures.
 *
 * Per the corrected forbidden-residue formula
 *   (memory: feedback_kt_arithmetic_corrections.md):
 *
 *     F_q = { (q - (b_i mod q)) mod q : i in 0..k-1 }   (deduped)
 *
 *   Pattern admissible at q iff |F_q| < q.
 *
 * SIZING NOTE
 *   The brief estimated wheel sizes around 2560 admissible offsets at 37#.
 *   The actual GP-canonical counts measured by tools/dump_wheel_canonical_hash.gp
 *   are ~266k for KT19_P0 and ~20k for KT22_P0 (recorded in the canonical
 *   table at the bottom of kt_wheel.c). Storage is therefore heap-allocated
 *   rather than fitting in a single __constant__ block; the runtime caps
 *   the wheel at KT_WHEEL_MAX_ADMISSIBLE = 1 << 20 entries (8 MiB worst-case)
 *   and uploads to GPU global memory (not __constant__) for the binary search.
 */

#ifndef KT_WHEEL_H
#define KT_WHEEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Hard ceiling on wheel size. Worst case observed: ~266k for KT19_P0 at 37#. */
#define KT_WHEEL_MAX_ADMISSIBLE (1 << 20)
#define KT_WHEEL_EXPR_MAX_PRIMES 16
#define KT_WHEEL_EXPR_CANON_LEN  128

/* CRT-built wheel for a pattern over a list of distinct primes.
 * `offsets` is malloc()d by kt_wheel_crt_join and must be released by
 * kt_wheel_free. Sorted ascending, deduped. */
typedef struct {
    uint64_t  primorial;     /* product of prime_list */
    int       n_admissible;  /* size of offsets[]; <= KT_WHEEL_MAX_ADMISSIBLE */
    uint64_t *offsets;       /* heap-allocated, sorted ascending */
    uint64_t  fnv1a64_hash;  /* FNV-1a-64 over offsets */
} kt_wheel_t;

/* Build the admissible-offset wheel for pattern via CRT-join.
 *   pat:        pattern offsets (b_0=0, ascending)
 *   k:          length of pat
 *   prime_list: distinct primes (any order; product must fit in u64)
 *   n_primes:   length of prime_list
 *   out:        result (caller-allocated struct; out->offsets is malloc'd
 *               on success and must be released via kt_wheel_free).
 * Returns 0 on success,
 *        -1 if the wheel exceeds KT_WHEEL_MAX_ADMISSIBLE,
 *        -2 if the pattern is inadmissible at any q in prime_list,
 *        -3 if the primorial overflows u64,
 *        -4 on malloc failure. */
int  kt_wheel_crt_join(const uint32_t *pat, int k,
                       const uint32_t *prime_list, int n_primes,
                       kt_wheel_t *out);

/* Phase 9 T2.1: streaming CRT-join wheel construction for high-primorial
 * lifts (41#, 43#, 47#).
 *
 * Computes the same admissible-offset wheel as kt_wheel_crt_join() but
 * sizes the host buffers dynamically per step rather than allocating two
 * KT_WHEEL_MAX_ADMISSIBLE-sized scratch buffers up front.
 *
 *   max_bytes:        abort if predicted final or peak intermediate
 *                     allocation exceeds this many bytes (caller passes
 *                     the safety cap; T2.1 brief mandates 4 GiB).
 *   peak_bytes_out:   on success, populated with the peak host-allocation
 *                     in bytes (cur+next buffer sum at the largest step).
 *                     Caller may pass NULL.
 *
 * Returns 0 on success,
 *        -1 if predicted size exceeds max_bytes (size estimate written to
 *           *peak_bytes_out for the operator),
 *        -2 if the pattern is inadmissible at any q in prime_list,
 *        -3 if the primorial overflows u64 (CRT-join cannot represent it),
 *        -4 on malloc failure (peak_bytes_out reflects last successful step).
 *
 * Estimation method:
 *   final_size  = prod_{q in prime_list}(q - |F_q|)
 *   peak_bytes  = max over i of (size_after_step_i + size_after_step_{i+1}) * 8
 *   The +8 byte multiplier reflects the u64 element width.
 */
int  kt_wheel_crt_join_streaming(const uint32_t *pat, int k,
                                 const uint32_t *prime_list, int n_primes,
                                 size_t max_bytes,
                                 size_t *peak_bytes_out,
                                 kt_wheel_t *out);

/* Parse a structural wheel expression:
 *
 *   X#             -> all primes <= X
 *   X#/Y[/Z...]    -> all primes <= X, except dropped primes Y, Z, ...
 *
 * Examples: 37#, 47#/31, 47#/17/31, 47#/11/17/31.
 *
 * `prime_catalog` supplies the allowed ordered primes.  The current CUDA
 * engine passes kt_first_primes[] (2..47), so X and every dropped Y must be
 * present in that catalog, and each Y must be strictly below X.  The returned
 * prime list is ordered ascending and the canonical expression writes drops
 * sorted by catalog order, so
 * 47#/31/17 normalizes to 47#/17/31.
 *
 * Returns 0 on success, -1 on parse/validation failure.  `err`, if supplied,
 * receives a short diagnostic.
 */
int kt_wheel_parse_expr(const char *expr,
                        const uint32_t *prime_catalog, int catalog_n,
                        uint32_t *out_primes, int *out_n_primes,
                        int *out_ceiling_idx,
                        char *out_canon, size_t out_canon_len,
                        char *err, size_t err_len);

/* Release out->offsets (no-op if NULL). */
void kt_wheel_free(kt_wheel_t *w);

/* Forbidden-residue set F_q = { (q - (b_i mod q)) mod q }, deduped.
 * out_forbidden must have capacity >= k. Returns count. */
int kt_wheel_pattern_forbidden(const uint32_t *pat, int k, uint32_t q,
                               uint32_t *out_forbidden);

/* FNV-1a-64 over an array of u64s (each value as 8 little-endian bytes). */
uint64_t kt_wheel_fnv1a64_u64_array(const uint64_t *arr, int n);

/* Forbidden-residue u64 mask for pattern at prime q (q < 64). Bit r is set
 * iff r in F_q (residue r is forbidden at q). Phase 3c L2 stage uses this. */
uint64_t kt_forbidden_mask_u64(const uint32_t *pat, int k, uint32_t q);

/* Forbidden-residue lo/hi u64 pair for pattern at prime q (q < 128). Bit r
 * is set in lo (r<64) or hi (r>=64). Phase 3c ext-L2 stage uses this. */
void     kt_forbidden_mask_u128(const uint32_t *pat, int k, uint32_t q,
                                uint64_t *lo, uint64_t *hi);

/* Packed bitvec for line-sieve prime q (q < 64*words). out[words] u64s,
 * each bit set iff that residue is forbidden. Caller zero-fills out. */
void     kt_forbidden_mask_packed(const uint32_t *pat, int k, uint32_t q,
                                  uint64_t *out, int words);

/* Canonical-hash entry for filter masks (Phase 3c). FNV-1a-64 over the
 * three packed mask arrays; runtime asserts agreement at startup. */
typedef struct {
    const char *pattern_name;
    uint64_t    l2_hash;        /* over the L2 prime mask u64s */
    uint64_t    ext_l2_hash;    /* over the ext-L2 lo/hi pairs */
    uint64_t    line_hash;      /* over the line-sieve packed bitvec */
} kt_canonical_filter_t;

extern const kt_canonical_filter_t kt_canonical_filter_hashes[];
extern const int kt_canonical_filter_hashes_count;

const kt_canonical_filter_t *kt_filter_canonical_lookup(const char *pattern_name);

/* Canonical-hash entry for ground-truth assertion at startup. */
typedef struct {
    const char *pattern_name;
    int         n_primes;        /* length of primes[] */
    uint32_t    primes[16];      /* primes used to build wheel */
    int         n_admissible;
    uint64_t    fnv1a64_hash;
} kt_canonical_wheel_t;

/* Generated by tools/dump_wheel_canonical_hash.gp; pasted into kt_wheel.c. */
extern const kt_canonical_wheel_t kt_canonical_wheel_hashes[];
extern const int kt_canonical_wheel_hashes_count;

/* Lookup canonical entry by name + prime list. NULL if not found. */
const kt_canonical_wheel_t *kt_wheel_canonical_lookup(
    const char *pattern_name,
    const uint32_t *prime_list, int n_primes);

#ifdef __cplusplus
}
#endif

#endif /* KT_WHEEL_H */
