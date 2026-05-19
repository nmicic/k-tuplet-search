/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_u128.h — u128 GPU primitives for Phase 3d Fermat-2 prefilter.
 *
 * LINEAGE
 *   Verbatim port of gpu_u128 / gpu_u128_mulmod / gpu_u128_powmod from
 *   the sister project cunningham-chain-search
 *   (src/cuda/cc18_filter_cuda_CpC_v15.cu:1390-1539).
 *   The 20-witness Miller-Rabin (gpu_is_prime) is intentionally NOT ported:
 *   Phase 3d ships Fermat-2 only at the GPU prefilter; CPU BPSW certifies.
 *
 * Everything is a static __device__ __forceinline__ definition in the header
 * so CUDA translation units inline the primitives without needing relocatable
 * device code. kt_u128.cu exists only to honor the file list in the Makefile;
 * it includes this header but defines nothing new.
 */

#ifndef KT_U128_H
#define KT_U128_H

#include <stdint.h>
#include <cuda_runtime.h>

typedef struct kt_u128 {
    uint64_t lo;
    uint64_t hi;
} kt_u128;

static __device__ __forceinline__ kt_u128 kt_u128_from_u64(uint64_t v) {
    kt_u128 r; r.lo = v; r.hi = 0; return r;
}

static __device__ __forceinline__ kt_u128 kt_u128_add(kt_u128 a, kt_u128 b) {
    kt_u128 r;
    r.lo = a.lo + b.lo;
    r.hi = a.hi + b.hi + (r.lo < a.lo ? 1 : 0);
    return r;
}

static __device__ __forceinline__ kt_u128 kt_u128_sub(kt_u128 a, kt_u128 b) {
    kt_u128 r;
    r.lo = a.lo - b.lo;
    r.hi = a.hi - b.hi - (a.lo < b.lo ? 1 : 0);
    return r;
}

static __device__ __forceinline__ int kt_u128_lt(kt_u128 a, kt_u128 b) {
    return (a.hi < b.hi) || (a.hi == b.hi && a.lo < b.lo);
}

static __device__ __forceinline__ int kt_u128_eq(kt_u128 a, kt_u128 b) {
    return a.lo == b.lo && a.hi == b.hi;
}

static __device__ __forceinline__ int kt_u128_gte(kt_u128 a, kt_u128 b) {
    return !kt_u128_lt(a, b);
}

static __device__ __forceinline__ int kt_u128_is_zero(kt_u128 a) {
    return a.lo == 0 && a.hi == 0;
}

static __device__ __forceinline__ kt_u128 kt_u128_shl1(kt_u128 a) {
    kt_u128 r;
    r.hi = (a.hi << 1) | (a.lo >> 63);
    r.lo = a.lo << 1;
    return r;
}

static __device__ __forceinline__ kt_u128 kt_u128_shr1(kt_u128 a) {
    kt_u128 r;
    r.lo = (a.lo >> 1) | (a.hi << 63);
    r.hi = a.hi >> 1;
    return r;
}

/* 64x64 -> 128 multiply via PTX mul.hi.u64. */
static __device__ __forceinline__ kt_u128 kt_u128_mul64(uint64_t a, uint64_t b) {
    kt_u128 r;
    r.lo = a * b;
    asm("mul.hi.u64 %0, %1, %2;" : "=l"(r.hi) : "l"(a), "l"(b));
    return r;
}

/* 128x64 -> low 128 bits. */
static __device__ __forceinline__ kt_u128 kt_u128_mul64_u128(uint64_t a, kt_u128 b) {
    kt_u128 lo_part = kt_u128_mul64(a, b.lo);
    uint64_t hi_part = a * b.hi;
    lo_part.hi += hi_part;
    return lo_part;
}

static __device__ __forceinline__ int kt_u128_clz(kt_u128 a) {
    if (a.hi) return __clzll(a.hi);
    if (a.lo) return 64 + __clzll(a.lo);
    return 128;
}

/* a % m via binary long division. */
static __device__ kt_u128 kt_u128_mod(kt_u128 a, kt_u128 m) {
    if (kt_u128_lt(a, m)) return a;
    if (kt_u128_is_zero(m)) return a;

    int shift = kt_u128_clz(m) - kt_u128_clz(a);
    if (shift < 0) return a;

    kt_u128 divisor = m;
    for (int i = 0; i < shift; i++) divisor = kt_u128_shl1(divisor);

    for (int i = shift; i >= 0; i--) {
        if (kt_u128_gte(a, divisor))
            a = kt_u128_sub(a, divisor);
        divisor = kt_u128_shr1(divisor);
    }
    return a;
}

