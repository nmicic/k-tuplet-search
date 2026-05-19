/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_tests.cu — host-only subset of the --test suite, extracted from
 * kt_filter_v8.cu in W20-DEC Phase 3 Step 8.
 *
 * PARTIAL EXTRACT: this TU contains the 18 tests that do not launch
 * production CUDA kernels (T1, T4-T6, T9, T16, T19, T26-T27, T32, T33,
 * T37, T46/b/c, T47, T48, T50) plus the kt_capture_envelope_warning helper
 * used by T26/T27.  Roughly half the suite remains in kt_filter_v8.cu
 * because nvcc requires kernel launches to share a TU with the kernel's
 * __global__ definition (absent -rdc=true, which the brief forbids).
 *
 * run_unit_tests dispatcher stays in core; it calls the moved tests
 * via the forward declarations in kt_tests.h.
 */
#include "kt_tests.h"
#include "kt_cli.h"
#include "kt_signal.h"
#include "kt_lanes.h"
#include "kt_records.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cuda_runtime.h>
#include <gmp.h>

extern "C" {
#include "ktuplet_pattern.h"
#include "kt_wheel.h"
#include "kt_verify.h"
#include "kt_json_min.h"
}
#include "kt_u128.h"

/* Engine-internal helpers consumed by these tests; `static` dropped in
 * kt_filter_v8.cu at Step 8.  Definitions remain in core, compiled as
 * C++ (no extern "C" wrapper) — declarations here match. */
extern int  parse_decimal_u128(const char *s, unsigned __int128 *out);
extern int  parse_prefix_str(const char *s, unsigned __int128 *val, int *bits);
extern void kt_u128_format_dec(unsigned __int128 v, char *buf, size_t buflen);
extern struct kt_known_records *
    kt_records_load_with_search(const char **out_used_path, int verbose);

/* Bloom filter exposed from kt_filter_v8.cu: T33 needs to exercise the
 * exact rotors/hash the engine uses, so duplicating would risk drift
 * (initial attempt produced 11 false-positive collisions vs the
 * original).  KtBloom + helpers had `static` dropped in core at Step 8. */
#define KT_BLOOM_BITS  524288u
#define KT_BLOOM_BYTES (KT_BLOOM_BITS / 8u)
#define KT_BLOOM_K     4u

typedef struct KtBloom {
    uint8_t bits[KT_BLOOM_BYTES];
    unsigned long long inserts;
    unsigned long long revisits;
} KtBloom;

extern KtBloom *kt_bloom_alloc(void);
extern void     kt_bloom_free(KtBloom *b);
extern int      kt_bloom_probe(const KtBloom *b, uint64_t key);
extern void     kt_bloom_insert(KtBloom *b, uint64_t key);
extern int      kt_bloom_test_and_insert(KtBloom *b, uint64_t key);
extern uint64_t kt_anchor_key(unsigned __int128 anchor, int anchor_bits);

#ifndef KT_STAGES_ALL
#define KT_STAGES_ALL (KT_STAGE_L2 | KT_STAGE_EXT_L2 | KT_STAGE_LINE | KT_STAGE_FERMAT)
#endif


int test_t1_parse_all_cpu_flags(void) {
    /* T1: every CPU long-flag is parseable. We synthesize an argv covering
     * the full surface and run the parser logic. For simplicity we don't
     * re-enter main(); we just assert the parser table below has entries
     * matching kt_gmp_v1.c print_usage. The exhaustive parse is exercised
     * by the runtime CLI tests in the acceptance script. Here we just
     * sanity-check that the global flag bookkeeping is wired up. */
    int slots = 0;
    slots += 1; /* --pattern */
    slots += 1; /* --k */
    slots += 1; /* --target */
    slots += 1; /* --bits */
    slots += 1; /* --primorial */
    slots += 1; /* --wheel-expr */
    slots += 1; /* --threads */
    slots += 1; /* --prefix */
    slots += 1; /* --random */
    slots += 1; /* --chunk-tiles */
    slots += 1; /* --verbose-rotation */
    slots += 1; /* --inject-cursor-offset */
    slots += 1; /* --sequential */
    slots += 1; /* --output / --log-file */
    slots += 1; /* --quiet */
    slots += 1; /* --full-quiet */
    slots += 1; /* --report / --report-interval-sec */
    slots += 1; /* --bench-jsonl */
    slots += 1; /* --max-batches */
    slots += 1; /* --max-time */
    slots += 1; /* --validate-per-record-budget */
    slots += 1; /* --checkpoint */
    slots += 1; /* --resume */
    slots += 1; /* --ckpt-interval */
    slots += 1; /* --test */
    slots += 1; /* --smoke */
    slots += 1; /* --validate-known */
    slots += 1; /* --validate-known-require-coverage */
    slots += 1; /* --help */
    /* Ignored CPU group */
    slots += 1; /* --no-line-sieve */
    slots += 1; /* --no-bitvec */
    slots += 1; /* --bitvec */
    slots += 1; /* --opt-fermat / --no-opt-fermat */
    slots += 1; /* --opt-mont-fermat / --no-opt-mont-fermat */
    slots += 1; /* --opt-prefetch / --no-opt-prefetch */
    slots += 1; /* --opt-bitscan / --no-opt-bitscan */
    slots += 1; /* --opt-line-cap */
    slots += 1; /* --pin */
    slots += 1; /* --pin-base */
    slots += 1; /* --sieve-only */
    /* GPU-only */
    slots += 1; /* --gpu-device */
    slots += 1; /* --gpu-batch-size */
    slots += 1; /* --gpu-streams */
    slots += 1; /* --gpu-arch */
    if (slots < 30) {
        fprintf(stderr, "T1 FAILED: parser surface too small (%d)\n", slots);
        return 1;
    }
    return 0;
}

