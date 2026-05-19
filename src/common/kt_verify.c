/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_verify.c — host BPSW certifier for k-tuplet candidates.
 *
 * Extracted verbatim (with `static` -> public linkage on the exposed
 * symbols) from src/cpu/kt_gmp_v1.c U128/Montgomery + verify_tuplet_gmp
 * blocks. CPU `kt_search` and GPU `kt_filter` both link this TU.
 *
 * MATH PROVENANCE
 *   u128 Montgomery stack: ported from cc_gmp_v34_bit-vector_10.c.
 *   verify_tuplet_gmp: BPSW (mpz_probab_prime_p, 25 rounds) per offset, with
 *   optional Fermat-base-2 prefilter (--opt-fermat, default ON) and an
 *   optional u128 Montgomery Fermat (--opt-mont-fermat, default OFF; gated
 *   on n+offset_max <= 124 bits to keep clear of the assert).
 */

#define _GNU_SOURCE
#define KT_VERIFY_INTERNAL_TYPES
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>
#include <gmp.h>

#include "ktuplet_pattern.h"

typedef uint64_t u64;
typedef uint32_t u32;
typedef unsigned __int128 u128;
typedef u128 kt_u128_int;

#include "kt_verify.h"

/* =============================================================================
 * Owned globals — runtime toggles + atomic counters.
 * ========================================================================== */

int      g_opt_fermat            = 1;
int      g_opt_mont_fermat       = 0;
uint64_t g_op_fermat_tests       = 0;
uint64_t g_op_fermat_mont_tests  = 0;
uint64_t g_op_fermat_rejects     = 0;
uint64_t g_op_prime_tests        = 0;

/* =============================================================================
 * U128 / MONTGOMERY (verbatim from cc_gmp_v34_bit-vector_10.c)
 * ========================================================================== */

u128 mpz_to_u128(const mpz_t x) {
    u64 lo = (u64)mpz_getlimbn(x, 0);
    u64 hi = (mpz_size(x) > 1) ? (u64)mpz_getlimbn(x, 1) : 0;
    return ((u128)hi << 64) | lo;
}

void u128_to_mpz(mpz_t x, u128 v) {
    u64 lo = (u64)v, hi = (u64)(v >> 64);
    if (hi) { mpz_set_ui(x, hi); mpz_mul_2exp(x, x, 64); mpz_add_ui(x, x, lo); }
    else mpz_set_ui(x, lo);
}

static inline u64 compute_ninv(u64 n0) {
    u64 inv = 1;
    inv *= 2 - n0 * inv;
    inv *= 2 - n0 * inv;
    inv *= 2 - n0 * inv;
    inv *= 2 - n0 * inv;
    inv *= 2 - n0 * inv;
    inv *= 2 - n0 * inv;
    return -inv;
}

static inline void compute_r_and_r2(u128 n128, u128* r_out, u128* r2_out) {
    u128 x = 1;
    for (int i = 0; i < 128; i++) { x <<= 1; if (x >= n128) x -= n128; }
    *r_out = x;
    for (int i = 0; i < 128; i++) { x <<= 1; if (x >= n128) x -= n128; }
    *r2_out = x;
}

void mont_ctx_init(MontCtx* ctx, u128 n128) {
    assert(n128 < ((u128)1 << 127) && "Montgomery requires n < 2^127");
    ctx->n[0] = (u64)n128; ctx->n[1] = (u64)(n128 >> 64);
    ctx->ninv = compute_ninv(ctx->n[0]);
    u128 r, r2;
    compute_r_and_r2(n128, &r, &r2);
    ctx->r1[0] = (u64)r; ctx->r1[1] = (u64)(r >> 64);
    ctx->r2[0] = (u64)r2; ctx->r2[1] = (u64)(r2 >> 64);
}

