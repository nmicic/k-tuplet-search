/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_verify.h — host BPSW certifier for k-tuplet candidates.
 *
 * Owns the verify_tuplet_gmp + Fermat-2 + u128 Montgomery stack that was
 * previously inlined in src/cpu/kt_gmp_v1.c. Both the CPU search engine
 * (kt_search) and the GPU host driver (kt_filter) link this TU so the
 * certification path is byte-identical across engines.
 *
 * Globals owned here:
 *   g_opt_fermat        --opt-fermat / --no-opt-fermat        (default 1)
 *   g_opt_mont_fermat   --opt-mont-fermat / --no-opt-mont-fermat (default 0)
 *   g_op_fermat_tests       (counter)
 *   g_op_fermat_mont_tests  (counter)
 *   g_op_fermat_rejects     (counter)
 *   g_op_prime_tests        (counter)
 *
 * A host that does NOT touch these defaults still gets correct behavior
 * because they live in the kt_verify TU.
 */

#ifndef KT_VERIFY_H
#define KT_VERIFY_H

#include <stdint.h>
#include <gmp.h>
#include "ktuplet_pattern.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The CPU TU already typedefs u64/u128; we expose extern signatures using
 * uint64_t and unsigned __int128 directly so this header is self-contained. */
#ifndef KT_VERIFY_INTERNAL_TYPES
typedef unsigned __int128 kt_u128_int;
#endif

typedef struct {
    uint64_t n[2];
    uint64_t ninv;
    uint64_t r1[2];
    uint64_t r2[2];
} MontCtx;

kt_u128_int mpz_to_u128(const mpz_t x);
void        u128_to_mpz(mpz_t x, kt_u128_int v);
void        mont_ctx_init(MontCtx* ctx, kt_u128_int n128);
kt_u128_int mont_powm(kt_u128_int base, kt_u128_int exp, const MontCtx* ctx);
int         is_prime_native(kt_u128_int n);
int         fermat_base2_gmp(const mpz_t n, mpz_t r, mpz_t nm1);
int         fermat_base2_mont(kt_u128_int n);
int         verify_tuplet_gmp(const mpz_t n, const KTupletPattern* pat, mpz_t scratch);

extern int      g_opt_fermat;
extern int      g_opt_mont_fermat;
extern uint64_t g_op_fermat_tests;
extern uint64_t g_op_fermat_mont_tests;
extern uint64_t g_op_fermat_rejects;
extern uint64_t g_op_prime_tests;

#ifdef __cplusplus
}
#endif
#endif /* KT_VERIFY_H */