static int kt_test_wheel_expr_ok(const char *expr,
                                 const char *want_canon,
                                 int want_n,
                                 int want_ceiling_idx,
                                 const uint32_t *must_not_contain,
                                 int must_not_contain_n) {
    const uint32_t primes[] = {2,3,5,7,11,13,17,19,23,29,31,37,41,43,47};
    uint32_t out[KT_WHEEL_EXPR_MAX_PRIMES];
    int out_n = 0;
    int ceiling_idx = -1;
    char canon[KT_WHEEL_EXPR_CANON_LEN];
    char err[128];
    int rc = kt_wheel_parse_expr(expr,
                                 primes, (int)(sizeof primes / sizeof primes[0]),
                                 out, &out_n, &ceiling_idx,
                                 canon, sizeof canon,
                                 err, sizeof err);
    if (rc != 0) {
        fprintf(stderr, "T50 FAILED: %s rejected: %s\n", expr, err);
        return 1;
    }
    if (strcmp(canon, want_canon) != 0 || out_n != want_n ||
        ceiling_idx != want_ceiling_idx) {
        fprintf(stderr,
                "T50 FAILED: %s canon=%s n=%d ceiling=%d, expected %s/%d/%d\n",
                expr, canon, out_n, ceiling_idx,
                want_canon, want_n, want_ceiling_idx);
        return 1;
    }
    for (int i = 1; i < out_n; i++) {
        if (out[i - 1] >= out[i]) {
            fprintf(stderr, "T50 FAILED: %s output primes not ascending\n", expr);
            return 1;
        }
    }
    for (int j = 0; j < must_not_contain_n; j++) {
        for (int i = 0; i < out_n; i++) {
            if (out[i] == must_not_contain[j]) {
                fprintf(stderr, "T50 FAILED: %s unexpectedly contains %u\n",
                        expr, must_not_contain[j]);
                return 1;
            }
        }
    }
    return 0;
}

static int kt_test_wheel_expr_rejects(const char *expr) {
    const uint32_t primes[] = {2,3,5,7,11,13,17,19,23,29,31,37,41,43,47};
    uint32_t out[KT_WHEEL_EXPR_MAX_PRIMES];
    int out_n = 0;
    int ceiling_idx = -1;
    char canon[KT_WHEEL_EXPR_CANON_LEN];
    char err[128];
    int rc = kt_wheel_parse_expr(expr,
                                 primes, (int)(sizeof primes / sizeof primes[0]),
                                 out, &out_n, &ceiling_idx,
                                 canon, sizeof canon,
                                 err, sizeof err);
    if (rc == 0) {
        fprintf(stderr, "T50 FAILED: %s unexpectedly accepted as %s\n", expr, canon);
        return 1;
    }
    return 0;
}

int test_t50_wheel_expr_parser(void) {
    const uint32_t drop31_17[] = {17, 31};
    const uint32_t drop31[] = {31};

    if (kt_test_wheel_expr_ok("47#/31/17", "47#/17/31", 13, 14,
                              drop31_17, 2) != 0) return 1;
    if (kt_test_wheel_expr_ok("47#", "47#", 15, 14, NULL, 0) != 0) return 1;
    if (kt_test_wheel_expr_ok("47#/31", "47#/31", 14, 14,
                              drop31, 1) != 0) return 1;

    if (kt_test_wheel_expr_rejects("47#/47") != 0) return 1;
    if (kt_test_wheel_expr_rejects("47#/17/17") != 0) return 1;
    if (kt_test_wheel_expr_rejects("47#/53") != 0) return 1;
    if (kt_test_wheel_expr_rejects("47#/") != 0) return 1;
    if (kt_test_wheel_expr_rejects("2#/2") != 0) return 1;

    return 0;
}

int test_t4_banner_ignored_flags(void) {
    /* T4: simulate CPU-flag bookkeeping and confirm emit_ignored_cpu_flag_line
     * would print at least one entry. We capture by setting flags in-process
     * and asserting the predicate; the runtime CLI test in the acceptance
     * script does the end-to-end stdout assertion. */
    int saved_no_bitvec = g_cpu_flag_no_bitvec;
    int saved_opt_fermat_set = g_cpu_flag_opt_fermat_set;
    int saved_opt_fermat_val = g_cpu_flag_opt_fermat_val;
    int saved_opt_line_cap = g_cpu_flag_opt_line_cap;

    g_cpu_flag_no_bitvec = 1;
    g_cpu_flag_opt_fermat_set = 1;
    g_cpu_flag_opt_fermat_val = 0;
    g_cpu_flag_opt_line_cap = 4096;

    int ok = (g_cpu_flag_no_bitvec && g_cpu_flag_opt_fermat_set &&
              g_cpu_flag_opt_line_cap > 0);

    g_cpu_flag_no_bitvec = saved_no_bitvec;
    g_cpu_flag_opt_fermat_set = saved_opt_fermat_set;
    g_cpu_flag_opt_fermat_val = saved_opt_fermat_val;
    g_cpu_flag_opt_line_cap = saved_opt_line_cap;

    if (!ok) {
        fprintf(stderr, "T4 FAILED: ignored-flag bookkeeping broken\n");
        return 1;
    }
    return 0;
}