/* (a*b) % m via shift-and-add. Used by kt_u128_powmod. */
static __device__ kt_u128 kt_u128_mulmod(kt_u128 a, kt_u128 b, kt_u128 m) {
    a = kt_u128_mod(a, m);
    kt_u128 result = kt_u128_from_u64(0);

    int top_bit = 127 - kt_u128_clz(b);
    for (int bit = top_bit; bit >= 0; bit--) {
        result = kt_u128_shl1(result);
        if (kt_u128_gte(result, m)) result = kt_u128_sub(result, m);

        uint64_t word = (bit >= 64) ? b.hi : b.lo;
        int bitpos = bit & 63;
        if ((word >> bitpos) & 1) {
            result = kt_u128_add(result, a);
            if (kt_u128_gte(result, m)) result = kt_u128_sub(result, m);
        }
    }
    return result;
}

/* base^exp mod mod, square-and-multiply from the top set bit. */
static __device__ kt_u128 kt_u128_powmod(kt_u128 base, kt_u128 exp, kt_u128 mod) {
    kt_u128 result = kt_u128_from_u64(1);
    base = kt_u128_mod(base, mod);

    if (kt_u128_is_zero(exp)) return result;
    int top_bit = 127 - kt_u128_clz(exp);
    for (int bit = top_bit; bit >= 0; bit--) {
        result = kt_u128_mulmod(result, result, mod);
        uint64_t word = (bit >= 64) ? exp.hi : exp.lo;
        int bitpos = bit & 63;
        if ((word >> bitpos) & 1) {
            result = kt_u128_mulmod(result, base, mod);
        }
    }
    return result;
}

/* Fermat base-2: returns 1 iff 2^(n-1) mod n == 1. n must be odd, > 3.
 * Caller is responsible for trial-dividing the small primes; we treat 2|n
 * as immediate composite for safety. */
static __device__ int kt_fermat_base2_u128(kt_u128 n) {
    if ((n.lo & 1) == 0) return 0;                    /* even -> composite */
    if (n.hi == 0 && n.lo < 4) return n.lo == 2 || n.lo == 3 ? 1 : 0;
    kt_u128 nm1 = kt_u128_sub(n, kt_u128_from_u64(1));
    kt_u128 base = kt_u128_from_u64(2);
    kt_u128 r = kt_u128_powmod(base, nm1, n);
    return r.lo == 1 && r.hi == 0;
}

/* a mod m, where m fits in u64. Reduces hi limb first via repeated mod_u64. */
static __device__ __forceinline__ uint64_t kt_u128_mod_u64(kt_u128 a, uint64_t m) {
    /* (hi * 2^64 + lo) mod m  =  ((hi mod m) * 2^64 + lo) mod m.
     * Compute (h * 2^64) mod m by 64 iterated doublings; cheap (~64 cycles)
     * and avoids the asm uint128 dance. For Stage-0 (one mod per candidate)
     * this is plenty. */
    if (a.hi == 0) return a.lo % m;
    uint64_t r = a.hi % m;
    #pragma unroll 64
    for (int i = 0; i < 64; i++) {
        r <<= 1;
        if (r >= m) r -= m;
    }
    /* now r = (a.hi * 2^64) mod m; add a.lo mod m and reduce. */
    uint64_t lo_mod = a.lo % m;
    uint64_t s = r + lo_mod;
    if (s < r || s >= m) s -= m;
    return s;
}

/* Phase 4a-3: Barrett-reciprocal variant of kt_u128_mod_u64.
 *
 * Replaces the 64-iter shift-and-add reduction loop in the original
 * kt_u128_mod_u64 with a constant-time multiply by a precomputed reciprocal
 * mu = floor(2^128 / m). Caller (host) computes mu once per launch and uploads
 * to __constant__ memory; per-call cost drops from ~70 cycles to ~5-6.
 *
 * Preconditions:
 *   - m >= 2, m fits in u64 (we use it for d_primorial = 37# = 7.42e12).
 *   - m <= 2^63 + 1 — same upper bound as the shift-loop reference, beyond
 *     which the q.lo*m subtraction wraps u64 and the corrections cannot
 *     recover (analogous to kt_u128_mod_u64's own r<<=1 overflow). Our
 *     primorial is 2^43, well below this; if a future caller needs m near
 *     2^64, use full-u128 subtraction or a different reduction scheme.
 *   - mu = floor(2^128 / m); compute on host as
 *       (unsigned __int128)mu = (~(unsigned __int128)0 - m + 1) / m + 1;
 *     i.e. (-(__uint128_t)m)/m + 1 (the unsigned negation gives 2^128 - m).
 *   - a < 2^128 (always true since kt_u128 is exactly 128 bits).
 *
 * The 128x128 -> top-128 multiply uses 4 mul.hi.u64 + cross-add carries.
 * Quotient estimate q' may underestimate the true quotient by at most 2;
 * we apply two corrections. T25 (kt_filter_v4) verifies against the
 * shift-loop kt_u128_mod_u64 across edge cases.
 *
 * The original kt_u128_mod_u64 stays intact above so v1/v2/v3 continue to
 * work. Only kt_filter_v4 calls this Barrett variant. */