static inline void mont_mul(u64 r[2], const u64 a[2], const u64 b[2], const MontCtx* ctx) {
    const u64* n = ctx->n;
    const u64 ninv = ctx->ninv;
    u128 p00 = (u128)a[0]*b[0], p01 = (u128)a[0]*b[1];
    u128 p10 = (u128)a[1]*b[0], p11 = (u128)a[1]*b[1];
    u64 T0 = (u64)p00;
    u128 mid = (p00 >> 64) + (u64)p01 + (u64)p10;
    u64 T1 = (u64)mid;
    u128 hi = (mid >> 64) + (p01 >> 64) + (p10 >> 64) + (u64)p11;
    u64 T2 = (u64)hi, T3 = (u64)(hi >> 64) + (u64)(p11 >> 64);
    u64 m0 = T0 * ninv;
    u128 c = (u128)m0 * n[0] + T0;
    c = (c >> 64) + (u128)m0 * n[1] + T1; T1 = (u64)c;
    c = (c >> 64) + T2; T2 = (u64)c;
    c = (c >> 64) + T3; T3 = (u64)c;
    u64 T4 = (u64)(c >> 64);
    u64 m1 = T1 * ninv;
    c = (u128)m1 * n[0] + T1;
    c = (c >> 64) + (u128)m1 * n[1] + T2; r[0] = (u64)c;
    c = (c >> 64) + T3; r[1] = (u64)c;
    u64 carry = (u64)(c >> 64) + T4;
    if (carry || r[1] > n[1] || (r[1] == n[1] && r[0] >= n[0])) {
        u128 v = ((u128)r[1] << 64) | r[0];
        v -= ((u128)n[1] << 64) | n[0];
        r[0] = (u64)v; r[1] = (u64)(v >> 64);
    }
}

static inline void mont_sqr(u64 r[2], const u64 a[2], const MontCtx* ctx) {
    const u64* n = ctx->n;
    const u64 ninv = ctx->ninv;
    u128 p00 = (u128)a[0]*a[0], p01 = (u128)a[0]*a[1], p11 = (u128)a[1]*a[1];
    u128 dp01 = p01 << 1;
    u64 T0 = (u64)p00;
    u128 mid = (p00 >> 64) + (u64)dp01;
    u64 T1 = (u64)mid;
    u128 hi = (mid >> 64) + (dp01 >> 64) + (u64)p11;
    u64 T2 = (u64)hi, T3 = (u64)(hi >> 64) + (u64)(p11 >> 64);
    u64 m0 = T0 * ninv;
    u128 c = (u128)m0 * n[0] + T0;
    c = (c >> 64) + (u128)m0 * n[1] + T1; T1 = (u64)c;
    c = (c >> 64) + T2; T2 = (u64)c;
    c = (c >> 64) + T3; T3 = (u64)c;
    u64 T4 = (u64)(c >> 64);
    u64 m1 = T1 * ninv;
    c = (u128)m1 * n[0] + T1;
    c = (c >> 64) + (u128)m1 * n[1] + T2; r[0] = (u64)c;
    c = (c >> 64) + T3; r[1] = (u64)c;
    u64 carry = (u64)(c >> 64) + T4;
    if (carry || r[1] > n[1] || (r[1] == n[1] && r[0] >= n[0])) {
        u128 v = ((u128)r[1] << 64) | r[0];
        v -= ((u128)n[1] << 64) | n[0];
        r[0] = (u64)v; r[1] = (u64)(v >> 64);
    }
}

static inline void mont_to(u64 r[2], const u64 a[2], const MontCtx* ctx) { mont_mul(r, a, ctx->r2, ctx); }
static inline void mont_from(u64 r[2], const u64 a[2], const MontCtx* ctx) {
    u64 one[2] = {1, 0}; mont_mul(r, a, one, ctx);
}

u128 mont_powm(u128 base, u128 exp, const MontCtx* ctx) {
    if (exp == 0) return 1;
    u64 b[2] = {(u64)base, (u64)(base >> 64)}, bm[2];
    mont_to(bm, b, ctx);
    int top_bit;
    u64 eh = (u64)(exp >> 64), el = (u64)exp;
    if (eh) top_bit = 127 - __builtin_clzll(eh);
    else    top_bit = 63 - __builtin_clzll(el);
    u64 rm[2] = {bm[0], bm[1]}, tmp[2];
    for (int bit = top_bit - 1; bit >= 0; bit--) {
        mont_sqr(tmp, rm, ctx); rm[0] = tmp[0]; rm[1] = tmp[1];
        if ((exp >> bit) & 1) { mont_mul(tmp, rm, bm, ctx); rm[0] = tmp[0]; rm[1] = tmp[1]; }
    }
    u64 result[2]; mont_from(result, rm, ctx);
    return ((u128)result[1] << 64) | result[0];
}