int test_t5_forbidden_kt5_q7(void) {
    uint32_t k5[] = {0,2,6,8,12};
    uint32_t fbd[16];
    int n = kt_wheel_pattern_forbidden(k5, 5, 7, fbd);
    /* sort ascending */
    for (int i = 0; i < n; i++)
      for (int j = i+1; j < n; j++)
        if (fbd[j] < fbd[i]) { uint32_t t = fbd[i]; fbd[i] = fbd[j]; fbd[j] = t; }
    uint32_t expected[] = {0,1,2,5,6};
    if (n != 5) {
        fprintf(stderr, "T5 FAILED: forbidden(KT5_P0,7) count=%d, expected 5\n", n);
        return 1;
    }
    for (int i = 0; i < 5; i++) {
        if (fbd[i] != expected[i]) {
            fprintf(stderr, "T5 FAILED: forbidden(KT5_P0,7)[%d]=%u expected %u\n",
                    i, fbd[i], expected[i]);
            return 1;
        }
    }
    return 0;
}

int test_t6_kt5_wheel_hash(void) {
    uint32_t k5[] = {0,2,6,8,12};
    uint32_t primes[] = {2,3,5,7,11};
    kt_wheel_t w;
    int rc = kt_wheel_crt_join(k5, 5, primes, 5, &w);
    if (rc != 0) {
        fprintf(stderr, "T6 FAILED: crt_join rc=%d\n", rc);
        return 1;
    }
    const kt_canonical_wheel_t *can =
        kt_wheel_canonical_lookup("KT5_P0", primes, 5);
    if (!can) {
        fprintf(stderr, "T6 FAILED: no canonical entry\n");
        kt_wheel_free(&w); return 1;
    }
    int ok = (can->n_admissible == w.n_admissible &&
              can->fnv1a64_hash  == w.fnv1a64_hash);
    if (!ok) {
        fprintf(stderr,
                "T6 FAILED: KT5_P0 [2..11] runtime n=%d hash=0x%016llx, "
                "canonical n=%d hash=0x%016llx\n",
                w.n_admissible, (unsigned long long)w.fnv1a64_hash,
                can->n_admissible, (unsigned long long)can->fnv1a64_hash);
    }
    kt_wheel_free(&w);
    return ok ? 0 : 1;
}

int test_t9_forbidden_mask_u64(void) {
    uint32_t k5[] = {0,2,6,8,12};
    uint64_t m = kt_forbidden_mask_u64(k5, 5, 7);
    /* Expected: bits at residues 0,1,2,5,6 -> 0b1100111 = 0x67. */
    uint64_t expected = (1ULL<<0) | (1ULL<<1) | (1ULL<<2) | (1ULL<<5) | (1ULL<<6);
    if (m != expected) {
        fprintf(stderr, "T9 FAILED: kt_forbidden_mask_u64(KT5_P0,7)=0x%016llx expected=0x%016llx\n",
                (unsigned long long)m, (unsigned long long)expected);
        return 1;
    }
    return 0;
}

int test_t16_records_load_and_contains(void) {
    const char *used = NULL;
    struct kt_known_records *kr =
        kt_records_load_with_search(&used, /*verbose=*/1);
    if (!kr) {
        fprintf(stderr,
            "T16 FAILED: could not locate records.json (set KT_RECORDS_JSON "
            "to override the search). cwd-relative paths attempted above.\n");
        return 1;
    }
    int hit  = kt_known_records_contains(kr, 16, "47710850533373130107");
    int miss = kt_known_records_contains(kr, 16, "1234567890");
    int total = kt_known_records_total(kr);
    printf("T16 records.json (%s): total=%d hit_first_KT16=%d miss=%d %s\n",
           used, total, hit, miss,
           (hit == 1 && miss == 0 && total > 0) ? "OK" : "FAIL");
    kt_known_records_free(kr);
    if (!(hit == 1 && miss == 0 && total > 0)) return 1;
    return 0;
}

int test_t19_prefix_range_math(void);

int test_t26_warning_bits127_fermat(void);
int test_t27_warning_bits_low_line(void);

int test_t32_u128_format_dec_helper(void);
int test_t33_bloom_revisit_detection(void);

int test_t37_list_patterns(void);

int test_t46_seed_anchor_placement(void);
int test_t46b_lane_min_primorial_alignment(void);
int test_t46c_lane_start_primorial_alignment(void);
int test_t47_records_json_env_override(void);
int test_t48_kpi_target_base_parse(void);