static __device__ __forceinline__ uint64_t
kt_u128_mod_u64_barrett(kt_u128 a, uint64_t m, kt_u128 mu) {
    /* Fast path: a fits in u64 (a.hi == 0). One HW divide is cheaper than
     * the full Barrett dance. Original kt_u128_mod_u64 has the same branch. */
    if (a.hi == 0) return a.lo % m;

    /* 128x128 multiply, keep top 128 bits.
     *   (a.hi*2^64 + a.lo) * (mu.hi*2^64 + mu.lo)
     *     = a.lo*mu.lo                   [bits 0..127]
     *     + (a.lo*mu.hi + a.hi*mu.lo)*2^64 [bits 64..191]
     *     + a.hi*mu.hi*2^128             [bits 128..255]
     * We need bits 128..255, i.e. q.lo = bits[128..191], q.hi = bits[192..255].
     */
    uint64_t a_lo = a.lo, a_hi = a.hi;
    uint64_t mu_lo = mu.lo, mu_hi = mu.hi;

    /* Cross products. Use mul.hi.u64 inline asm for the high halves; the
     * low halves are plain 64-bit multiplies (compiler emits mul.lo.u64). */
    uint64_t p0_hi;                    /* hi64(a_lo * mu_lo) — only hi half used */
    asm("mul.hi.u64 %0, %1, %2;" : "=l"(p0_hi) : "l"(a_lo), "l"(mu_lo));

    uint64_t p1_lo = a_lo * mu_hi;
    uint64_t p1_hi;
    asm("mul.hi.u64 %0, %1, %2;" : "=l"(p1_hi) : "l"(a_lo), "l"(mu_hi));

    uint64_t p2_lo = a_hi * mu_lo;
    uint64_t p2_hi;
    asm("mul.hi.u64 %0, %1, %2;" : "=l"(p2_hi) : "l"(a_hi), "l"(mu_lo));

    uint64_t p3_lo = a_hi * mu_hi;
    /* p3_hi (top 64 of a_hi*mu_hi) feeds q.hi only, which we don't need —
     * r = a.lo - low64(q*m) and low64(q*m) depends only on q.lo (= col2c).
     * So we deliberately skip the mul.hi for p3 to save one cycle. */

    /* Column [64..127] = p0_hi + p1_lo + p2_lo. Track carry into [128..]. */
    uint64_t col1   = p0_hi + p1_lo;
    uint64_t carry1 = (col1 < p0_hi);
    uint64_t col1b  = col1 + p2_lo;
    carry1         += (col1b < col1);

    /* Column [128..191] = p1_hi + p2_hi + p3_lo + carry1. Track carry. */
    uint64_t col2   = p1_hi + p2_hi;
    uint64_t carry2 = (col2 < p1_hi);
    uint64_t col2b  = col2 + p3_lo;
    carry2         += (col2b < col2);
    uint64_t col2c  = col2b + carry1;
    carry2         += (col2c < col2b);

    /* Column [192..255] = p3_hi + carry2 — skipped; q.hi is unused. */

    /* q.lo = col2c, q.hi = unused. r = a.lo - low64(q*m), and low64(q*m)
     * only depends on low64(q) = col2c.
     *
     * r_true = a - q*m fits in u64 (it's < 2*m + extra correction = 4m at
     * most), so computing in u64 mod 2^64 gives the right value. */
    uint64_t r = a_lo - col2c * m;

    /* Möller-Granlund-style: estimate q' may be off by up to 2. Two
     * unconditional corrections. Each is `if (r >= m) r -= m` which the
     * NVCC backend lowers to a select/sub (no branch divergence). */
    if (r >= m) r -= m;
    if (r >= m) r -= m;
    return r;
}

/* a mod q, where q fits in u32. Two reductions: split lo into halves. */
static __device__ __forceinline__ uint32_t kt_u128_mod_u32(kt_u128 a, uint32_t q) {
    /* hi mod q, then fold across 64-bit boundary, then fold lo halves. */
    uint64_t r = (a.hi == 0) ? 0 : ((uint64_t)(a.hi % q));
    /* r * 2^64 mod q via two 32-bit shifts. */
    r = (r << 32) | (a.lo >> 32);
    r %= q;
    r = (r << 32) | (uint32_t)a.lo;
    r %= q;
    return (uint32_t)r;
}

#endif /* KT_U128_H */