static int miller_rabin_mont(u128 n, u64 a, const MontCtx* ctx) {
    u128 nm1 = n - 1;
    int s = 0;
    { u128 t = nm1; while (!(t & 1)) { t >>= 1; s++; } }
    u128 d = nm1 >> s;
    u128 x = mont_powm(a, d, ctx);
    if (x == 1 || x == nm1) return 1;
    u64 xm[2], tmp2[2];
    u64 xv[2] = {(u64)x, (u64)(x >> 64)}; mont_to(xm, xv, ctx);
    u64 nm1v[2] = {(u64)nm1, (u64)(nm1 >> 64)}, nm1m[2]; mont_to(nm1m, nm1v, ctx);
    for (int r = 1; r < s; r++) {
        mont_sqr(tmp2, xm, ctx); xm[0] = tmp2[0]; xm[1] = tmp2[1];
        if (xm[0] == nm1m[0] && xm[1] == nm1m[1]) return 1;
        if (xm[0] == ctx->r1[0] && xm[1] == ctx->r1[1]) return 0;
    }
    return 0;
}

int is_prime_native(u128 n) {
    if (n < 2) return 0;
    if (n < 4) return 1;
    if (!(n & 1)) return 0;
    static const u32 small[] = {3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97};
    for (size_t i = 0; i < sizeof(small)/sizeof(small[0]); i++) {
        u32 p = small[i];
        if (n == p) return 1;
        if (n % p == 0) return 0;
    }
    MontCtx ctx; mont_ctx_init(&ctx, n);
    if (!miller_rabin_mont(n, 2, &ctx)) return 0;
    if (n > 3 && !miller_rabin_mont(n, 3, &ctx)) return 0;
    if (n > 5 && !miller_rabin_mont(n, 5, &ctx)) return 0;
    return 1;
}

/* Fermat base-2 PRP test: returns 1 iff 2^(n-1) mod n == 1.
 * scratch (r, nm1) supplied by caller; we keep them as __thread persistent
 * buffers in verify_tuplet_gmp to avoid mpz_init/clear on every call. */
int fermat_base2_gmp(const mpz_t n, mpz_t r, mpz_t nm1) {
    mpz_sub_ui(nm1, n, 1);
    mpz_set_ui(r, 2);
    mpz_powm(r, r, nm1, n);
    return mpz_cmp_ui(r, 1) == 0;
}

int fermat_base2_mont(u128 n) {
    if ((n & 1) == 0) return 0;
    MontCtx ctx;
    mont_ctx_init(&ctx, n);
    u128 r = mont_powm(2, n - 1, &ctx);
    return r == 1;
}

int verify_tuplet_gmp(const mpz_t n, const KTupletPattern* pat, mpz_t scratch) {
    static __thread mpz_t f_r, f_nm1;
    static __thread int f_init = 0;
    if (!f_init) { mpz_init(f_r); mpz_init(f_nm1); f_init = 1; }

    if (g_opt_fermat) {
        int can_use_mont = 0;
        if (g_opt_mont_fermat) {
            mpz_add_ui(scratch, n, (unsigned long)pat->offsets[pat->k - 1]);
            if (mpz_sizeinbase(scratch, 2) <= 124) can_use_mont = 1;
        }
        if (can_use_mont) {
            for (int i = 0; i < pat->k; i++) {
                mpz_add_ui(scratch, n, (unsigned long)pat->offsets[i]);
                __atomic_fetch_add(&g_op_fermat_tests, 1, __ATOMIC_RELAXED);
                __atomic_fetch_add(&g_op_fermat_mont_tests, 1, __ATOMIC_RELAXED);
                u128 nv = mpz_to_u128(scratch);
                if (!fermat_base2_mont(nv)) {
                    __atomic_fetch_add(&g_op_fermat_rejects, 1, __ATOMIC_RELAXED);
                    return 0;
                }
            }
        } else {
            for (int i = 0; i < pat->k; i++) {
                mpz_add_ui(scratch, n, (unsigned long)pat->offsets[i]);
                __atomic_fetch_add(&g_op_fermat_tests, 1, __ATOMIC_RELAXED);
                if (!fermat_base2_gmp(scratch, f_r, f_nm1)) {
                    __atomic_fetch_add(&g_op_fermat_rejects, 1, __ATOMIC_RELAXED);
                    return 0;
                }
            }
        }
    }

    for (int i = 0; i < pat->k; i++) {
        mpz_add_ui(scratch, n, (unsigned long)pat->offsets[i]);
        __atomic_fetch_add(&g_op_prime_tests, 1, __ATOMIC_RELAXED);
        if (mpz_probab_prime_p(scratch, 25) <= 0) return 0;
    }
    return 1;
}