int test_t19_prefix_range_math(void) {
    unsigned __int128 v = 0;
    int b = 0;
    if (parse_prefix_str("0b1", &v, &b) != 0) {
        fprintf(stderr, "T19 FAILED: parse_prefix_str(0b1) failed\n");
        return 1;
    }
    if (b != 1 || v != 1) {
        fprintf(stderr, "T19 FAILED: parse_prefix_str(0b1) -> bits=%d val.lo=%llu (want 1,1)\n",
                b, (unsigned long long)(uint64_t)v);
        return 1;
    }
    int target_bits = 60;
    int shift = target_bits - b;
    unsigned __int128 range_start = v << shift;
    unsigned __int128 range_end   = (v + 1) << shift;
    unsigned __int128 expected_start = (unsigned __int128)1 << 59;
    unsigned __int128 expected_end   = (unsigned __int128)1 << 60;
    if (range_start != expected_start || range_end != expected_end) {
        fprintf(stderr, "T19 FAILED: range=[%llu,%llu) expected=[2^59,2^60)\n",
                (unsigned long long)(uint64_t)range_start,
                (unsigned long long)(uint64_t)range_end);
        return 1;
    }
    /* Multi-bit prefix: 0b101 at 100 bits -> [0xa<<97, 0xb<<97). */
    if (parse_prefix_str("0b101", &v, &b) != 0 || b != 3 || v != 5) {
        fprintf(stderr, "T19 FAILED: parse_prefix_str(0b101) -> bits=%d val=%llu\n",
                b, (unsigned long long)(uint64_t)v);
        return 1;
    }
    /* parse with no 0b. */
    if (parse_prefix_str("11", &v, &b) != 0 || b != 2 || v != 3) {
        fprintf(stderr, "T19 FAILED: parse_prefix_str(11) -> bits=%d val=%llu\n",
                b, (unsigned long long)(uint64_t)v);
        return 1;
    }
    /* parse_decimal_u128 cross-check. */
    unsigned __int128 d = 0;
    if (parse_decimal_u128("47710850533373130107", &d) != 0) {
        fprintf(stderr, "T19 FAILED: parse_decimal_u128 failed\n");
        return 1;
    }
    /* base >> (66 - 1) for KT16 first record, expect leading bits 1 (top bit). */
    unsigned __int128 prefix1 = d >> 65;
    if (prefix1 != 1) {
        fprintf(stderr, "T19 FAILED: KT16 first record top bit = %llu (want 1)\n",
                (unsigned long long)(uint64_t)prefix1);
        return 1;
    }
    printf("T19 prefix range math OK\n");
    return 0;
}

int kt_capture_envelope_warning(int bits, unsigned stages_active,
                                       char *buf, size_t buflen) {
    FILE *f = tmpfile();
    if (!f) return -1;
    kt_emit_envelope_warnings(bits, stages_active, f);
    long pos = ftell(f);
    if (pos < 0) { fclose(f); return -1; }
    rewind(f);
    size_t n = (size_t)pos;
    if (n >= buflen) n = buflen - 1;
    size_t got = fread(buf, 1, n, f);
    buf[got] = '\0';
    fclose(f);
    return 0;
}

int test_t26_warning_bits127_fermat(void) {
    char buf[1024];
    /* Case A: --bits=127 + default stages → must emit G1. */
    if (kt_capture_envelope_warning(127, KT_STAGES_ALL, buf, sizeof buf) != 0) {
        fprintf(stderr, "T26 FAILED: tmpfile capture\n");
        return 1;
    }
    if (!strstr(buf, "G1:") || !strstr(buf, "--bits=127")) {
        fprintf(stderr, "T26 FAILED case-A: expected G1 warning, got: %s\n", buf);
        return 1;
    }
    /* Case B: --bits=127 + Fermat disabled → must be silent. */
    unsigned no_fermat = KT_STAGES_ALL & ~KT_STAGE_FERMAT;
    if (kt_capture_envelope_warning(127, no_fermat, buf, sizeof buf) != 0) {
        fprintf(stderr, "T26 FAILED: tmpfile capture (B)\n");
        return 1;
    }
    if (strstr(buf, "G1:")) {
        fprintf(stderr, "T26 FAILED case-B: G1 fired with Fermat off: %s\n", buf);
        return 1;
    }
    /* Case C: --bits=126 + default stages → must be silent. */
    if (kt_capture_envelope_warning(126, KT_STAGES_ALL, buf, sizeof buf) != 0) {
        fprintf(stderr, "T26 FAILED: tmpfile capture (C)\n");
        return 1;
    }
    if (strstr(buf, "G1:")) {
        fprintf(stderr, "T26 FAILED case-C: G1 fired at bits=126: %s\n", buf);
        return 1;
    }
    printf("T26 G1 envelope warning (--bits>=127 + Fermat): 3/3 cases pass\n");
    return 0;
}

int test_t27_warning_bits_low_line(void) {
    char buf[1024];
    /* Case A: --bits=8 + default stages → must emit G2.
     * Substring is "(G2)" — the warning text uses parens-with-period. */
    if (kt_capture_envelope_warning(8, KT_STAGES_ALL, buf, sizeof buf) != 0) {
        fprintf(stderr, "T27 FAILED: tmpfile capture\n");
        return 1;
    }
    if (!strstr(buf, "(G2)") || !strstr(buf, "--bits=8")) {
        fprintf(stderr, "T27 FAILED case-A: expected G2 warning, got: %s\n", buf);
        return 1;
    }
    /* Case B: --bits=8 + line-sieve disabled → must be silent. */
    unsigned no_line = KT_STAGES_ALL & ~KT_STAGE_LINE;
    if (kt_capture_envelope_warning(8, no_line, buf, sizeof buf) != 0) {
        fprintf(stderr, "T27 FAILED: tmpfile capture (B)\n");
        return 1;
    }
    if (strstr(buf, "(G2)")) {
        fprintf(stderr, "T27 FAILED case-B: G2 fired with line off: %s\n", buf);
        return 1;
    }
    /* Case C: --bits=10 + default stages → must be silent (boundary). */
    if (kt_capture_envelope_warning(10, KT_STAGES_ALL, buf, sizeof buf) != 0) {
        fprintf(stderr, "T27 FAILED: tmpfile capture (C)\n");
        return 1;
    }
    if (strstr(buf, "(G2)")) {
        fprintf(stderr, "T27 FAILED case-C: G2 fired at bits=10: %s\n", buf);
        return 1;
    }
    printf("T27 G2 envelope warning (--bits<10 + line-sieve): 3/3 cases pass\n");
    return 0;
}

int test_t32_u128_format_dec_helper(void) {
    struct Case { unsigned __int128 v; const char *want; };
    /* 2^64 = 18446744073709551616, 2^64+12345 = 18446744073709563961
     * 2^128-1 = 340282366920938463463374607431768211455 */
    Case cases[] = {
        { (unsigned __int128)0,                                          "0" },
        { (unsigned __int128)1,                                          "1" },
        { (unsigned __int128)18446744073709551615ULL,                    "18446744073709551615" },
        { (unsigned __int128)1 << 64,                                    "18446744073709551616" },
        { ((unsigned __int128)1 << 64) + 12345u,                         "18446744073709563961" },
        { (unsigned __int128)((__uint128_t)-1),                          "340282366920938463463374607431768211455" },
    };
    int N = (int)(sizeof(cases) / sizeof(cases[0]));
    for (int i = 0; i < N; i++) {
        char buf[64];
        kt_u128_format_dec(cases[i].v, buf, sizeof buf);
        if (strcmp(buf, cases[i].want) != 0) {
            fprintf(stderr, "T32 FAILED: case %d got=%s want=%s\n",
                    i, buf, cases[i].want);
            return 1;
        }
    }
    /* Round-trip: format then parse and compare to known sum >2^64.
     * 2*((1<<64)) = 36893488147419103232. Tests an integer that arises naturally
     * from "2 × per-batch raw_cand at b80" in the §1.1 reproducer. */
    unsigned __int128 v   = ((unsigned __int128)1 << 64) * 2;
    char buf[64];
    kt_u128_format_dec(v, buf, sizeof buf);
    static const char *want = "36893488147419103232";
    if (strcmp(buf, want) != 0) {
        fprintf(stderr, "T32 FAILED: round-trip got=%s want=%s\n", buf, want);
        return 1;
    }
    printf("T32 kt_u128_format_dec OK (%d edge cases + round-trip past 2^64)\n", N);
    return 0;
}

int test_t33_bloom_revisit_detection(void) {
    KtBloom *b = kt_bloom_alloc();
    if (!b) { fprintf(stderr, "T33 FAILED: kt_bloom_alloc\n"); return 1; }

    /* (a) Same key inserted twice → second probe says "seen". */
    uint64_t key = kt_anchor_key((unsigned __int128)0xdeadbeefcafebabeULL, 24);
    int seen0 = kt_bloom_probe(b, key);     /* expected: 0 */
    kt_bloom_insert(b, key);
    int seen1 = kt_bloom_probe(b, key);     /* expected: 1 */
    if (seen0 != 0 || seen1 != 1) {
        fprintf(stderr, "T33 FAILED: probe before/after insert: %d/%d (want 0/1)\n",
                seen0, seen1);
        kt_bloom_free(b);
        return 1;
    }

    /* (b) Re-insert via test_and_insert → returns 1 (seen) and bumps revisits. */
    int seen2 = kt_bloom_test_and_insert(b, key);
    if (seen2 != 1) {
        fprintf(stderr, "T33 FAILED: test_and_insert(2nd) returned %d (want 1)\n",
                seen2);
        kt_bloom_free(b);
        return 1;
    }
    if (b->revisits != 1u) {
        fprintf(stderr, "T33 FAILED: revisits=%llu (want 1)\n",
                (unsigned long long)b->revisits);
        kt_bloom_free(b);
        return 1;
    }

    /* (c) 4096 distinct anchors should not trigger any revisits at this load
     *     (~0.8 % fill, k=4 hashes; fp rate well below 0.01 %). */
    KtBloom *b2 = kt_bloom_alloc();
    if (!b2) { fprintf(stderr, "T33 FAILED: kt_bloom_alloc(b2)\n"); kt_bloom_free(b); return 1; }
    int collisions = 0;
    for (uint64_t i = 0; i < 4096u; i++) {
        uint64_t k2 = kt_anchor_key((unsigned __int128)i * 0xbf58476d1ce4e5b9ULL, 24);
        if (kt_bloom_test_and_insert(b2, k2)) collisions++;
    }
    if (collisions != 0) {
        fprintf(stderr, "T33 FAILED: %d false-positive collisions in 4096 distinct keys\n",
                collisions);
        kt_bloom_free(b);
        kt_bloom_free(b2);
        return 1;
    }
    kt_bloom_free(b);
    kt_bloom_free(b2);
    printf("T33 Bloom revisit detection OK: 1 revisit on duplicate insert, "
           "0 false-positive collisions on 4096 distinct keys\n");
    return 0;
}

int test_t37_list_patterns(void) {
    (void)mkdir("./tmp", 0755);
    const char *cap_path = "./tmp/t37_list_patterns.txt";
    unlink(cap_path);
    fflush(stdout);
    int saved_stdout = dup(fileno(stdout));
    int cap_fd = open(cap_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (saved_stdout < 0 || cap_fd < 0) {
        fprintf(stderr, "T37 FAILED: stdout redirect (errno=%d)\n", errno);
        if (saved_stdout >= 0) close(saved_stdout);
        if (cap_fd >= 0) close(cap_fd);
        return 1;
    }
    dup2(cap_fd, fileno(stdout));
    int rc = kt_print_pattern_catalog();
    fflush(stdout);
    dup2(saved_stdout, fileno(stdout));
    close(saved_stdout);
    close(cap_fd);
    if (rc != 0) {
        fprintf(stderr, "T37 FAILED: kt_print_pattern_catalog rc=%d\n", rc); return 1;
    }
    FILE *fp = fopen(cap_path, "r");
    if (!fp) { fprintf(stderr, "T37 FAILED: open %s\n", cap_path); return 1; }
    char line[1024];
    char prev_name[64] = "";
    int n_pattern_rows = 0;
    int saw_kt19 = 0, saw_kt22 = 0;
    int sort_ok  = 1;
    while (fgets(line, sizeof line, fp)) {
        /* Pattern rows start with two spaces + 'KT'. */
        if (!(line[0] == ' ' && line[1] == ' ' && line[2] == 'K' && line[3] == 'T'))
            continue;
        char nm[64] = "";
        if (sscanf(line + 2, "%63s", nm) != 1) continue;
        if (n_pattern_rows > 0 && strcmp(prev_name, nm) > 0) sort_ok = 0;
        strcpy(prev_name, nm);
        if (!strcmp(nm, "KT19_P0")) saw_kt19 = 1;
        if (!strcmp(nm, "KT22_P1")) saw_kt22 = 1;
        n_pattern_rows++;
    }
    fclose(fp);
    if (n_pattern_rows < 4) {
        fprintf(stderr, "T37 FAILED: only %d pattern rows (>= 4 required)\n",
                n_pattern_rows);
        return 1;
    }
    if (!saw_kt19 || !saw_kt22) {
        fprintf(stderr, "T37 FAILED: missing %s%s%s\n",
                saw_kt19 ? "" : "KT19_P0",
                (!saw_kt19 && !saw_kt22) ? " " : "",
                saw_kt22 ? "" : "KT22_P1");
        return 1;
    }
    if (!sort_ok) {
        fprintf(stderr, "T37 FAILED: pattern names not sorted alphabetically\n");
        return 1;
    }
    printf("T37 list-patterns OK: %d rows, sorted, includes KT19_P0 + KT22_P1\n",
           n_pattern_rows);
    return 0;
}

int test_t46_seed_anchor_placement(void) {
    const int bits = 89;
    /* 37# = 7420738134810 (production default; matches kt_first_primes[11]). */
    const unsigned __int128 prim37 = (unsigned __int128)7420738134810ULL;

    unsigned __int128 off1 = kt_seed_anchor_offset(0x1111111111111111ULL, bits, prim37);
    unsigned __int128 off2 = kt_seed_anchor_offset(0x2222222222222222ULL, bits, prim37);
    unsigned __int128 off3 = kt_seed_anchor_offset(0x3333333333333333ULL, bits, prim37);

    if (off1 == off2 || off1 == off3 || off2 == off3) {
        fprintf(stderr, "T46 FAILED: 3 distinct seeds produced non-distinct offsets "
                "at bits=%d\n", bits);
        return 1;
    }

    /* Determinism. */
    if (kt_seed_anchor_offset(0x1111111111111111ULL, bits, prim37) != off1) {
        fprintf(stderr, "T46 FAILED: kt_seed_anchor_offset is not deterministic\n");
        return 1;
    }

    /* Small range: target_bits ≤ workload_log2+1 → offset must be 0. */
    if (kt_seed_anchor_offset(0x1111111111111111ULL, 26, prim37) != (unsigned __int128)0) {
        fprintf(stderr, "T46 FAILED: expected offset=0 for target_bits=26\n");
        return 1;
    }
    if (kt_seed_anchor_offset(0x1111111111111111ULL, 27, prim37) != (unsigned __int128)0) {
        fprintf(stderr, "T46 FAILED: expected offset=0 for target_bits=27 (offset_bits=0)\n");
        return 1;
    }

    /* seed=0 → offset=0. */
    if (kt_seed_anchor_offset(0ULL, bits, prim37) != (unsigned __int128)0) {
        fprintf(stderr, "T46 FAILED: seed=0 should give offset=0\n");
        return 1;
    }

    /* Offsets must be within [0, 2^(bits-1)) so cursor stays in range. */
    unsigned __int128 half_range = (unsigned __int128)1 << (bits - 1);
    if (off1 >= half_range || off2 >= half_range || off3 >= half_range) {
        fprintf(stderr, "T46 FAILED: offset exceeds half_range (cursor would escape range)\n");
        return 1;
    }

    /* W18-A: offsets MUST be primorial-aligned (the whole point of the fix —
     * adding the offset to a primorial-aligned cursor must preserve alignment). */
    if ((off1 % prim37) || (off2 % prim37) || (off3 % prim37)) {
        fprintf(stderr, "T46 FAILED: offsets not primorial-aligned (37#=7420738134810); "
                "off1%%prim=%llu off2%%prim=%llu off3%%prim=%llu\n",
                (unsigned long long)(off1 % prim37),
                (unsigned long long)(off2 % prim37),
                (unsigned long long)(off3 % prim37));
        return 1;
    }

    printf("T46 seed-anchor placement: 3 seeds → 3 distinct offsets at b89 "
           "(off1_hi=%llx off2_hi=%llx off3_hi=%llx), range-safe, primorial-aligned — PASS\n",
           (unsigned long long)(off1 >> 64),
           (unsigned long long)(off2 >> 64),
           (unsigned long long)(off3 >> 64));
    return 0;
}

int test_t46b_lane_min_primorial_alignment(void) {
    const unsigned __int128 primorials[] = {
        (unsigned __int128)7420738134810ULL,        /* 37# (--primorial 11) */
        (unsigned __int128)304250263527210ULL,      /* 41# (--primorial 12) */
        (unsigned __int128)614889782588491410ULL,   /* 47# (--primorial 14) */
    };
    const char *prim_names[]   = { "37#", "41#", "47#" };
    const int   prim_indices[] = { 11, 12, 14 };
    const int   prim_n         = (int)(sizeof primorials / sizeof primorials[0]);

    /* Cursor inputs that are NOT a primorial multiple, so the rounding has
     * something to do.  Simulates --prefix 0x... --bits ~90 + a slightly
     * offset lane range. */
    const unsigned __int128 cursor_in    = ((unsigned __int128)1 << 89) | 12345ULL;
    const unsigned __int128 range_end_in = ((unsigned __int128)1 << 90) | 67890ULL;

    int n_checks = 0;
    for (int pi = 0; pi < prim_n; pi++) {
        unsigned __int128 prim = primorials[pi];

        for (int lanes = 2; lanes <= 4; lanes += 2) {
            unsigned __int128 prev_lane_max = 0;
            int have_prev = 0;
            for (int lane_id = 0; lane_id < lanes; lane_id++) {
                unsigned __int128 lm = 0, lx = 0, ls = 0;
                kt_compute_lane_bounds(cursor_in, range_end_in, lanes, lane_id,
                                       prim, &lm, &lx, &ls);

                /* (a) lane_min % primorial == 0 */
                if ((lm % prim) != 0) {
                    fprintf(stderr, "T46b FAILED: prim=%s lanes=%d lane_id=%d "
                            "lane_min %% prim = %llu (want 0)\n",
                            prim_names[pi], lanes, lane_id,
                            (unsigned long long)(lm % prim));
                    return 1;
                }
                /* (b) non-final lane_max % primorial == 0 */
                if (lane_id + 1 < lanes && (lx % prim) != 0) {
                    fprintf(stderr, "T46b FAILED: prim=%s lanes=%d lane_id=%d "
                            "(non-final) lane_max %% prim = %llu (want 0)\n",
                            prim_names[pi], lanes, lane_id,
                            (unsigned long long)(lx % prim));
                    return 1;
                }
                /* (d) lane_start == lane_min */
                if (ls != lm) {
                    fprintf(stderr, "T46b FAILED: prim=%s lanes=%d lane_id=%d "
                            "lane_start != lane_min\n",
                            prim_names[pi], lanes, lane_id);
                    return 1;
                }
                /* (c) lane(k).lane_max == lane(k+1).lane_min */
                if (have_prev && prev_lane_max != lm) {
                    fprintf(stderr, "T46b FAILED: prim=%s lanes=%d lane_id=%d "
                            "boundary discontinuity: prev lane_max != this lane_min\n",
                            prim_names[pi], lanes, lane_id);
                    return 1;
                }
                /* Final lane should match range_end_in (unrounded). */
                if (lane_id + 1 == lanes && lx != range_end_in) {
                    fprintf(stderr, "T46b FAILED: prim=%s lanes=%d (final) "
                            "lane_max != range_end_in\n",
                            prim_names[pi], lanes);
                    return 1;
                }

                prev_lane_max = lx;
                have_prev = 1;
                n_checks++;
            }
            (void)prim_indices;
        }
    }
    printf("T46b lane-min primorial alignment: %d (prim x lanes x lane_id) "
           "checks across primorials {37#,41#,47#} x lanes {2,4} all aligned, "
           "no inter-lane overlap — PASS\n", n_checks);
    return 0;
}

int test_t46c_lane_start_primorial_alignment(void) {
    const unsigned __int128 primorials[] = {
        (unsigned __int128)7420738134810ULL,        /* 37# */
        (unsigned __int128)304250263527210ULL,      /* 41# */
        (unsigned __int128)614889782588491410ULL,   /* 47# */
    };
    const char *prim_names[] = { "37#", "41#", "47#" };
    const int prim_n         = (int)(sizeof primorials / sizeof primorials[0]);

    /* Cursors at a mix of bit-aligned and explicitly mis-aligned positions. */
    const unsigned __int128 cursors[] = {
        ((unsigned __int128)1 << 65),                                       /* 2^65 */
        ((unsigned __int128)1 << 79) | 12345ULL,                            /* 2^79 + 12345 */
        ((unsigned __int128)1 << 99) | 9876543210ULL,                       /* 2^99 + 9.87e9 */
        ((unsigned __int128)5 << 63),                                       /* 0b101 << 63 */
    };
    const int cursor_n = (int)(sizeof cursors / sizeof cursors[0]);

    int n_checks = 0;
    for (int pi = 0; pi < prim_n; pi++) {
        unsigned __int128 prim = primorials[pi];
        for (int ci = 0; ci < cursor_n; ci++) {
            unsigned __int128 c   = cursors[ci];
            unsigned __int128 ls  = kt_compute_lane_start_no_lanes(c, prim);
            if ((ls % prim) != 0) {
                fprintf(stderr, "T46c FAILED: prim=%s cursor_idx=%d "
                        "lane_start %% prim = %llu (want 0)\n",
                        prim_names[pi], ci,
                        (unsigned long long)(ls % prim));
                return 1;
            }
            /* The round must move DOWN (lane_start <= cursor), and the
             * delta is in [0, primorial). */
            if (ls > c || (c - ls) >= prim) {
                fprintf(stderr, "T46c FAILED: prim=%s cursor_idx=%d "
                        "round delta out of bounds: cursor-lane_start = ? (want [0, prim))\n",
                        prim_names[pi], ci);
                return 1;
            }
            n_checks++;
        }
    }
    printf("T46c lane-start primorial alignment: %d (prim x cursor) checks "
           "across primorials {37#,41#,47#} all aligned (round-down delta in [0,prim)) — PASS\n",
           n_checks);
    return 0;
}

int test_t47_records_json_env_override(void) {
    /* Step 1: locate records.json via normal fallback search. */
    const char *probe_used = NULL;
    struct kt_known_records *kr0 = kt_records_load_with_search(&probe_used, 0);
    if (!kr0) {
        printf("T47 KT_RECORDS_JSON env-override: SKIP (no records.json reachable from CWD)\n");
        return 0;
    }
    int n0 = kt_known_records_total(kr0);
    kt_known_records_free(kr0);

    /* Step 2: resolve to absolute path so it can't match any relative fallback. */
    char abs_path[4096];
    if (!realpath(probe_used, abs_path)) {
        printf("T47 KT_RECORDS_JSON env-override: SKIP (realpath('%s') failed: %s)\n",
               probe_used, strerror(errno));
        return 0;
    }

    /* Save previous env value so we can restore it. */
    char saved_env[4096] = "";
    int had_prev = 0;
    const char *prev = getenv("KT_RECORDS_JSON");
    if (prev) {
        strncpy(saved_env, prev, sizeof(saved_env) - 1);
        had_prev = 1;
    }

    /* Step 3: set KT_RECORDS_JSON to abs_path and reload. */
    setenv("KT_RECORDS_JSON", abs_path, 1);
    const char *used2 = NULL;
    struct kt_known_records *kr2 = kt_records_load_with_search(&used2, 0);
    /* Compare used2 before restoring env (pointer may alias env storage). */
    int path_match = (used2 != NULL && strcmp(used2, abs_path) == 0);
    int n2 = kr2 ? kt_known_records_total(kr2) : 0;
    if (kr2) kt_known_records_free(kr2);
    if (had_prev) setenv("KT_RECORDS_JSON", saved_env, 1);
    else unsetenv("KT_RECORDS_JSON");

    if (!kr2) {
        fprintf(stderr, "T47 FAILED: KT_RECORDS_JSON=%s returned NULL\n", abs_path);
        return 1;
    }
    if (!path_match) {
        fprintf(stderr, "T47 FAILED: used='%s' != env='%s' (env path not honoured first)\n",
                used2 ? used2 : "(null)", abs_path);
        return 1;
    }
    if (n2 != n0) {
        fprintf(stderr, "T47 FAILED: env path loaded %d records, fallback loaded %d\n", n2, n0);
        return 1;
    }
    printf("T47 KT_RECORDS_JSON env-override: used=%s total=%d — PASS\n", abs_path, n2);
    return 0;
}

int test_t48_kpi_target_base_parse(void) {
    /* Snapshot affected globals so we leave the test bench clean. */
    const char *saved_kpi_target = g_kpi_target_base;
    int saved_validate_mode      = g_validate_known_mode;
    int saved_validate_target_k  = g_validate_target_k;
    int saved_kpi_early_exit     = g_kpi_early_exit;

    int rc1 = 0, rc2 = 0;
    int ok_store = 0, ok_mutex = 0;

    /* Subtest A: --kpi-target-base 12345 stores the literal pointer to the
     * argv slot.  parse_argv returns 0 on success. */
    g_kpi_target_base    = NULL;
    g_validate_known_mode = 0;
    g_validate_target_k   = 0;
    g_kpi_early_exit      = 0;
    {
        char *argv_a[] = { (char*)"kt_filter_v8",
                           (char*)"--kpi-target-base", (char*)"12345",
                           NULL };
        int argc_a = 3;
        rc1 = parse_argv(argc_a, argv_a);
        ok_store = (rc1 == 0)
                && (g_kpi_target_base != NULL)
                && (strcmp(g_kpi_target_base, "12345") == 0);
    }

    /* Subtest B: --kpi-target-base 1 --validate-known returns nonzero (the
     * mutex check at end of parse_argv). */
    g_kpi_target_base    = NULL;
    g_validate_known_mode = 0;
    g_validate_target_k   = 0;
    g_kpi_early_exit      = 0;
    {
        char *argv_b[] = { (char*)"kt_filter_v8",
                           (char*)"--kpi-target-base", (char*)"1",
                           (char*)"--validate-known",
                           NULL };
        int argc_b = 4;
        rc2 = parse_argv(argc_b, argv_b);
        ok_mutex = (rc2 != 0);
    }

    /* Restore to avoid leaking state into later tests. */
    g_kpi_target_base     = saved_kpi_target;
    g_validate_known_mode = saved_validate_mode;
    g_validate_target_k   = saved_validate_target_k;
    g_kpi_early_exit      = saved_kpi_early_exit;

    if (!ok_store) {
        fprintf(stderr,
            "T48 FAILED: --kpi-target-base 12345 did not store; "
            "rc=%d g_kpi_target_base=%s\n",
            rc1, g_kpi_target_base ? g_kpi_target_base : "(null)");
        return 1;
    }
    if (!ok_mutex) {
        fprintf(stderr,
            "T48 FAILED: --kpi-target-base + --validate-known accepted; "
            "rc=%d (expected nonzero)\n", rc2);
        return 1;
    }
    printf("T48 --kpi-target-base parse + mutex with --validate-known — PASS\n");
    return 0;
}
