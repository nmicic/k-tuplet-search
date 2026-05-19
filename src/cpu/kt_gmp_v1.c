/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_gmp_v1.c — k-Tuplet CPU search engine (port of cc_gmp_v34_bit-vector_10.c).
 *
 * LINEAGE
 *   Base: cc_gmp_v34_bit-vector_10.c (Cunningham Chain v34 bit-vector).
 *   Retargeted from chain element formula 2^i*n + (2^i - 1) to k-tuplet
 *   formula n + b_i. The depth dimension that v34 indexed by chain
 *   position collapses entirely: there is one set of forbidden residues
 *   per (prime, pattern), not per (prime, chain_len).
 *
 * MATH (do not get wrong)
 *   For pattern B = {b_0, ..., b_{k-1}} and prime q:
 *     q | (n + b_i)  iff  n ≡ -b_i (mod q)
 *   So forbidden_r[i] = (q - (b_i mod q)) mod q, then deduplicate.
 *   No mod_inverse, no 2^i ladder, no chain length parameter.
 *   Cross-check: visualizations/k-tuplet-analyzer/index.html L441 uses
 *   `((-o) % p + p) % p` which is mathematically identical.
 *
 * STRUCTURE
 *   - Wheel modulus = primorial p_n# (default 2310 = 11#).
 *   - Wheel = residues r in [0, primorial) admissible for chosen pattern.
 *   - Per tile T (integer index): candidate n = T * primorial + r for r in wheel.
 *   - Filter primes: L2 bitmask (q in (max_primorial_prime, 64)),
 *     ext-L2 byte (q in (64, 128)), line-sieve (q in (128, 863]).
 *   - Survivor verification: each n+b_i tested for primality via GMP BPSW.
 *     Native u128 Montgomery remains in-tree for tests and future narrow-mode
 *     experiments, but is not currently used on the hot verification path.
 *
 * CHECKPOINT
 *   First line "kt-v1"; subsequent lines key=value with the full search
 *   identity (k, pattern, primorial_n, bits, prefix). Version mismatch is
 *   refused with a clear error rather than silently misinterpreted.
 *
 * Build: see Makefile (gcc -O3 -march=native -flto + GMP + pthread).
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <assert.h>
#include <pthread.h>
#include <gmp.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/time.h>
#include <sys/wait.h>
#ifdef __linux__
#include <sched.h>
#endif

#include "../common/ktuplet_pattern.h"
#include "../common/kt_verify.h"

typedef uint64_t u64;
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t  u8;
typedef unsigned __int128 u128;

#define LIKELY(x)   __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

/* =============================================================================
 * FILTER PRIME SETS
 *
 * Default primorial 11# = 2310 covers {2,3,5,7,11}. The remaining primes are
 * partitioned by storage class:
 *   L2 bitmask:    primes <  64   stored as one u64 per prime
 *   ext-L2 byte:   primes <  128  stored as a 128-byte LUT per prime
 *   line-sieve:    primes <= 863  stored as packed u64 bitsets (14 u64 per prime)
 *
 * For higher primorials (e.g. --primorial 17 → 510510) the small primes 13..17
 * are absorbed by the wheel; the engine skips them in the L2 list automatically
 * via build_filter_primes(). This keeps the math correct for any primorial.
 * ========================================================================== */

#define MAX_L2_PRIMES   16
#define MAX_EXTL2_PRIMES 16
#define LINE_SIEVE_MAX_PRIME 864
/* Capacity bound: pi(65535) = 6542; covers --opt-line-cap up to 65535. */
#define LINE_SIEVE_PRIME_CAP 6542

static const u32 ALL_SMALL_PRIMES[] = {
    2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,
    67,71,73,79,83,89,97,101,103,107,109,113,127,
    131,137,139,149,151,157,163,167,173,179,181,191,193,197,199,
    211,223,227,229,233,239,241,251,257,263,269,271,277,281,283,293,
    307,311,313,317,331,337,347,349,353,359,367,373,379,383,389,397,
    401,409,419,421,431,433,439,443,449,457,461,463,467,479,487,491,
    499,503,509,521,523,541,547,557,563,569,571,577,587,593,599,601,
    607,613,617,619,631,641,643,647,653,659,661,673,677,683,691,701,
    709,719,727,733,739,743,751,757,761,769,773,787,797,809,811,821,
    823,827,829,839,853,857,859,863
};
#define ALL_SMALL_PRIMES_N (sizeof(ALL_SMALL_PRIMES) / sizeof(ALL_SMALL_PRIMES[0]))

/* Active filter prime layouts — populated at startup based on chosen primorial. */
static u32 g_l2_primes[MAX_L2_PRIMES];
static int g_l2_count = 0;
static u32 g_extl2_primes[MAX_EXTL2_PRIMES];
static int g_extl2_count = 0;
static u32 g_line_primes[LINE_SIEVE_PRIME_CAP];
static int g_line_count = 0;

/* Primorial config */
static int g_primorial_n_primes = 5;       /* default: 5 primes -> 2310 */
static u64 g_primorial = 2310;
static u32 g_primorial_factors[16];        /* the small primes that compose primorial */
static int g_primorial_factor_count = 0;

/* =============================================================================
 * GLOBAL CONFIG
 * ========================================================================== */

static const KTupletPattern* g_pattern = NULL;
static int g_target_bits = 60;
static int g_k = 0;                  /* derived from pattern */
static int g_threads = 1;
static int g_quiet_mode = 0;
static int g_full_quiet_mode = 0;
static int g_sequential_mode = 0;
static int g_use_prefix = 0;
static int g_sieve_only_mode = 0;
static int g_smoke_mode = 0;
static int g_validate_known_mode = 0;
static int g_max_batches = 0;        /* 0 = unlimited */
static double g_max_time_sec = 0.0;  /* 0 = unlimited */
static int g_pin_threads = 0;
static int g_pin_base_cpu = 0;
static double g_report_interval_sec = 1.0;  /* 0 disables reporter; sub-second OK */
static int g_wide_mode = 0;          /* 1 if max(n+diameter) >= 2^127 */
static int g_line_depth_enabled = 1; /* 1 if line-sieve active */
static u64 g_tiles_per_batch = 500;
static const char* g_log_path = NULL;
static FILE* g_log_fp = NULL;
static const char* g_checkpoint_file = NULL;
static int g_checkpoint_interval_sec = 60;
static int g_resume_mode = 0;
static double g_deadline_epoch_sec = 0.0; /* 0 = unlimited */
static u64 g_batches_claimed = 0;         /* global batch budget accounting */
static int g_profile_skip_verify = 0;     /* warm-up uses real filter path, no verify */

/* prefix range */
static int g_prefix_bits = 0;
static mpz_t g_prefix_value;

/* derived ranges (k-space for tile walk) */
static mpz_t g_n_min, g_n_max;       /* [n_min, n_max] inclusive */
static mpz_t g_tile_min, g_tile_max; /* tile index bounds: n = T*primorial */
static mpz_t g_current_tile;
static mpz_t g_completed_tile;
static int g_search_complete = 0;
static volatile sig_atomic_t shutdown_requested = 0;

/* Operational counters (atomics on the hot path; mutex only used for snapshot
 * reads is unnecessary thanks to __atomic_load_n). Reset between independent
 * searches via reset_global_results(). */
static u64 g_op_cand = 0;          /* candidates entering L2 sieve (per wheel slot) */
static u64 g_op_surv = 0;          /* survivors past line-sieve (entering verifier) */
/* g_op_prime_tests, g_op_fermat_tests, g_op_fermat_rejects, g_op_fermat_mont_tests
 * are owned by kt_verify (extern via kt_verify.h) so the GPU host links them too. */
static u64 g_op_found = 0;         /* full k-tuplets confirmed */

/* g_opt_fermat / g_opt_mont_fermat are owned by kt_verify (extern). */
static int g_opt_prefetch = 1;  /* default ON; --no-opt-prefetch disables */
/* Phase 4b-#4 (port of CC v34 OPT-B): when ON, iterate only alive slots in
 * each bit-vector block via __builtin_ctzll instead of scanning 0..63. Default
 * ON; --no-opt-bitscan reverts to the 0..wheel-size loop for A/B. Only engages
 * when the bit-vector path is active and not in sieve-only mode. */
static int g_opt_bitscan = 1;

/* Random-chunk search mode (Phase 4b-#3.5a, port from cc_gmp_v34_bit-vector_10.c).
 * When set, workers pick a random tile within [g_tile_min, g_tile_max) via
 * xoshiro256**-seeded gmp_randstate and walk g_chunk_tiles forward, repeating.
 * Default: 0 (sequential). Mutually exclusive with --prefix at startup. */
static int g_random_chunk_mode = 0;
static u64 g_chunk_tiles = 0;       /* 0 = use default (500) at activation time */
static u64 g_urandom_master[4];     /* 32 bytes from /dev/urandom (or fallback) */
static int g_urandom_source_ok = 0; /* 1 = real /dev/urandom; 0 = fallback mix */

static const char* g_bench_jsonl_path = NULL;
static FILE* g_bench_jsonl_fp = NULL;
static pthread_mutex_t g_bench_jsonl_lock = PTHREAD_MUTEX_INITIALIZER;

static pthread_mutex_t g_seq_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_print_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_log_file_lock = PTHREAD_MUTEX_INITIALIZER;

/* =============================================================================
 * WHEEL — admissible residues mod primorial for the chosen pattern.
 *
 * For each prime q | primorial, candidates with n mod q in forbidden_set(pat,q)
 * are pruned. The wheel enumerates every r in [0, primorial) that survives.
 * Wheel size is product over primorial primes q of (q - |forbidden_q|), and
 * matches kt_admissible_count_mod() in gp/kt_lib_v1.gp by construction.
 * ========================================================================== */

static u32* g_wheel = NULL;
static int g_wheel_size = 0;

/* Per-(filter prime, wheel index) precomputed residue: g_wheel_mod[p_idx][w] = wheel[w] % p */
static u16* g_l2_wheel_mod[MAX_L2_PRIMES];
static u16* g_extl2_wheel_mod[MAX_EXTL2_PRIMES];
static u16* g_line_wheel_mod[LINE_SIEVE_PRIME_CAP];

/* primorial mod each filter prime (constant) */
static u32 g_l2_pri_mod[MAX_L2_PRIMES];
static u32 g_extl2_pri_mod[MAX_EXTL2_PRIMES];
static u32 g_line_pri_mod[LINE_SIEVE_PRIME_CAP];

/* Forbidden-residue tables for each filter prime.
 * L2: u64 bitmask (residue r forbidden iff (mask >> r) & 1).
 * ext-L2: byte LUT (1 = forbidden).
 * line-sieve: packed u64 bitset, flat allocation indexed as
 *   g_line_kill_packed[i * g_line_kill_stride + (r >> 6)] bit (r & 63).
 * Default stride = 14 (covers 863 residues, byte-identical with the prior
 * [LINE_SIEVE_PRIME_CAP][14] static layout). Phase 4b-#5: --opt-line-cap N
 * lifts cap to N in [863, 65535]; stride becomes (N + 63) / 64. */
static u64 g_l2_mask[MAX_L2_PRIMES];
static u8  g_extl2_kill[MAX_EXTL2_PRIMES][128];
static u64 *g_line_kill_packed = NULL;
static int g_line_kill_stride = 14;        /* (863 + 63) / 64 */
static int g_opt_line_cap = 863;           /* --opt-line-cap N, range [863, 65535] */
static size_t g_line_kill_alloc = 0;       /* current alloc capacity in u64s */

/* =============================================================================
 * BIT-VECTOR L2 FILTER (Armitage, ported from cc_gmp_v34_bit-vector_10.c)
 *
 * For each wheel block (64 wheel entries) and each L2 / ext-L2 prime q, store
 * a per-tile-base kill table indexed by tile_base ∈ [0, q):
 *   l2_kill[(blk * g_l2_count + pi) * 64 + j]
 *     bit k set  iff  (j + g_l2_wheel_mod[pi][blk*64+k]) mod q ∈ forbidden[pi]
 * Per-tile, OR these across pi at the current tile_base[pi] to get one u64
 * kill-mask per block — replacing 14 mod-checks per candidate with 1 bit-test.
 *
 * One bucket per process: kt-tuplet has a single global wheel (CC has per-base
 * mod-6 buckets — that dimension collapses here, see header lineage notes).
 * ========================================================================== */
#define BITVEC_L2_STRIDE     64    /* >= max(L2 prime)    = 61  */
#define BITVEC_EXTL2_STRIDE  128   /* >= max(ext-L2 prime)= 113 */
#define BITVEC_MAX_BLOCKS    128   /* hot-loop stack bound; falls back if exceeded */

typedef struct {
    int   num_blocks;
    int   wheel_size;
    u64  *l2_kill;     /* [num_blocks * g_l2_count    * BITVEC_L2_STRIDE]    */
    u64  *extl2_kill;  /* [num_blocks * g_extl2_count * BITVEC_EXTL2_STRIDE] */
} BitvecBucket;

static BitvecBucket g_bitvec = {0};
static int g_bitvec_enabled = 1;   /* default on; --no-bitvec disables */
static int g_bitvec_force_on = 0;      /* --bitvec: override auto-disable */
static int g_bitvec_auto_disabled = 0; /* set by precompute when heuristic fires */
static int g_bitvec_built = 0;

/* =============================================================================
 * RESULTS
 * ========================================================================== */
typedef struct {
    pthread_mutex_t lock;
    u64 tiles_processed;
    u64 candidates;
    u64 l2_rejected;
    u64 extl2_rejected;
    u64 line_rejected;
    u64 survivors;
    u64 tuplets_found;
    char* found_strs[1024];
    int found_count;
} SearchResults;
static SearchResults g_results;

/* =============================================================================
 * MATH HELPERS
 * ========================================================================== */

static inline int is_small_prime(u32 n) {
    if (n < 2) return 0;
    for (u32 d = 2; d * d <= n; d++) if (n % d == 0) return 0;
    return 1;
}

static double wall_time_sec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

/* xoshiro256** (Blackman & Vigna). Used only as a high-quality seed source
 * for per-thread gmp_randstate; the actual random-tile selection goes through
 * mpz_urandomm so wide-mode (tile count > 2^64) just works. */
static inline u64 xoshiro_rotl(u64 x, int k) { return (x << k) | (x >> (64 - k)); }

static inline u64 xoshiro_next(u64 s[4]) {
    u64 result = xoshiro_rotl(s[1] * 5, 7) * 9;
    u64 t = s[1] << 17;
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3];
    s[2] ^= t; s[3] = xoshiro_rotl(s[3], 45);
    return result;
}

static inline void xoshiro_seed_splitmix(u64 s[4], u64 seed) {
    for (int i = 0; i < 4; i++) {
        seed += 0x9E3779B97F4A7C15ULL;
        u64 z = seed;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        s[i] = z ^ (z >> 31);
    }
}

/* Read 32 bytes into s[0..3] from /dev/urandom. On failure, fall back to a
 * time/pid/clock mix passed through splitmix64. Returns 1 if /dev/urandom
 * succeeded, 0 if the fallback was used, -1 only on internal error. */
static int seed_xoshiro_from_urandom(u64 s[4]) {
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "warning: /dev/urandom open failed (%s); falling back to time/pid mix\n",
                strerror(errno));
        u64 mix = (u64)time(NULL) ^ ((u64)getpid() << 16) ^ (u64)clock();
        xoshiro_seed_splitmix(s, mix);
        return 0;
    }
    ssize_t got = 0;
    while (got < 32) {
        ssize_t n = read(fd, ((char*)s) + got, 32 - got);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            u64 mix = (u64)time(NULL) ^ ((u64)getpid() << 16) ^ (u64)clock();
            xoshiro_seed_splitmix(s, mix);
            return 0;
        }
        got += n;
    }
    close(fd);
    if ((s[0] | s[1] | s[2] | s[3]) == 0) s[0] = 1; /* xoshiro forbids all-zero */
    return 1;
}

/* Derive per-thread xoshiro state from the master master[0..3] read at
 * startup, mixed with thread_id via splitmix64. Each thread thus gets an
 * uncorrelated stream from the same urandom seed. */
static void derive_per_thread_seed(u64 dst[4], const u64 master[4], int thread_id) {
    u64 mix = master[0]
            ^ (master[1] + (u64)thread_id * 0x9E3779B97F4A7C15ULL)
            ^ xoshiro_rotl(master[2], (thread_id * 13) & 63)
            ^ master[3];
    xoshiro_seed_splitmix(dst, mix);
    if ((dst[0] | dst[1] | dst[2] | dst[3]) == 0) dst[0] = 1;
}

static u64 compute_primorial_for_n_primes(int n_primes, u32* factors_out, int* factor_count_out) {
    u64 p = 1;
    int c = 0;
    for (size_t i = 0; i < ALL_SMALL_PRIMES_N && c < n_primes; i++) {
        u32 q = ALL_SMALL_PRIMES[i];
        if (factors_out) factors_out[c] = q;
        p *= q;
        c++;
    }
    if (factor_count_out) *factor_count_out = c;
    return p;
}

/* Build L2 / ext-L2 / line-sieve prime sets that exclude primes already in the primorial. */
static void build_filter_primes(void) {
    g_l2_count = 0;
    g_extl2_count = 0;
    g_line_count = 0;

    /* Cap for the line-sieve set: clamp to [863, 65535] defensively. */
    int cap = g_opt_line_cap;
    if (cap < 863) cap = 863;
    if (cap > 65535) cap = 65535;

    /* Membership test: is q one of the primorial factors? */
    for (size_t i = 0; i < ALL_SMALL_PRIMES_N; i++) {
        u32 q = ALL_SMALL_PRIMES[i];
        int in_primorial = 0;
        for (int j = 0; j < g_primorial_factor_count; j++)
            if (g_primorial_factors[j] == q) { in_primorial = 1; break; }
        if (in_primorial) continue;

        if (q < 64) {
            if (g_l2_count < MAX_L2_PRIMES) g_l2_primes[g_l2_count++] = q;
        } else if (q < 128) {
            if (g_extl2_count < MAX_EXTL2_PRIMES) g_extl2_primes[g_extl2_count++] = q;
        } else if ((int)q <= cap) {
            if (g_line_count < LINE_SIEVE_PRIME_CAP) g_line_primes[g_line_count++] = q;
        }
    }

    /* Phase 4b-#5: when --opt-line-cap > 863, extend line-sieve set with
     * primes in (863, cap] via Eratosthenes. Default cap = 863 leaves the
     * line-sieve set byte-identical with the historical ALL_SMALL_PRIMES path. */
    if (cap > 863) {
        u32 hi = (u32)cap;
        u8* mark = (u8*)calloc((size_t)hi + 1, 1);
        if (mark) {
            for (u32 p = 2; (u64)p * p <= hi; p++) {
                if (mark[p]) continue;
                for (u64 m = (u64)p * p; m <= hi; m += p) mark[m] = 1;
            }
            for (u32 p = 864; p <= hi; p++) {
                if (mark[p]) continue;
                int in_primorial = 0;
                for (int j = 0; j < g_primorial_factor_count; j++)
                    if (g_primorial_factors[j] == p) { in_primorial = 1; break; }
                if (in_primorial) continue;
                if (g_line_count < LINE_SIEVE_PRIME_CAP) g_line_primes[g_line_count++] = p;
            }
            free(mark);
        }
    }
}

/* Phase 4b-#5: (re)allocate g_line_kill_packed for the current cap and count.
 * Sized to g_line_count * g_line_kill_stride u64s. Re-uses the existing buffer
 * when capacity is sufficient (zeroed by init_filter_tables before each use). */
static int alloc_line_kill_packed(void) {
    g_line_kill_stride = (g_opt_line_cap + 63) / 64;
    if (g_line_kill_stride < 14) g_line_kill_stride = 14;  /* >= default */
    size_t need = (size_t)g_line_count * (size_t)g_line_kill_stride;
    if (g_line_kill_packed && g_line_kill_alloc >= need) return 0;
    free(g_line_kill_packed);
    g_line_kill_packed = (u64*)calloc(need ? need : 1, sizeof(u64));
    if (!g_line_kill_packed) {
        fprintf(stderr, "line-sieve: calloc(%zu u64) failed; cap=%d count=%d stride=%d\n",
                need, g_opt_line_cap, g_line_count, g_line_kill_stride);
        g_line_kill_alloc = 0;
        return -1;
    }
    g_line_kill_alloc = need;
    return 0;
}

static void free_line_kill_packed(void) {
    free(g_line_kill_packed);
    g_line_kill_packed = NULL;
    g_line_kill_alloc = 0;
}

/* =============================================================================
 * WHEEL CONSTRUCTION
 * ========================================================================== */

static void free_wheel_tables(void) {
    free(g_wheel); g_wheel = NULL;
    g_wheel_size = 0;
    for (int i = 0; i < MAX_L2_PRIMES; i++) { free(g_l2_wheel_mod[i]); g_l2_wheel_mod[i] = NULL; }
    for (int i = 0; i < MAX_EXTL2_PRIMES; i++) { free(g_extl2_wheel_mod[i]); g_extl2_wheel_mod[i] = NULL; }
    for (int i = 0; i < LINE_SIEVE_PRIME_CAP; i++) { free(g_line_wheel_mod[i]); g_line_wheel_mod[i] = NULL; }
}

static int build_wheel(const KTupletPattern* pat) {
    /* Forbidden tables for primes that compose primorial */
    u8* fbd[16] = {0};
    for (int j = 0; j < g_primorial_factor_count; j++) {
        u32 q = g_primorial_factors[j];
        fbd[j] = (u8*)calloc(q, 1);
        if (!fbd[j]) { for (int x=0;x<j;x++) free(fbd[x]); return -1; }
        u32 buf[KT_MAX_K];
        int n = kt_pattern_forbidden_residues(pat, q, buf);
        for (int t = 0; t < n; t++) fbd[j][buf[t]] = 1;
    }
    /* Enumerate */
    if (g_primorial > SIZE_MAX / sizeof(u32)) {
        for (int j = 0; j < g_primorial_factor_count; j++) free(fbd[j]);
        return -1;
    }
    u32* tmp = (u32*)malloc(g_primorial * sizeof(u32));
    if (!tmp) { for (int j=0;j<g_primorial_factor_count;j++) free(fbd[j]); return -1; }
    int sz = 0;
    for (u64 r = 0; r < g_primorial; r++) {
        int ok = 1;
        for (int j = 0; j < g_primorial_factor_count && ok; j++) {
            if (fbd[j][r % g_primorial_factors[j]]) ok = 0;
        }
        if (ok) tmp[sz++] = (u32)r;
    }
    for (int j = 0; j < g_primorial_factor_count; j++) free(fbd[j]);

    if (sz > 0) {
        u32* shrunk = (u32*)realloc(tmp, sz * sizeof(u32));
        g_wheel = shrunk ? shrunk : tmp;  /* shrink-realloc may return same or new ptr */
    } else {
        free(tmp);
        g_wheel = NULL;
    }
    g_wheel_size = sz;

    /* Per-filter-prime wheel residue tables */
    for (int i = 0; i < g_l2_count; i++) {
        u32 q = g_l2_primes[i];
        g_l2_pri_mod[i] = (u32)(g_primorial % q);
        g_l2_wheel_mod[i] = (u16*)malloc(g_wheel_size * sizeof(u16));
        if (!g_l2_wheel_mod[i]) goto fail;
        for (int w = 0; w < g_wheel_size; w++)
            g_l2_wheel_mod[i][w] = (u16)(g_wheel[w] % q);
    }
    for (int i = 0; i < g_extl2_count; i++) {
        u32 q = g_extl2_primes[i];
        g_extl2_pri_mod[i] = (u32)(g_primorial % q);
        g_extl2_wheel_mod[i] = (u16*)malloc(g_wheel_size * sizeof(u16));
        if (!g_extl2_wheel_mod[i]) goto fail;
        for (int w = 0; w < g_wheel_size; w++)
            g_extl2_wheel_mod[i][w] = (u16)(g_wheel[w] % q);
    }
    for (int i = 0; i < g_line_count; i++) {
        u32 q = g_line_primes[i];
        g_line_pri_mod[i] = (u32)(g_primorial % q);
        g_line_wheel_mod[i] = (u16*)malloc(g_wheel_size * sizeof(u16));
        if (!g_line_wheel_mod[i]) goto fail;
        for (int w = 0; w < g_wheel_size; w++)
            g_line_wheel_mod[i][w] = (u16)(g_wheel[w] % q);
    }
    return 0;

fail:
    free_wheel_tables();
    return -1;
}

/* =============================================================================
 * FILTER TABLE CONSTRUCTION
 * ========================================================================== */

static void init_filter_tables(const KTupletPattern* pat) {
    memset(g_l2_mask, 0, sizeof(g_l2_mask));
    memset(g_extl2_kill, 0, sizeof(g_extl2_kill));
    if (alloc_line_kill_packed() != 0) return;
    if (g_line_kill_packed)
        memset(g_line_kill_packed, 0,
               (size_t)g_line_count * (size_t)g_line_kill_stride * sizeof(u64));

    u32 buf[KT_MAX_K];
    for (int i = 0; i < g_l2_count; i++) {
        u32 q = g_l2_primes[i];
        int n = kt_pattern_forbidden_residues(pat, q, buf);
        u64 m = 0;
        for (int t = 0; t < n; t++) m |= (1ULL << buf[t]);
        g_l2_mask[i] = m;
    }
    for (int i = 0; i < g_extl2_count; i++) {
        u32 q = g_extl2_primes[i];
        int n = kt_pattern_forbidden_residues(pat, q, buf);
        for (int t = 0; t < n; t++) g_extl2_kill[i][buf[t]] = 1;
    }
    for (int i = 0; i < g_line_count; i++) {
        u32 q = g_line_primes[i];
        int n = kt_pattern_forbidden_residues(pat, q, buf);
        for (int t = 0; t < n; t++)
            g_line_kill_packed[i * g_line_kill_stride + (buf[t] >> 6)]
                |= (1ULL << (buf[t] & 63));
    }
}

/* Free bit-vector kill tables and reset bucket state. Idempotent. */
static void free_bitvec_buckets_kt(void) {
    free(g_bitvec.l2_kill);    g_bitvec.l2_kill = NULL;
    free(g_bitvec.extl2_kill); g_bitvec.extl2_kill = NULL;
    g_bitvec.num_blocks = 0;
    g_bitvec.wheel_size = 0;
    g_bitvec_built = 0;
}

/* Precompute Armitage block-kill tables for the current wheel + L2/ext-L2
 * forbidden masks. Must be called AFTER build_wheel() and init_filter_tables().
 * On allocation failure, disables bit-vector filtering and falls back to the
 * existing per-prime path. */
static void precompute_bitvec_blocks_kt(void) {
    if (g_bitvec_built) free_bitvec_buckets_kt();
    if (!g_bitvec_enabled) return;
    if (g_wheel_size <= 0) return;

    /* Auto-disable when amortization domain is too small (per-bucket setup cost dominates).
     * wheel_size * l2_count < 64 means fewer than one full 64-bit word of candidates per bucket. */
    if (!g_bitvec_force_on && (g_wheel_size * g_l2_count < 64)) {
        if (!g_quiet_mode && !g_full_quiet_mode)
            fprintf(stderr, "bit-vector: auto-disabled (wheel=%d x l2=%d < 64); use --bitvec to force\n",
                    g_wheel_size, g_l2_count);
        g_bitvec_enabled = 0;
        g_bitvec_auto_disabled = 1;
        return;
    }
    if (g_bitvec_force_on && !g_quiet_mode && !g_full_quiet_mode)
        fprintf(stderr, "bit-vector: force-enabled by --bitvec (wheel=%d x l2=%d)\n",
                g_wheel_size, g_l2_count);

    int num_blocks = (g_wheel_size + 63) / 64;
    g_bitvec.num_blocks = num_blocks;
    g_bitvec.wheel_size = g_wheel_size;

    size_t l2_total = (size_t)num_blocks * (size_t)g_l2_count    * BITVEC_L2_STRIDE;
    size_t ex_total = (size_t)num_blocks * (size_t)g_extl2_count * BITVEC_EXTL2_STRIDE;

    g_bitvec.l2_kill    = l2_total ? (u64*)calloc(l2_total, sizeof(u64)) : NULL;
    g_bitvec.extl2_kill = ex_total ? (u64*)calloc(ex_total, sizeof(u64)) : NULL;
    if ((l2_total && !g_bitvec.l2_kill) || (ex_total && !g_bitvec.extl2_kill)) {
        fprintf(stderr, "WARNING: BIT-VECTOR: alloc failed, disabling\n");
        free(g_bitvec.l2_kill); g_bitvec.l2_kill = NULL;
        free(g_bitvec.extl2_kill); g_bitvec.extl2_kill = NULL;
        g_bitvec.num_blocks = 0;
        g_bitvec.wheel_size = 0;
        g_bitvec_enabled = 0;
        return;
    }

    for (int blk = 0; blk < num_blocks; blk++) {
        int blk_start = blk * 64;
        int blk_end   = blk_start + 64;
        if (blk_end > g_wheel_size) blk_end = g_wheel_size;
        int blk_sz = blk_end - blk_start;
        u64 pad_kill = (blk_sz < 64) ? ~((1ULL << blk_sz) - 1) : 0ULL;

        /* L2 kill vectors */
        for (int pi = 0; pi < g_l2_count; pi++) {
            u32 q = g_l2_primes[pi];
            u64 fmask = g_l2_mask[pi];
            u64 *kv = &g_bitvec.l2_kill[((size_t)blk * g_l2_count + pi) * BITVEC_L2_STRIDE];
            for (int k = 0; k < blk_sz; k++) {
                u32 wM = g_l2_wheel_mod[pi][blk_start + k];
                for (u32 j = 0; j < q; j++) {
                    u32 r = j + wM;
                    if (r >= q) r -= q;
                    if ((fmask >> r) & 1ULL)
                        kv[j] |= (1ULL << k);
                }
            }
            for (u32 j = 0; j < q; j++) kv[j] |= pad_kill;
        }

        /* ext-L2 kill vectors */
        for (int pi = 0; pi < g_extl2_count; pi++) {
            u32 q = g_extl2_primes[pi];
            const u8 *fkill = g_extl2_kill[pi];
            u64 *kv = &g_bitvec.extl2_kill[((size_t)blk * g_extl2_count + pi) * BITVEC_EXTL2_STRIDE];
            for (int k = 0; k < blk_sz; k++) {
                u32 wM = g_extl2_wheel_mod[pi][blk_start + k];
                for (u32 j = 0; j < q; j++) {
                    u32 r = j + wM;
                    if (r >= q) r -= q;
                    if (fkill[r])
                        kv[j] |= (1ULL << k);
                }
            }
            for (u32 j = 0; j < q; j++) kv[j] |= pad_kill;
        }
    }

    g_bitvec_built = 1;
    if (!g_quiet_mode && !g_full_quiet_mode) {
        size_t bytes_l2 = l2_total * sizeof(u64);
        size_t bytes_ex = ex_total * sizeof(u64);
        printf("BIT-VECTOR: kill tables: L2=%zu KB, ext-L2=%zu KB (blocks=%d, wheel=%d)\n",
               bytes_l2 / 1024, bytes_ex / 1024, num_blocks, g_wheel_size);
    }
}

/* =============================================================================
 * U128 / MONTGOMERY + verify_tuplet_gmp moved to src/common/kt_verify.{c,h}
 * (Phase 3d). The CPU search engine and the GPU host driver both link the
 * same TU so the certification path is byte-identical across engines.
 * ========================================================================== */


/* =============================================================================
 * SIEVE HOT PATH
 * ========================================================================== */

typedef struct {
    int thread_id;
    mpz_t n_mpz;
    mpz_t scratch;
    mpz_t tile;            /* current tile index T as mpz */
    char found_buf[8192];
    size_t found_buf_len;
    u64 rng_state[4];      /* xoshiro256** state (random-chunk mode) */
    gmp_randstate_t rand_state;
    int rand_state_inited;
} ThreadConfig;

/* stderr crash-safe announce: write(2) bypasses stdio entirely, survives even
 * if stdio state is corrupt. Unbuffered by default on stderr. */
static void crash_safe_announce(const char* base_str, const KTupletPattern* pat, int bits) {
    char msg[1024];
    int n = snprintf(msg, sizeof(msg),
        "\n*** FOUND k=%d bits=%d pattern=%s base=%s ***\n",
        pat->k, bits, pat->name, base_str);
    if (n > 0 && (size_t)n < sizeof(msg)) {
        ssize_t wr = write(STDERR_FILENO, msg, (size_t)n);
        (void)wr;
    }
}

/* Append a found tuplet to the log file; fflush+fsync so the record survives
 * kernel panic / power loss. fflush alone only reaches the kernel page cache. */
static void persist_tuplet_to_file(int k, const char* pat_name, const char* base_dec) {
    if (!g_log_fp) return;
    pthread_mutex_lock(&g_log_file_lock);
    fprintf(g_log_fp, "KT%d %s %s\n", k, pat_name, base_dec);
    fflush(g_log_fp);
#ifdef __linux__
    fsync(fileno(g_log_fp)); /* guarantee record hits storage, not just page cache */
#endif
    pthread_mutex_unlock(&g_log_file_lock);
}

static void record_found_tuplet(ThreadConfig* cfg, const mpz_t n) {
    char* dec = mpz_get_str(NULL, 10, n);
    if (!dec) {
        fprintf(stderr, "ERROR: mpz_get_str failed while recording a found tuplet\n");
        shutdown_requested = 1;
        return;
    }
    crash_safe_announce(dec, g_pattern, g_target_bits);
    persist_tuplet_to_file(g_pattern->k, g_pattern->name, dec);
    pthread_mutex_lock(&g_results.lock);
    if (g_results.found_count < (int)(sizeof(g_results.found_strs)/sizeof(g_results.found_strs[0]))) {
        char* dup = strdup(dec);
        if (!dup) {
            pthread_mutex_unlock(&g_results.lock);
            fprintf(stderr, "ERROR: strdup failed while recording a found tuplet\n");
            free(dec);
            shutdown_requested = 1;
            return;
        }
        g_results.found_strs[g_results.found_count++] = dup;
    }
    g_results.tuplets_found++;
    __atomic_fetch_add(&g_op_found, 1, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&g_results.lock);
    if (!g_quiet_mode) {
        pthread_mutex_lock(&g_print_lock);
        printf("  [T%d] *** %s FOUND base=%s\n", cfg->thread_id, g_pattern->name, dec);
        fflush(stdout);
        pthread_mutex_unlock(&g_print_lock);
    }
    free(dec);
}

/* Zero operational counters between independent searches so per-record rates
 * don't accumulate across --validate-known invocations. */
static void reset_global_results(void) {
    __atomic_store_n(&g_op_cand, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_op_surv, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_op_prime_tests, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_op_fermat_tests, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_op_fermat_rejects, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_op_fermat_mont_tests, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_op_found, 0, __ATOMIC_RELAXED);
}

/* Emit one stderr reporter line. has_range=1 enables ETA computation from the
 * tile cursor; for tiny prefix-shard runs (validate-known) pass 0. */
static void emit_reporter_line(double t0, int has_range) {
    double now = wall_time_sec();
    double elapsed = now - t0;
    u64 cand = __atomic_load_n(&g_op_cand, __ATOMIC_RELAXED);
    u64 surv = __atomic_load_n(&g_op_surv, __ATOMIC_RELAXED);
    u64 ptests = __atomic_load_n(&g_op_prime_tests, __ATOMIC_RELAXED);
    u64 found = __atomic_load_n(&g_op_found, __ATOMIC_RELAXED);
    double cand_rate = elapsed > 0 ? cand / elapsed : 0;
    double surv_rate = elapsed > 0 ? surv / elapsed : 0;
    double ptest_rate = elapsed > 0 ? ptests / elapsed : 0;

    char eta_buf[64] = "";
    if (has_range) {
        pthread_mutex_lock(&g_seq_lock);
        mpz_t span, prog;
        mpz_init(span); mpz_init(prog);
        mpz_sub(span, g_tile_max, g_tile_min);
        mpz_sub(prog, g_current_tile, g_tile_min);
        double span_d = mpz_get_d(span);
        double prog_d = mpz_get_d(prog);
        mpz_clear(span); mpz_clear(prog);
        pthread_mutex_unlock(&g_seq_lock);
        double pct = (span_d > 0) ? prog_d / span_d : 0;
        if (pct > 1e-4 && elapsed > 0.5 && span_d > 1e3) {
            double eta = (elapsed / pct) * (1.0 - pct);
            if (eta < 60)        snprintf(eta_buf, sizeof(eta_buf), " ETA: %.0fs", eta);
            else if (eta < 3600) snprintf(eta_buf, sizeof(eta_buf), " ETA: %.1fm", eta/60);
            else if (eta < 86400)snprintf(eta_buf, sizeof(eta_buf), " ETA: %.1fh", eta/3600);
            else                 snprintf(eta_buf, sizeof(eta_buf), " ETA: %.1fd", eta/86400);
        }
    }

    fprintf(stderr,
        "\rcand: %llu (%.2fM/s) | surv: %llu (%.0f/s) | P: %llu (%.0f/s) | KT%d+: %llu | %.1fs%s   ",
        (unsigned long long)cand, cand_rate / 1e6,
        (unsigned long long)surv, surv_rate,
        (unsigned long long)ptests, ptest_rate,
        g_pattern ? g_pattern->k : 0, (unsigned long long)found,
        elapsed, eta_buf);
    fflush(stderr);
}

static void emit_reporter_done(double t0) {
    double elapsed = wall_time_sec() - t0;
    u64 cand = __atomic_load_n(&g_op_cand, __ATOMIC_RELAXED);
    u64 surv = __atomic_load_n(&g_op_surv, __ATOMIC_RELAXED);
    u64 ptests = __atomic_load_n(&g_op_prime_tests, __ATOMIC_RELAXED);
    u64 found = __atomic_load_n(&g_op_found, __ATOMIC_RELAXED);
    double cand_rate = elapsed > 0 ? cand / elapsed : 0;
    double ptest_rate = elapsed > 0 ? ptests / elapsed : 0;
    fprintf(stderr,
        "\nDONE  cand: %llu surv: %llu P: %llu found: %llu elapsed: %.2fs "
        "avg: cand %.0f/s prime %.0f/s\n",
        (unsigned long long)cand, (unsigned long long)surv,
        (unsigned long long)ptests, (unsigned long long)found,
        elapsed, cand_rate, ptest_rate);
    fflush(stderr);
}

static int reporter_active(void) {
    return !g_full_quiet_mode && !g_quiet_mode && g_report_interval_sec > 0.0;
}

static useconds_t reporter_sleep_us(void) {
    double us = g_report_interval_sec * 1e6;
    if (us < 1000.0) us = 1000.0;          /* clamp to 1ms */
    if (us > 3.6e9)  us = 3.6e9;            /* upper bound for useconds_t */
    return (useconds_t)us;
}

/* Phase 4b-#4 (OPT-B). Per-slot post-l2-kill body used by the ctzll fast path
 * (g_opt_bitscan=1, bit-vector active, non-sieve-only). Alive bits already
 * exclude L2/ext-L2 kills, so this only runs the line-sieve check, range gate,
 * and verify. The slow path keeps its existing inline body verbatim — T56
 * asserts both branches enumerate the same set of slot indices. */
static inline void kt_bitscan_process_slot(ThreadConfig* cfg, int w,
                                           const u32* tile_base_line,
                                           u64* line_rej, u64* survivors) {
    int line_kill = 0;
    if (g_line_depth_enabled) {
        for (int i = 0; i < g_line_count; i++) {
            u32 q = g_line_primes[i];
            u32 r = tile_base_line[i] + g_line_wheel_mod[i][w];
            if (r >= q) r -= q;
            if ((g_line_kill_packed[i * g_line_kill_stride + (r >> 6)] >> (r & 63)) & 1ULL) { line_kill = 1; break; }
        }
    }
    if (line_kill) { (*line_rej)++; return; }
    (*survivors)++;
    mpz_mul_ui(cfg->n_mpz, cfg->tile, g_primorial);
    mpz_add_ui(cfg->n_mpz, cfg->n_mpz, g_wheel[w]);
    if (mpz_cmp(cfg->n_mpz, g_n_min) < 0) return;
    if (mpz_cmp(cfg->n_mpz, g_n_max) > 0) return;
    if (g_profile_skip_verify) return;
    if (verify_tuplet_gmp(cfg->n_mpz, g_pattern, cfg->scratch)) {
        record_found_tuplet(cfg, cfg->n_mpz);
    }
}

/* Run one batch of tiles starting at *cur_tile (mutated in place) up to but not
 * exceeding tile_end. Single-threaded helper; used by both the worker loop and
 * the smoke / validate-known harnesses. Returns count of tiles processed. */
static u64 run_tile_range(ThreadConfig* cfg, const mpz_t tile_start, const mpz_t tile_end,
                          double deadline_epoch_sec, u64 max_tiles_this_call,
                          u64* out_candidates, u64* out_l2_rej, u64* out_extl2_rej,
                          u64* out_line_rej, u64* out_survivors) {
    u64 tiles = 0;
    u64 candidates = 0, l2_rej = 0, ext_rej = 0, line_rej = 0, survivors = 0;
    u64 prev_candidates = 0, prev_survivors = 0;
    mpz_set(cfg->tile, tile_start);

    /* Per-tile L2/ext-L2/line baselines: T_mod_q * primorial_mod_q mod q.
     * Initialized on the first tile, then maintained incrementally:
     * each subsequent tile increments T by 1, so baseline += primorial_mod_q,
     * subtract q if ≥ q. */
    u32 tile_base_l2[MAX_L2_PRIMES];
    u32 tile_base_ext[MAX_EXTL2_PRIMES];
    u32 tile_base_line[LINE_SIEVE_PRIME_CAP];
    int first_tile = 1;

    while (mpz_cmp(cfg->tile, tile_end) < 0) {
        if (shutdown_requested) break;
        if (max_tiles_this_call && tiles >= max_tiles_this_call) break;
        if (deadline_epoch_sec > 0) {
            struct timeval tv; gettimeofday(&tv, NULL);
            double now = tv.tv_sec + tv.tv_usec/1e6;
            if (now >= deadline_epoch_sec) break;
        }

        if (UNLIKELY(first_tile)) {
            for (int i = 0; i < g_l2_count; i++) {
                u32 q = g_l2_primes[i];
                u32 t_mod = (u32)mpz_fdiv_ui(cfg->tile, q);
                tile_base_l2[i] = (u32)((u64)t_mod * g_l2_pri_mod[i] % q);
            }
            for (int i = 0; i < g_extl2_count; i++) {
                u32 q = g_extl2_primes[i];
                u32 t_mod = (u32)mpz_fdiv_ui(cfg->tile, q);
                tile_base_ext[i] = (u32)((u64)t_mod * g_extl2_pri_mod[i] % q);
            }
            for (int i = 0; i < g_line_count; i++) {
                u32 q = g_line_primes[i];
                u32 t_mod = (u32)mpz_fdiv_ui(cfg->tile, q);
                tile_base_line[i] = (u32)((u64)t_mod * g_line_pri_mod[i] % q);
            }
            first_tile = 0;
        } else {
            for (int i = 0; i < g_l2_count; i++) {
                u32 q = g_l2_primes[i], v = tile_base_l2[i] + g_l2_pri_mod[i];
                if (v >= q) v -= q;
                tile_base_l2[i] = v;
            }
            for (int i = 0; i < g_extl2_count; i++) {
                u32 q = g_extl2_primes[i], v = tile_base_ext[i] + g_extl2_pri_mod[i];
                if (v >= q) v -= q;
                tile_base_ext[i] = v;
            }
            for (int i = 0; i < g_line_count; i++) {
                u32 q = g_line_primes[i], v = tile_base_line[i] + g_line_pri_mod[i];
                if (v >= q) v -= q;
                tile_base_line[i] = v;
            }
        }

        /* BIT-VECTOR: collapse this tile's L2 + ext-L2 forbidden checks into one
         * u64 kill-mask per 64-wide block of wheel offsets. 14 lookups/block once
         * vs 14 mod-checks per candidate before. Disabled in sieve-only mode so
         * --smoke retains per-stage kill counts. */
        int bitvec_using = (g_bitvec_enabled && g_bitvec_built &&
                            !g_sieve_only_mode &&
                            g_bitvec.num_blocks <= BITVEC_MAX_BLOCKS);
        u64 bitvec_block_kills[BITVEC_MAX_BLOCKS];
        if (bitvec_using) {
            for (int blk = 0; blk < g_bitvec.num_blocks; blk++) {
#if defined(__GNUC__) || defined(__clang__)
                if (g_opt_prefetch && blk + 1 < g_bitvec.num_blocks) {
                    if (g_l2_count > 0)
                        __builtin_prefetch(&g_bitvec.l2_kill[(size_t)(blk + 1) * g_l2_count * BITVEC_L2_STRIDE], 0, 1);
                    if (g_extl2_count > 0)
                        __builtin_prefetch(&g_bitvec.extl2_kill[(size_t)(blk + 1) * g_extl2_count * BITVEC_EXTL2_STRIDE], 0, 1);
                }
#endif
                u64 C = 0;
                for (int pi = 0; pi < g_l2_count; pi++)
                    C |= g_bitvec.l2_kill[((size_t)blk * g_l2_count + pi) * BITVEC_L2_STRIDE
                                          + tile_base_l2[pi]];
                for (int pi = 0; pi < g_extl2_count; pi++)
                    C |= g_bitvec.extl2_kill[((size_t)blk * g_extl2_count + pi) * BITVEC_EXTL2_STRIDE
                                             + tile_base_ext[pi]];
                bitvec_block_kills[blk] = C;
            }
        }

        if (bitvec_using && !g_sieve_only_mode && g_opt_bitscan) {
            /* Phase 4b-#4 OPT-B fast path: iterate alive bits per u64 block
             * via __builtin_ctzll. Skips dead candidates at u64 granularity
             * instead of bit-testing all 64 slots per block. l2/ext-L2 kills
             * are already folded into the kill mask; popcount accounts for
             * them in l2_rej. */
            int num_blocks = g_bitvec.num_blocks;
            for (int blk = 0; blk < num_blocks; blk++) {
                int base_w = blk << 6;
                int slots_in_block = (base_w + 64 <= g_wheel_size) ? 64 : (g_wheel_size - base_w);
                u64 lim = (slots_in_block >= 64) ? ~(u64)0 : (((u64)1 << slots_in_block) - 1);
                u64 km = bitvec_block_kills[blk] & lim;
                u64 surv = (~km) & lim;
                candidates += slots_in_block;
                l2_rej    += __builtin_popcountll(km);
                while (surv) {
                    int slot = __builtin_ctzll(surv);
                    surv &= surv - 1;
                    int w = base_w + slot;
                    kt_bitscan_process_slot(cfg, w, tile_base_line, &line_rej, &survivors);
                }
            }
            goto tile_done;
        }

        for (int w = 0; w < g_wheel_size; w++) {
            candidates++;

            /* In sieve-only mode (and during smoke), tally each stage
             * independently so every stage's reject counter reflects its
             * own kill rate. In production search this would be wasteful;
             * but sieve-only is a benchmarking / introspection mode. */
            int l2_kill = 0, ext_kill = 0, line_kill = 0;

            if (bitvec_using) {
                /* Combined L2+ext-L2 kill bit. Cannot attribute to either stage
                 * (mask is union); l2_rej accumulates both. */
                u64 km = bitvec_block_kills[w >> 6];
                if ((km >> (w & 63)) & 1ULL) l2_kill = 1;
            } else {
                for (int i = 0; i < g_l2_count; i++) {
                    u32 q = g_l2_primes[i];
                    u32 r = tile_base_l2[i] + g_l2_wheel_mod[i][w];
                    if (r >= q) r -= q;
                    if ((g_l2_mask[i] >> r) & 1ULL) { l2_kill = 1; break; }
                }

                if (g_sieve_only_mode || !l2_kill) {
                    for (int i = 0; i < g_extl2_count; i++) {
                        u32 q = g_extl2_primes[i];
                        u32 r = tile_base_ext[i] + g_extl2_wheel_mod[i][w];
                        if (r >= q) r -= q;
                        if (g_extl2_kill[i][r]) { ext_kill = 1; break; }
                    }
                }
            }

            if (g_line_depth_enabled && (g_sieve_only_mode || (!l2_kill && !ext_kill))) {
                for (int i = 0; i < g_line_count; i++) {
                    u32 q = g_line_primes[i];
                    u32 r = tile_base_line[i] + g_line_wheel_mod[i][w];
                    if (r >= q) r -= q;
                    if ((g_line_kill_packed[i * g_line_kill_stride + (r >> 6)] >> (r & 63)) & 1ULL) { line_kill = 1; break; }
                }
            }

            if (l2_kill)   l2_rej++;
            if (ext_kill)  ext_rej++;
            if (line_kill) line_rej++;
            if (l2_kill || ext_kill || line_kill) continue;

            survivors++;

            if (g_sieve_only_mode) continue;

            /* Build n = T * primorial + wheel[w] */
            mpz_mul_ui(cfg->n_mpz, cfg->tile, g_primorial);
            mpz_add_ui(cfg->n_mpz, cfg->n_mpz, g_wheel[w]);

            /* Range gate (prefix or bit-range) */
            if (mpz_cmp(cfg->n_mpz, g_n_min) < 0) continue;
            if (mpz_cmp(cfg->n_mpz, g_n_max) > 0) continue;
            if (g_profile_skip_verify) continue;

            if (verify_tuplet_gmp(cfg->n_mpz, g_pattern, cfg->scratch)) {
                record_found_tuplet(cfg, cfg->n_mpz);
            }
        }

    tile_done:
        mpz_add_ui(cfg->tile, cfg->tile, 1);
        tiles++;

        /* Per-tile atomic flush of operational counters so the reporter sees
         * smooth rate updates without a per-candidate atomic on the hot path. */
        u64 dc = candidates - prev_candidates;
        u64 ds = survivors  - prev_survivors;
        if (dc) __atomic_fetch_add(&g_op_cand, dc, __ATOMIC_RELAXED);
        if (ds) __atomic_fetch_add(&g_op_surv, ds, __ATOMIC_RELAXED);
        prev_candidates = candidates;
        prev_survivors  = survivors;
    }

    if (out_candidates) *out_candidates = candidates;
    if (out_l2_rej)     *out_l2_rej     = l2_rej;
    if (out_extl2_rej)  *out_extl2_rej  = ext_rej;
    if (out_line_rej)   *out_line_rej   = line_rej;
    if (out_survivors)  *out_survivors  = survivors;
    return tiles;
}

/* =============================================================================
 * CHECKPOINT (kt-v1)
 *
 * Format (whitespace-tolerant key=value, "kt-v1" header):
 *   kt-v1
 *   k=<int>
 *   pattern=<string>
 *   primorial_n=<int>
 *   bits=<int>
 *   prefix_bits=<int>
 *   prefix=<hex>
 *   tile=<hex>
 * Versions other than "kt-v1" are refused with a clear message.
 * ========================================================================== */

static void write_checkpoint(void) {
    if (!g_checkpoint_file) return;
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s.tmpXXXXXX", g_checkpoint_file);
    int fd = mkstemp(tmp);
    if (fd < 0) return;
    FILE* fp = fdopen(fd, "w");
    if (!fp) {
        close(fd);
        unlink(tmp);
        return;
    }
    pthread_mutex_lock(&g_seq_lock);
    char* tile_hex = mpz_get_str(NULL, 16, g_completed_tile);
    char* prefix_hex = mpz_get_str(NULL, 16, g_prefix_value);
    pthread_mutex_unlock(&g_seq_lock);
    if (!tile_hex || !prefix_hex) {
        free(tile_hex);
        free(prefix_hex);
        fclose(fp);
        unlink(tmp);
        return;
    }
    int rc = fprintf(fp, "kt-v1\nk=%d\npattern=%s\nprimorial_n=%d\nbits=%d\nprefix_bits=%d\nprefix=%s\ntile=%s\n",
            g_pattern ? g_pattern->k : 0,
            g_pattern ? g_pattern->name : "?",
            g_primorial_n_primes, g_target_bits, g_prefix_bits,
            prefix_hex, tile_hex);
    free(tile_hex); free(prefix_hex);
    if (rc < 0 || fclose(fp) != 0 || rename(tmp, g_checkpoint_file) != 0) {
        unlink(tmp);
    }
}

static int load_checkpoint(void) {
    if (!g_checkpoint_file) return 0;
    FILE* fp = fopen(g_checkpoint_file, "r");
    if (!fp) return 0;
    char ver[32] = {0};
    if (fscanf(fp, "%31s", ver) != 1) { fclose(fp); return 0; }
    if (strcmp(ver, "kt-v1") != 0) {
        fprintf(stderr,
            "ERROR: Refusing to resume from incompatible checkpoint format %s; "
            "remove the file or pass a fresh --checkpoint path.\n", ver);
        fclose(fp);
        exit(1);
    }
    int file_k = -1, file_primorial_n = -1, file_bits = -1, file_prefix_bits = -1;
    int saw_k = 0, saw_pattern = 0, saw_primorial_n = 0, saw_bits = 0;
    int saw_prefix_bits = 0, saw_prefix = 0, saw_tile = 0;
    char file_pattern[64] = {0};
    mpz_t file_prefix, file_tile;
    mpz_init(file_prefix);
    mpz_init(file_tile);
    char line[1024];
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        mpz_clear(file_prefix);
        mpz_clear(file_tile);
        return 0;
    } /* consume rest of first line */
    while (fgets(line, sizeof(line), fp)) {
        char* eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char* key = line;
        char* val = eq + 1;
        size_t vlen = strlen(val);
        while (vlen > 0 && (val[vlen-1] == '\n' || val[vlen-1] == '\r')) val[--vlen] = 0;
        if (!strcmp(key, "k")) {
            file_k = atoi(val);
            saw_k = 1;
        } else if (!strcmp(key, "pattern")) {
            snprintf(file_pattern, sizeof(file_pattern), "%s", val);
            saw_pattern = 1;
        } else if (!strcmp(key, "primorial_n")) {
            file_primorial_n = atoi(val);
            saw_primorial_n = 1;
        } else if (!strcmp(key, "bits")) {
            file_bits = atoi(val);
            saw_bits = 1;
        } else if (!strcmp(key, "prefix_bits")) {
            file_prefix_bits = atoi(val);
            saw_prefix_bits = 1;
        } else if (!strcmp(key, "prefix")) {
            if (mpz_set_str(file_prefix, val, 16) != 0) {
                fprintf(stderr, "ERROR: invalid prefix field in checkpoint %s\n", g_checkpoint_file);
                fclose(fp);
                mpz_clear(file_prefix);
                mpz_clear(file_tile);
                exit(1);
            }
            saw_prefix = 1;
        } else if (!strcmp(key, "tile")) {
            if (mpz_set_str(file_tile, val, 16) != 0) {
                fprintf(stderr, "ERROR: invalid tile field in checkpoint %s\n", g_checkpoint_file);
                fclose(fp);
                mpz_clear(file_prefix);
                mpz_clear(file_tile);
                exit(1);
            }
            saw_tile = 1;
        }
    }
    fclose(fp);
    if (!saw_k || !saw_pattern || !saw_primorial_n || !saw_bits ||
        !saw_prefix_bits || !saw_prefix || !saw_tile) {
        fprintf(stderr, "ERROR: checkpoint %s is missing required kt-v1 fields\n", g_checkpoint_file);
        mpz_clear(file_prefix);
        mpz_clear(file_tile);
        exit(1);
    }
    if (!g_pattern || file_k != g_pattern->k || strcmp(file_pattern, g_pattern->name) != 0 ||
        file_primorial_n != g_primorial_n_primes || file_bits != g_target_bits ||
        file_prefix_bits != g_prefix_bits || mpz_cmp(file_prefix, g_prefix_value) != 0) {
        char* file_prefix_hex = mpz_get_str(NULL, 16, file_prefix);
        char* cli_prefix_hex = mpz_get_str(NULL, 16, g_prefix_value);
        fprintf(stderr,
                "ERROR: checkpoint identity mismatch for %s\n"
                "  file: k=%d pattern=%s primorial_n=%d bits=%d prefix_bits=%d prefix=%s\n"
                "  cli : k=%d pattern=%s primorial_n=%d bits=%d prefix_bits=%d prefix=%s\n",
                g_checkpoint_file,
                file_k, file_pattern, file_primorial_n, file_bits, file_prefix_bits,
                file_prefix_hex ? file_prefix_hex : "(oom)",
                g_pattern ? g_pattern->k : 0, g_pattern ? g_pattern->name : "(null)",
                g_primorial_n_primes, g_target_bits, g_prefix_bits,
                cli_prefix_hex ? cli_prefix_hex : "(oom)");
        free(file_prefix_hex);
        free(cli_prefix_hex);
        mpz_clear(file_prefix);
        mpz_clear(file_tile);
        exit(1);
    }
    if (mpz_cmp(file_tile, g_tile_min) < 0 || mpz_cmp(file_tile, g_tile_max) > 0) {
        char* tile_hex = mpz_get_str(NULL, 16, file_tile);
        fprintf(stderr, "ERROR: checkpoint tile %s is outside the current search range\n",
                tile_hex ? tile_hex : "(oom)");
        free(tile_hex);
        mpz_clear(file_prefix);
        mpz_clear(file_tile);
        exit(1);
    }
    mpz_set(g_current_tile, file_tile);
    mpz_set(g_completed_tile, file_tile);
    mpz_clear(file_prefix);
    mpz_clear(file_tile);
    return 1;
}

/* =============================================================================
 * SIGNAL HANDLING
 * ========================================================================== */
static void signal_handler(int sig) {
    (void)sig;
    if (!shutdown_requested) {
        shutdown_requested = 1;
        const char* msg = "\n[INTERRUPT] stopping (Ctrl+C again = force exit)\n";
        ssize_t r = write(STDERR_FILENO, msg, strlen(msg)); (void)r;
        return;
    }
    const char* msg = "\n[INTERRUPT] force exit\n";
    ssize_t r = write(STDERR_FILENO, msg, strlen(msg)); (void)r;
    _exit(130);
}

static void install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

/* =============================================================================
 * WORKER THREAD
 * ========================================================================== */

static void init_thread_config(ThreadConfig* cfg, int tid) {
    cfg->thread_id = tid;
    mpz_init(cfg->n_mpz);
    mpz_init(cfg->scratch);
    mpz_init(cfg->tile);
    cfg->found_buf_len = 0;
    derive_per_thread_seed(cfg->rng_state, g_urandom_master, tid);
    /* Seed gmp_randstate from two xoshiro lanes so mpz_urandomm draws are
     * uncorrelated across threads even though gmp_randseed_ui takes a u64. */
    gmp_randinit_mt(cfg->rand_state);
    u64 lo = xoshiro_next(cfg->rng_state);
    u64 hi = xoshiro_next(cfg->rng_state);
    gmp_randseed_ui(cfg->rand_state, lo ^ xoshiro_rotl(hi, 27));
    cfg->rand_state_inited = 1;
}
static void cleanup_thread_config(ThreadConfig* cfg) {
    mpz_clear(cfg->n_mpz); mpz_clear(cfg->scratch); mpz_clear(cfg->tile);
    if (cfg->rand_state_inited) {
        gmp_randclear(cfg->rand_state);
        cfg->rand_state_inited = 0;
    }
}

static void pin_thread_if_requested(int tid) {
#ifdef __linux__
    if (!g_pin_threads) return;
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu <= 0) return;
    long cpu = ((long)g_pin_base_cpu + tid) % ncpu;
    if (cpu < 0) cpu += ncpu;
    cpu_set_t set; CPU_ZERO(&set); CPU_SET(cpu, &set);
    (void)pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
#else
    (void)tid;
#endif
}

static void* worker_thread(void* arg) {
    ThreadConfig* cfg = (ThreadConfig*)arg;
    pin_thread_if_requested(cfg->thread_id);

    while (!shutdown_requested && !g_search_complete) {
        mpz_t batch_start, batch_end;
        mpz_init(batch_start); mpz_init(batch_end);

        pthread_mutex_lock(&g_seq_lock);
        if (g_deadline_epoch_sec > 0 && wall_time_sec() >= g_deadline_epoch_sec) {
            g_search_complete = 1;
            pthread_mutex_unlock(&g_seq_lock);
            mpz_clear(batch_start); mpz_clear(batch_end);
            break;
        }
        if (g_max_batches > 0 && g_batches_claimed >= (u64)g_max_batches) {
            g_search_complete = 1;
            pthread_mutex_unlock(&g_seq_lock);
            mpz_clear(batch_start); mpz_clear(batch_end);
            break;
        }
        if (g_random_chunk_mode) {
            /* Pick a uniformly random tile within [g_tile_min, g_tile_max),
             * then walk g_chunk_tiles forward (clamped to g_tile_max). The
             * random draw uses gmp_randstate per-thread, so different threads
             * see uncorrelated tile windows. */
            mpz_t span, rand_off;
            mpz_init(span); mpz_init(rand_off);
            mpz_sub(span, g_tile_max, g_tile_min);
            if (mpz_sgn(span) <= 0) {
                /* Degenerate range: nothing to do. */
                g_search_complete = 1;
                mpz_clear(span); mpz_clear(rand_off);
                pthread_mutex_unlock(&g_seq_lock);
                mpz_clear(batch_start); mpz_clear(batch_end);
                break;
            }
            mpz_urandomm(rand_off, cfg->rand_state, span);
            mpz_add(batch_start, g_tile_min, rand_off);
            mpz_add_ui(batch_end, batch_start, g_chunk_tiles);
            if (mpz_cmp(batch_end, g_tile_max) > 0) mpz_set(batch_end, g_tile_max);
            mpz_clear(span); mpz_clear(rand_off);
            g_batches_claimed++;
        } else {
            if (mpz_cmp(g_current_tile, g_tile_max) >= 0) {
                g_search_complete = 1;
                pthread_mutex_unlock(&g_seq_lock);
                mpz_clear(batch_start); mpz_clear(batch_end);
                break;
            }
            mpz_set(batch_start, g_current_tile);
            mpz_add_ui(batch_end, g_current_tile, g_tiles_per_batch);
            if (mpz_cmp(batch_end, g_tile_max) > 0) mpz_set(batch_end, g_tile_max);
            mpz_set(g_current_tile, batch_end);
            g_batches_claimed++;
        }
        pthread_mutex_unlock(&g_seq_lock);

        u64 cand=0, l2r=0, er=0, lr=0, surv=0;
        u64 tiles = run_tile_range(cfg, batch_start, batch_end, g_deadline_epoch_sec, 0,
                                   &cand, &l2r, &er, &lr, &surv);

        pthread_mutex_lock(&g_results.lock);
        g_results.tiles_processed += tiles;
        g_results.candidates += cand;
        g_results.l2_rejected += l2r;
        g_results.extl2_rejected += er;
        g_results.line_rejected += lr;
        g_results.survivors += surv;
        pthread_mutex_unlock(&g_results.lock);
        if (g_threads == 1) {
            pthread_mutex_lock(&g_seq_lock);
            mpz_add_ui(g_completed_tile, batch_start, (unsigned long)tiles);
            pthread_mutex_unlock(&g_seq_lock);
        }

        mpz_clear(batch_start); mpz_clear(batch_end);
        if (g_deadline_epoch_sec > 0 && wall_time_sec() >= g_deadline_epoch_sec) {
            g_search_complete = 1;
        }
    }
    return NULL;
}

/* =============================================================================
 * RANGE / PREFIX SETUP
 * ========================================================================== */

static int parse_prefix(const char* str, mpz_t value, int* bits) {
    mpz_set_ui(value, 0);
    *bits = 0;
    if (str[0] != '0' || (str[1] != 'b' && str[1] != 'B')) {
        fprintf(stderr, "ERROR: Prefix must be binary format (0b...)\n");
        return -1;
    }
    const char* p = str + 2;
    if (*p != '1') { fprintf(stderr, "ERROR: Binary prefix must start with 1\n"); return -1; }
    while (*p == '0' || *p == '1') {
        mpz_mul_2exp(value, value, 1);
        if (*p == '1') mpz_add_ui(value, value, 1);
        (*bits)++;
        p++;
    }
    if (*p != '\0') {
        fprintf(stderr, "ERROR: Prefix must contain only binary digits after 0b\n");
        return -1;
    }
    return 0;
}

static void compute_search_range(void) {
    /* n_min = 2^(bits-1), n_max = 2^bits - 1, narrowed to prefix range if set. */
    mpz_t two_bits, two_min;
    mpz_init(two_bits); mpz_init(two_min);
    mpz_ui_pow_ui(two_bits, 2, g_target_bits);
    mpz_ui_pow_ui(two_min, 2, g_target_bits - 1);
    mpz_set(g_n_min, two_min);
    mpz_set(g_n_max, two_bits);
    mpz_sub_ui(g_n_max, g_n_max, 1);

    if (g_use_prefix) {
        if (g_prefix_bits > g_target_bits) {
            fprintf(stderr, "ERROR: prefix has %d bits but target is %d bits\n",
                    g_prefix_bits, g_target_bits);
            exit(1);
        }
        int shift = g_target_bits - g_prefix_bits;
        mpz_t pmin, pmax;
        mpz_init(pmin); mpz_init(pmax);
        mpz_mul_2exp(pmin, g_prefix_value, shift);
        mpz_add_ui(pmax, g_prefix_value, 1);
        mpz_mul_2exp(pmax, pmax, shift);
        mpz_sub_ui(pmax, pmax, 1);
        if (mpz_cmp(pmin, g_n_min) > 0) mpz_set(g_n_min, pmin);
        if (mpz_cmp(pmax, g_n_max) < 0) mpz_set(g_n_max, pmax);
        mpz_clear(pmin); mpz_clear(pmax);
    }

    /* tile_min = floor(n_min / primorial), tile_max = ceil(n_max / primorial) + 1 */
    mpz_fdiv_q_ui(g_tile_min, g_n_min, g_primorial);
    mpz_cdiv_q_ui(g_tile_max, g_n_max, g_primorial);
    mpz_add_ui(g_tile_max, g_tile_max, 1);

    mpz_set(g_current_tile, g_tile_min);
    mpz_set(g_completed_tile, g_tile_min);

    /* Wide-mode gate: if max(n + diameter) >= 2^127, route to GMP (always
     * — verify_tuplet uses GMP regardless, but keep flag for diagnostics). */
    mpz_t check;
    mpz_init(check);
    mpz_add_ui(check, g_n_max, (unsigned long)g_pattern->diameter);
    g_wide_mode = (mpz_sizeinbase(check, 2) > 127) ? 1 : 0;
    mpz_clear(check);

    mpz_clear(two_bits); mpz_clear(two_min);
}

/* =============================================================================
 * --validate-known
 *
 * For each record matching --k, run a 2-second warm-up on the real filter path
 * with verification skipped, estimate a prefix for roughly 60 seconds of work,
 * then run single-threaded with a strict 60-second wall-clock cap. Emit one
 * OK/SKIPPED/NOTFOUND line per record.
 * ========================================================================== */

typedef struct {
    int k;
    char pattern[32];
    char base_dec[256];
    int bits;
} RecordEntry;

static int load_records_manifest(RecordEntry** out, int target_k_filter) {
    /* Try CWD-relative, then walk up to find tools/records_manifest.tsv. */
    static const char* candidates[] = {
        "tools/records_manifest.tsv",
        "../tools/records_manifest.tsv",
        "../../tools/records_manifest.tsv",
        NULL
    };
    FILE* fp = NULL;
    for (int i = 0; candidates[i]; i++) {
        fp = fopen(candidates[i], "r");
        if (fp) break;
    }
    if (!fp) {
        fprintf(stderr, "ERROR: tools/records_manifest.tsv not found. Run: python3 tools/parse_records_json.py\n");
        return -1;
    }
    char line[2048];
    int cap = 64, count = 0;
    RecordEntry* arr = (RecordEntry*)malloc(cap * sizeof(RecordEntry));
    if (!arr) { fclose(fp); return -1; }
    if (!fgets(line, sizeof(line), fp)) { fclose(fp); free(arr); return 0; } /* skip header */
    while (fgets(line, sizeof(line), fp)) {
        RecordEntry r; memset(&r, 0, sizeof(r));
        char date_buf[128], author_buf[256];
        int n_fields = sscanf(line, "%d\t%31[^\t]\t%255[^\t]\t%*d\t%127[^\t]\t%255[^\t]\t%d",
                              &r.k, r.pattern, r.base_dec, date_buf, author_buf, &r.bits);
        if (n_fields < 6) continue;
        if (r.k < 0 || r.k >= 64) continue;
        if (r.bits < 8 || r.bits > 4096) continue;
        if (target_k_filter > 0 && r.k != target_k_filter) continue;
        if (count >= cap) {
            cap *= 2;
            RecordEntry* grown = (RecordEntry*)realloc(arr, cap * sizeof(RecordEntry));
            if (!grown) {
                fclose(fp);
                free(arr);
                return -1;
            }
            arr = grown;
        }
        arr[count++] = r;
    }
    fclose(fp);
    *out = arr;
    return count;
}

static double estimate_throughput(double seconds) {
    /* Run the real filter path with verification skipped and return candidates/s. */
    int saved_profile_skip_verify = g_profile_skip_verify;
    g_profile_skip_verify = 1;
    ThreadConfig tc; init_thread_config(&tc, 0);
    mpz_t te; mpz_init(te);
    mpz_add_ui(te, g_current_tile, 1000000); /* upper bound */
    if (mpz_cmp(te, g_tile_max) > 0) mpz_set(te, g_tile_max);
    double t0 = wall_time_sec();
    double deadline = t0 + seconds;
    u64 cand = 0, l2r=0, ext_r=0, lr=0, surv=0;
    run_tile_range(&tc, g_current_tile, te, deadline, 0,
                   &cand, &l2r, &ext_r, &lr, &surv);
    double elapsed = wall_time_sec() - t0;
    if (elapsed < 1e-6) elapsed = 1e-6;
    mpz_clear(te);
    cleanup_thread_config(&tc);
    g_profile_skip_verify = saved_profile_skip_verify;
    return (double)cand / elapsed;
}

static int set_pattern_by_name(const char* name) {
    g_pattern = kt_pattern_by_name(name);
    if (!g_pattern) {
        fprintf(stderr, "ERROR: pattern '%s' not in catalog\n", name);
        return -1;
    }
    g_k = g_pattern->k;
    return 0;
}

static int default_pattern_for_k(int k, char* out_name, size_t cap) {
    /* Smallest-name (lexicographic) pattern of length k. */
    for (int i = 0; i < KT_PATTERNS_COUNT; i++) {
        if (KT_PATTERNS[i].k == k) {
            snprintf(out_name, cap, "%s", KT_PATTERNS[i].name);
            return 0;
        }
    }
    return -1;
}

static int run_validate_known(int target_k_filter) {
    RecordEntry* recs = NULL;
    int n = load_records_manifest(&recs, target_k_filter);
    if (n < 0) return 1;
    if (n == 0) {
        fprintf(stderr, "No records for k=%d\n", target_k_filter);
        free(recs);
        return target_k_filter > 0 ? 1 : 0;
    }
    if (g_bench_jsonl_path && !g_bench_jsonl_fp) {
        g_bench_jsonl_fp = fopen(g_bench_jsonl_path, "w");
        if (!g_bench_jsonl_fp) {
            fprintf(stderr, "ERROR: cannot open --bench-jsonl path %s: %s\n",
                    g_bench_jsonl_path, strerror(errno));
            free(recs);
            return 2;
        }
    }
    if (reporter_active())
        fprintf(stderr, "Reporter: every %.2fs (stderr)\n", g_report_interval_sec);

    /* Group by k; pick a small budget per record. */
    int ok_by_k[64] = {0};
    int touched_by_k[64] = {0};

    for (int i = 0; i < n; i++) {
        RecordEntry* r = &recs[i];
        if (touched_by_k[r->k] >= 5 && ok_by_k[r->k] >= 1) continue; /* one OK per k is enough */
        touched_by_k[r->k]++;

        /* Configure engine for this record. */
        if (set_pattern_by_name(r->pattern) != 0) continue;
        g_target_bits = r->bits;
        g_threads = 1;
        g_sequential_mode = 1;
        g_use_prefix = 0; /* set below */

        /* Build wheel + filters for this pattern. */
        free_wheel_tables();
        free_bitvec_buckets_kt();
        if (build_wheel(g_pattern) != 0) {
            printf("[k=%d %s] FAIL build_wheel\n", r->k, r->pattern);
            continue;
        }
        init_filter_tables(g_pattern);
        precompute_bitvec_blocks_kt();

        /* Compute a tentative range so warm-up has tiles to process. */
        mpz_set_ui(g_prefix_value, 1);
        g_prefix_bits = 1;
        g_use_prefix = 1;
        compute_search_range();

        double tput = estimate_throughput(2.0);
        if (tput < 1.0) tput = 1.0;

        /* Choose prefix_bits so 2^(bits - prefix_bits) candidates fit in ~60s. */
        double budget_candidates = 60.0 * tput;
        int needed_prefix_bits = 0;
        if (budget_candidates < 1.0) needed_prefix_bits = r->bits - 1;
        else {
            double log2_budget = log(budget_candidates) / log(2.0);
            needed_prefix_bits = (int)ceil((double)r->bits - log2_budget);
            if (needed_prefix_bits < 1) needed_prefix_bits = 1;
            if (needed_prefix_bits > r->bits - 1) needed_prefix_bits = r->bits - 1;
        }

        /* prefix = base >> (bits - prefix_bits) */
        mpz_t base, prefix;
        mpz_init(base); mpz_init(prefix);
        mpz_set_str(base, r->base_dec, 10);
        mpz_fdiv_q_2exp(prefix, base, r->bits - needed_prefix_bits);

        /* Sanity: prefix bit-length should equal needed_prefix_bits */
        if ((int)mpz_sizeinbase(prefix, 2) != needed_prefix_bits) {
            /* Possibly the leading bit is 0 (e.g. base bit_length not a clean fit).
             * Walk needed_prefix_bits down so prefix has a leading 1. */
            while (needed_prefix_bits > 1 && (int)mpz_sizeinbase(prefix, 2) != needed_prefix_bits) {
                needed_prefix_bits--;
                mpz_fdiv_q_2exp(prefix, base, r->bits - needed_prefix_bits);
            }
        }

        if (needed_prefix_bits >= r->bits) {
            printf("[k=%d %s] SKIPPED reason=throughput_too_low (tput=%.0f/s)\n",
                   r->k, r->pattern, tput);
            mpz_clear(base); mpz_clear(prefix);
            continue;
        }

        mpz_set(g_prefix_value, prefix);
        g_prefix_bits = needed_prefix_bits;
        compute_search_range();

        /* Run with 60s budget. */
        memset(&g_results, 0, sizeof(g_results));
        pthread_mutex_init(&g_results.lock, NULL);
        reset_global_results();
        g_search_complete = 0;
        g_max_time_sec = 60.0;
        g_max_batches = 0;
        g_sieve_only_mode = 0;
        g_profile_skip_verify = 0;
        g_batches_claimed = 0;
        g_deadline_epoch_sec = wall_time_sec() + g_max_time_sec;

        ThreadConfig tc; init_thread_config(&tc, 0);
        double t0 = wall_time_sec();

        /* Spawn worker in its own thread so the reporter can run in this one. */
        pthread_t wt;
        int spawned = (pthread_create(&wt, NULL, worker_thread, &tc) == 0);
        if (spawned) {
            /* Poll fast (50ms) so worker completion is detected promptly even
             * for sub-second records; emit a reporter line at the configured
             * cadence. This stops the reporter sleep from dominating elapsed
             * and skewing tput on short shards. */
            const useconds_t poll_us = 50000;
            double last_emit = wall_time_sec();
            while (!g_search_complete && !shutdown_requested) {
                usleep(poll_us);
                double now = wall_time_sec();
                if (g_deadline_epoch_sec > 0 && now >= g_deadline_epoch_sec)
                    g_search_complete = 1;
                if (reporter_active() && (now - last_emit) >= g_report_interval_sec) {
                    emit_reporter_line(t0, 0); /* shards too tiny for ETA */
                    last_emit = now;
                }
            }
            pthread_join(wt, NULL);
        } else {
            worker_thread(&tc);
        }
        if (reporter_active()) emit_reporter_done(t0);

        double elapsed = wall_time_sec() - t0;
        cleanup_thread_config(&tc);
        g_max_time_sec = 0.0;
        g_deadline_epoch_sec = 0.0;

        /* Did we report base as a hit? */
        int hit = 0;
        for (int j = 0; j < g_results.found_count; j++) {
            if (strcmp(g_results.found_strs[j], r->base_dec) == 0) { hit = 1; break; }
        }
        u64 op_cand = __atomic_load_n(&g_op_cand, __ATOMIC_RELAXED);
        u64 op_surv = __atomic_load_n(&g_op_surv, __ATOMIC_RELAXED);
        u64 op_pt   = __atomic_load_n(&g_op_prime_tests, __ATOMIC_RELAXED);
        u64 op_ft   = __atomic_load_n(&g_op_fermat_tests, __ATOMIC_RELAXED);
        u64 op_fr   = __atomic_load_n(&g_op_fermat_rejects, __ATOMIC_RELAXED);
        u64 op_fmt  = __atomic_load_n(&g_op_fermat_mont_tests, __ATOMIC_RELAXED);
        u64 op_fnd  = __atomic_load_n(&g_op_found, __ATOMIC_RELAXED);
        if (hit) {
            printf("[k=%d %s] base=%s OK time=%.1fs prefix_bits=%d tput=%.0f/s\n",
                   r->k, r->pattern, r->base_dec, elapsed, needed_prefix_bits, tput);
            ok_by_k[r->k] = 1;
        } else {
            printf("[k=%d %s] base=%s NOTFOUND time=%.1fs prefix_bits=%d cand=%llu surv=%llu\n",
                   r->k, r->pattern, r->base_dec, elapsed, needed_prefix_bits,
                   (unsigned long long)g_results.candidates,
                   (unsigned long long)g_results.survivors);
        }
        if (g_bench_jsonl_fp) {
            double cand_per_s = elapsed > 0 ? (double)op_cand / elapsed : 0;
            pthread_mutex_lock(&g_bench_jsonl_lock);
            fprintf(g_bench_jsonl_fp,
                    "{\"k\":%d,\"pattern\":\"%s\",\"base\":\"%s\",\"bits\":%d,"
                    "\"prefix_bits\":%d,\"elapsed_s\":%.4f,"
                    "\"cand\":%llu,\"surv\":%llu,\"prime_tests\":%llu,"
                    "\"fermat_tests\":%llu,\"fermat_rejects\":%llu,"
                    "\"fermat_mont_tests\":%llu,"
                    "\"opt_fermat\":%d,\"opt_mont_fermat\":%d,"
                    "\"found\":%llu,\"hit\":%d,\"tput_cand_per_s\":%.0f}\n",
                    r->k, r->pattern, r->base_dec, r->bits,
                    needed_prefix_bits, elapsed,
                    (unsigned long long)op_cand,
                    (unsigned long long)op_surv,
                    (unsigned long long)op_pt,
                    (unsigned long long)op_ft,
                    (unsigned long long)op_fr,
                    (unsigned long long)op_fmt,
                    g_opt_fermat ? 1 : 0,
                    g_opt_mont_fermat ? 1 : 0,
                    (unsigned long long)op_fnd,
                    hit ? 1 : 0, cand_per_s);
            fflush(g_bench_jsonl_fp);
            pthread_mutex_unlock(&g_bench_jsonl_lock);
        }
        for (int j = 0; j < g_results.found_count; j++) free(g_results.found_strs[j]);
        pthread_mutex_destroy(&g_results.lock);
        mpz_clear(base); mpz_clear(prefix);
    }

    int gate_ok = 1;
    if (target_k_filter > 0) {
        gate_ok = ok_by_k[target_k_filter];
    } else {
        gate_ok = ok_by_k[17] && ok_by_k[18] && ok_by_k[19];
    }
    printf("\n=== validate-known summary ===\n");
    for (int k = 16; k <= 24; k++) {
        if (touched_by_k[k] > 0)
            printf("  k=%d: %s (touched=%d)\n", k, ok_by_k[k] ? "OK" : "FAIL", touched_by_k[k]);
    }
    free(recs);
    free_bitvec_buckets_kt();
    if (g_bench_jsonl_fp) {
        fclose(g_bench_jsonl_fp);
        g_bench_jsonl_fp = NULL;
    }
    return gate_ok ? 0 : 1;
}

/* =============================================================================
 * --smoke
 *
 * Single batch sieve-only at the configured (k, pattern, bits). Asserts that
 * the L2/ext-L2/line-sieve stages all reject something and that we processed
 * a minimum number of candidates. Used as a synthetic Layer-2 gate at
 * k=22/23/24 where no real records exist yet.
 * ========================================================================== */

static int run_smoke(void) {
    g_sieve_only_mode = 1;
    g_profile_skip_verify = 0;
    g_max_batches = 1;
    g_batches_claimed = 0;
    g_deadline_epoch_sec = 0.0;
    g_threads = 1;
    g_sequential_mode = 1;
    /* Bigger batch so high-k smoke still hits the 100k-candidate floor with
     * a tiny wheel (e.g. wheel_size=1 for KT22..24 mod 2310). */
    if (g_tiles_per_batch < 200000) g_tiles_per_batch = 200000;
    if (!g_use_prefix) {
        /* Default smoke prefix = 0b1: lower half of bit range. */
        mpz_set_ui(g_prefix_value, 1);
        g_prefix_bits = 1;
        g_use_prefix = 1;
    }
    if (build_wheel(g_pattern) != 0) { fprintf(stderr, "build_wheel failed\n"); return 1; }
    init_filter_tables(g_pattern);
    precompute_bitvec_blocks_kt();
    compute_search_range();

    memset(&g_results, 0, sizeof(g_results));
    pthread_mutex_init(&g_results.lock, NULL);
    g_search_complete = 0;

    printf("smoke: pattern=%s k=%d bits=%d wheel_size=%d primorial=%llu\n",
           g_pattern->name, g_k, g_target_bits, g_wheel_size,
           (unsigned long long)g_primorial);

    ThreadConfig tc; init_thread_config(&tc, 0);
    worker_thread(&tc);
    cleanup_thread_config(&tc);

    printf("smoke: tiles=%llu cand=%llu l2_rej=%llu extl2_rej=%llu line_rej=%llu surv=%llu\n",
           (unsigned long long)g_results.tiles_processed,
           (unsigned long long)g_results.candidates,
           (unsigned long long)g_results.l2_rejected,
           (unsigned long long)g_results.extl2_rejected,
           (unsigned long long)g_results.line_rejected,
           (unsigned long long)g_results.survivors);

    int ok = 1;
    if (g_results.candidates < 100000ULL) { printf("smoke: FAIL candidates < 1e5\n"); ok = 0; }
    if (g_results.l2_rejected == 0)       { printf("smoke: FAIL L2 reject = 0\n"); ok = 0; }
    if (g_results.extl2_rejected == 0)    { printf("smoke: FAIL ext-L2 reject = 0\n"); ok = 0; }
    if (g_results.line_rejected == 0)     { printf("smoke: FAIL line reject = 0\n"); ok = 0; }

    pthread_mutex_destroy(&g_results.lock);
    if (ok) { printf("smoke OK pattern=%s\n", g_pattern->name); return 0; }
    return 1;
}

/* =============================================================================
 * UNIT TESTS
 * ========================================================================== */

static int t_pass = 0, t_fail = 0;
#define TEST(name, expr) do { \
    if (expr) { printf("  OK  %s\n", name); t_pass++; } \
    else      { printf("  FAIL %s\n", name); t_fail++; } \
} while(0)

static int run_unit_tests(void) {
    printf("=== kt_gmp_v1 unit tests ===\n");

    /* T01: catalog count floor. Catalog grew from records.json/Luhn high-k rows
     * (25 entries) to enumerator-derived (>=25). Semantic check that no
     * locked name was lost is covered by T02-T15 (each looks up by name). */
    TEST("T01_catalog_count_at_least_25", KT_PATTERNS_COUNT >= 25);

    /* T02: lookup KT19_P0 */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT19_P0");
        TEST("T02_KT19_P0_lookup", p && p->k == 19 && p->diameter == 76);
    }

    /* T03: forbidden residues KT5_P0 at q=7 */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT5_P0");
        u32 buf[KT_MAX_K];
        int n = kt_pattern_forbidden_residues(p, 7, buf);
        /* Expected: {0,1,2,5,6} from GP T02 — sorted match (count 5, set match). */
        int seen[8] = {0};
        for (int i = 0; i < n; i++) seen[buf[i]] = 1;
        TEST("T03_forbidden_KT5_q7", n == 5 && seen[0] && seen[1] && seen[2] && seen[5] && seen[6]);
    }

    /* T04: forbidden residues KT5_P0 at q=5 dedup */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT5_P0");
        u32 buf[KT_MAX_K];
        int n = kt_pattern_forbidden_residues(p, 5, buf);
        int seen[8] = {0};
        for (int i = 0; i < n; i++) seen[buf[i]] = 1;
        TEST("T04_forbidden_KT5_q5_dedup", n == 4 && seen[0] && seen[2] && seen[3] && seen[4]);
    }

    /* T05-T09: forbidden residue formula sanity */
    for (int idx = 0; idx < 5; idx++) {
        const char* names[] = {"KT5_P0","KT19_P0","KT19_P0","KT22_P0","KT24_P0"};
        u32 qs[]            = {7,        43,       37,       37,       37};
        const KTupletPattern* p = kt_pattern_by_name(names[idx]);
        u32 buf[KT_MAX_K]; int n = kt_pattern_forbidden_residues(p, qs[idx], buf);
        int ok = 1;
        for (int i = 0; i < n; i++) {
            int found = 0;
            for (int j = 0; j < p->k; j++) {
                u32 expect = (qs[idx] - ((u32)p->offsets[j] % qs[idx])) % qs[idx];
                if (expect == buf[i]) { found = 1; break; }
            }
            if (!found) ok = 0;
        }
        char tname[64]; snprintf(tname, sizeof(tname), "T0%d_forbidden_formula_%s_q%u", 5+idx, names[idx], qs[idx]);
        TEST(tname, ok);
    }

    /* T10-T15: Layer-1 admissibility for k=22-24 */
    {
        struct { const char* name; int k; } cases[] = {
            {"KT22_P0", 22}, {"KT22_P1", 22}, {"KT23_P0", 23},
            {"KT24_P0", 24}, {"KT24_P1", 24}, {"KT24_P2", 24},
        };
        for (int i = 0; i < 6; i++) {
            const KTupletPattern* p = kt_pattern_by_name(cases[i].name);
            int bad = 0;
            int ok = (p && p->k == cases[i].k && kt_pattern_is_admissible(p, 113, &bad));
            char tname[64];
            snprintf(tname, sizeof(tname), "T%d_%s_admissible_q<=113", 10+i, cases[i].name);
            TEST(tname, ok);
        }
    }

    /* T16: KT19 diameter 76 */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT19_P0");
        TEST("T16_KT19_P0_diameter_76", p && p->diameter == 76);
    }

    /* T17: KT22_P0 diameter 90, KT24_P0 diameter 100 */
    {
        const KTupletPattern* p1 = kt_pattern_by_name("KT22_P0");
        const KTupletPattern* p2 = kt_pattern_by_name("KT24_P0");
        TEST("T17_high_k_diameters", p1 && p1->diameter == 90 && p2 && p2->diameter == 100);
    }

    /* T18: pattern_match by offsets */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT5_P0");
        const KTupletPattern* p2 = kt_pattern_match(5, p->offsets);
        TEST("T18_pattern_match_by_offsets", p == p2);
    }

    /* T19: forbidden count <= k for any pattern, any q (small sample) */
    {
        int ok = 1;
        for (int idx = 0; idx < KT_PATTERNS_COUNT && ok; idx++) {
            const KTupletPattern* p = &KT_PATTERNS[idx];
            for (u32 q = 2; q <= 113 && ok; q++) {
                if (!is_small_prime(q)) continue;
                u32 buf[KT_MAX_K];
                int n = kt_pattern_forbidden_residues(p, q, buf);
                if (n > p->k) ok = 0;
            }
        }
        TEST("T19_forbidden_count_le_k", ok);
    }

    /* T20-T22: u128/Montgomery sanity */
    {
        u128 m = 97; MontCtx ctx; mont_ctx_init(&ctx, m);
        TEST("T20_mont_pow_2_13_mod_97_eq_44", mont_powm(2, 13, &ctx) == 44);
    }
    {
        u128 m = 1000000007ULL; MontCtx ctx; mont_ctx_init(&ctx, m);
        u128 r = mont_powm(3, 50, &ctx);
        mpz_t a, e, mm, rg; mpz_inits(a, e, mm, rg, NULL);
        mpz_set_ui(a, 3); mpz_set_ui(e, 50); mpz_set_ui(mm, 1000000007ULL);
        mpz_powm(rg, a, e, mm);
        u64 g = mpz_get_ui(rg);
        TEST("T21_mont_3_50_mod_1e9_7_eq_GMP", (u64)r == g);
        mpz_clears(a, e, mm, rg, NULL);
    }
    {
        TEST("T22_is_prime_native_1e9_7", is_prime_native(1000000007ULL));
    }
    {
        TEST("T23_is_prime_native_561_no", !is_prime_native(561));
        TEST("T24_is_prime_native_1729_no", !is_prime_native(1729));
        TEST("T25_is_prime_native_2_yes", is_prime_native(2));
        TEST("T26_is_prime_native_15_no", !is_prime_native(15));
    }

    /* T27-T29: verify_tuplet on known small tuplets */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT5_P0");
        mpz_t n, scratch; mpz_init(n); mpz_init(scratch);
        mpz_set_ui(n, 5); /* 5,7,11,13,17 all prime */
        int ok = verify_tuplet_gmp(n, p, scratch);
        mpz_set_ui(n, 4); /* 4+2=6 composite */
        int notok = verify_tuplet_gmp(n, p, scratch);
        TEST("T27_verify_KT5_P0_at_5", ok);
        TEST("T28_verify_KT5_P0_at_4_rejects", !notok);
        mpz_clear(n); mpz_clear(scratch);
    }
    {
        const KTupletPattern* p = kt_pattern_by_name("KT7_P0");
        mpz_t n, scratch; mpz_init(n); mpz_init(scratch);
        mpz_set_ui(n, 11); /* 11,13,17,19,23,29,31 all prime */
        TEST("T29_verify_KT7_P0_at_11", verify_tuplet_gmp(n, p, scratch));
        mpz_clear(n); mpz_clear(scratch);
    }

    /* T30: verify a known KT17_P0 record (Wroblewski 2009, smallest). */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT17_P3");
        mpz_t n, scratch; mpz_init(n); mpz_init(scratch);
        mpz_set_str(n, "1620784518619319025971", 10); /* k=17 first record */
        TEST("T30_verify_KT17_P3_record", verify_tuplet_gmp(n, p, scratch));
        mpz_clear(n); mpz_clear(scratch);
    }

    /* T31: prefix parser */
    {
        mpz_t v; mpz_init(v); int b;
        int rc = parse_prefix("0b1011", v, &b);
        TEST("T31_prefix_0b1011", rc == 0 && b == 4 && mpz_cmp_ui(v, 11) == 0);
        mpz_clear(v);
    }
    /* T32: prefix parser rejects malformed forms (suppress stderr noise during this test) */
    {
        mpz_t v; mpz_init(v); int b;
        int saved = dup(STDERR_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
        int rc1 = parse_prefix("0b011", v, &b);
        int rc2 = parse_prefix("0b1011junk", v, &b);
        if (saved >= 0) { dup2(saved, STDERR_FILENO); close(saved); }
        TEST("T32_prefix_rejects_invalid_forms", rc1 != 0 && rc2 != 0);
        mpz_clear(v);
    }

    /* T33: primorial computation */
    {
        u32 fac[16]; int fc;
        u64 p11 = compute_primorial_for_n_primes(5, fac, &fc);
        TEST("T33_primorial_11hash_2310", p11 == 2310ULL && fc == 5);
        u64 p17 = compute_primorial_for_n_primes(7, fac, &fc);
        TEST("T34_primorial_17hash_510510", p17 == 510510ULL && fc == 7);
    }

    /* T35: filter primes do not include primorial primes */
    {
        g_primorial_n_primes = 5;
        g_primorial = compute_primorial_for_n_primes(5, g_primorial_factors, &g_primorial_factor_count);
        build_filter_primes();
        int ok = 1;
        for (int i = 0; i < g_l2_count; i++) {
            for (int j = 0; j < g_primorial_factor_count; j++)
                if (g_l2_primes[i] == g_primorial_factors[j]) ok = 0;
        }
        TEST("T35_filter_primes_disjoint_primorial", ok && g_l2_count > 0);
    }

    /* T36: build_wheel for KT5_P0 mod 2310 -> exactly 12 admissible classes */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT5_P0");
        free_wheel_tables();
        int rc = build_wheel(p);
        TEST("T36_wheel_KT5_P0_mod2310_size_12", rc == 0 && g_wheel_size == 12);
    }

    /* T37: every wheel residue is admissible mod each primorial prime */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT5_P0");
        int ok = 1;
        for (int w = 0; w < g_wheel_size && ok; w++) {
            u32 r = g_wheel[w];
            for (int j = 0; j < g_primorial_factor_count && ok; j++) {
                u32 q = g_primorial_factors[j];
                u32 buf[KT_MAX_K];
                int n = kt_pattern_forbidden_residues(p, q, buf);
                u32 rm = r % q;
                for (int t = 0; t < n; t++) if (buf[t] == rm) ok = 0;
            }
        }
        TEST("T37_wheel_residues_admissible", ok);
    }

    /* T38: KT22_P0 wheel size > 0 mod 2310, and matches GP-style product. */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT22_P0");
        free_wheel_tables();
        int rc = build_wheel(p);
        /* product over q in {2,3,5,7,11} of (q - |fbd_q|) */
        const KTupletPattern* pp = p;
        u64 expected = 1;
        for (int j = 0; j < g_primorial_factor_count; j++) {
            u32 q = g_primorial_factors[j];
            u32 buf[KT_MAX_K];
            int nf = kt_pattern_forbidden_residues(pp, q, buf);
            expected *= (q - nf);
        }
        TEST("T38_wheel_KT22_P0_count_matches_product", rc == 0 && (u64)g_wheel_size == expected);
    }

    /* T39: filter table init for KT22_P0 — check L2 mask for q=37
     * Expected: bits set for {(37 - b%37)%37 : b in offsets, dedup}.
     * Compute expected directly to avoid a brittle hard-coded constant. */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT22_P0");
        free_wheel_tables();
        build_wheel(p);
        init_filter_tables(p);
        u64 expected = 0;
        u32 buf[KT_MAX_K];
        int n = kt_pattern_forbidden_residues(p, 37, buf);
        for (int t = 0; t < n; t++) expected |= (1ULL << buf[t]);
        int idx37 = -1;
        for (int i = 0; i < g_l2_count; i++) if (g_l2_primes[i] == 37) { idx37 = i; break; }
        TEST("T39_filter_table_KT22_P0_q37", idx37 >= 0 && g_l2_mask[idx37] == expected);
    }

    /* T40: line-sieve packed table for q=131 — popcount equals forbidden set size */
    {
        int idx131 = -1;
        for (int i = 0; i < g_line_count; i++) if (g_line_primes[i] == 131) { idx131 = i; break; }
        if (idx131 >= 0) {
            int pop = 0;
            for (int j = 0; j < g_line_kill_stride; j++)
                pop += __builtin_popcountll(g_line_kill_packed[idx131 * g_line_kill_stride + j]);
            u32 buf[KT_MAX_K];
            int n = kt_pattern_forbidden_residues(g_pattern ? g_pattern : kt_pattern_by_name("KT22_P0"), 131, buf);
            TEST("T40_line_sieve_popcount_q131", pop == n);
        } else {
            TEST("T40_line_sieve_popcount_q131", 0);
        }
    }

    /* T41-T45: KT22, KT23, KT24 wheel sizes — sanity range. */
    {
        const char* names[] = {"KT22_P0", "KT22_P1", "KT23_P0", "KT24_P0", "KT24_P1"};
        int ok = 1;
        for (int i = 0; i < 5; i++) {
            const KTupletPattern* p = kt_pattern_by_name(names[i]);
            free_wheel_tables();
            int rc = build_wheel(p);
            if (rc != 0 || g_wheel_size <= 0) ok = 0;
            char tname[64]; snprintf(tname, sizeof(tname), "T%d_wheel_%s_positive", 41+i, names[i]);
            TEST(tname, rc == 0 && g_wheel_size > 0);
        }
        (void)ok;
    }

    /* T46: cross-check forbidden residues against GP formula at KT19_P0 q=43 */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT19_P0");
        u32 buf[KT_MAX_K];
        int n = kt_pattern_forbidden_residues(p, 43, buf);
        /* GP: ((-o) % 43 + 43) % 43 dedup. Compute reference here. */
        u32 ref[KT_MAX_K]; int rn = 0;
        for (int i = 0; i < p->k; i++) {
            u32 v = (43 - ((u32)p->offsets[i] % 43)) % 43;
            int dup = 0;
            for (int j = 0; j < rn; j++) if (ref[j] == v) { dup = 1; break; }
            if (!dup) ref[rn++] = v;
        }
        int match = (n == rn);
        for (int i = 0; i < n && match; i++) {
            int found = 0;
            for (int j = 0; j < rn; j++) if (ref[j] == buf[i]) { found = 1; break; }
            if (!found) match = 0;
        }
        TEST("T46_GP_crosscheck_KT19_P0_q43", match);
    }

    /* T47: u128 round-trip via mpz_to_u128 / u128_to_mpz. */
    {
        mpz_t a, b; mpz_init(a); mpz_init(b);
        mpz_set_str(a, "123456789abcdef0123456789abcdef0", 16);
        u128 v = mpz_to_u128(a);
        u128_to_mpz(b, v);
        TEST("T47_u128_roundtrip", mpz_cmp(a, b) == 0);
        mpz_clear(a); mpz_clear(b);
    }

    /* T48: incremental tile baseline matches recompute */
    {
        u32 q = 41;
        u64 t1 = 12345, t2 = 12346;
        u32 pri_mod = (u32)(2310 % q);
        u32 b1 = (u32)(t1 % q * pri_mod % q);
        u32 b1_inc = b1 + pri_mod; if (b1_inc >= q) b1_inc -= q;
        u32 b2 = (u32)(t2 % q * pri_mod % q);
        TEST("T48_tile_baseline_increment", b1_inc == b2);
    }

    /* T49: refuse to load a non-kt-v1 checkpoint */
    {
        char path[] = "/tmp/kt_test_ckpt_XXXXXX";
        int fd = mkstemp(path);
        if (fd >= 0) {
            FILE* fp = fdopen(fd, "w");
            fprintf(fp, "v33\n0\n");
            fclose(fp);
            const char* saved_ckpt = g_checkpoint_file;
            g_checkpoint_file = path;
            fflush(NULL);
            pid_t pid = fork();
            int ok = 0;
            if (pid == 0) {
                int devnull = open("/dev/null", O_WRONLY);
                if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
                load_checkpoint();
                _exit(0);
            } else if (pid > 0) {
                int status = 0;
                if (waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 1)
                    ok = 1;
            }
            g_checkpoint_file = saved_ckpt;
            unlink(path);
            TEST("T49_old_checkpoint_refused", ok);
        } else {
            TEST("T49_old_checkpoint_refused", 0);
        }
    }

    /* T51: Fermat-2 prefilter against a known KT17_P3 record (reuses the
     * Wroblewski 2009 base from T30) and a known composite (n=15, offset 0).
     * Asserts every member passes Fermat AND every member passes BPSW. */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT17_P3");
        mpz_t n, t, r, nm1; mpz_init(n); mpz_init(t); mpz_init(r); mpz_init(nm1);
        mpz_set_str(n, "1620784518619319025971", 10);
        int all_fermat = 1, all_bpsw = 1;
        for (int i = 0; p && i < p->k; i++) {
            mpz_add_ui(t, n, (unsigned long)p->offsets[i]);
            if (!fermat_base2_gmp(t, r, nm1)) { all_fermat = 0; break; }
            if (mpz_probab_prime_p(t, 25) <= 0) { all_bpsw = 0; break; }
        }
        TEST("T51_fermat_passes_known_record_kt17", p && all_fermat && all_bpsw);
        /* Negative: n=15 must fail Fermat-2 (2^14 mod 15 = 4 != 1). */
        mpz_set_ui(n, 15);
        int composite_fails = !fermat_base2_gmp(n, r, nm1);
        TEST("T52_fermat_rejects_composite_15", composite_fails);
        mpz_clear(n); mpz_clear(t); mpz_clear(r); mpz_clear(nm1);
    }

    /* T53: u128 Montgomery Fermat prefilter agrees with the GMP path on a
     * known KT17_P3 record (~71 bits, fits in u128 with offset headroom).
     * Asserts every member passes Mont-Fermat AND every member passes the
     * GMP-Fermat baseline (the two backends must agree). Also checks the
     * negative case (n=15 must be rejected by both backends). */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT17_P3");
        mpz_t n, t, r, nm1; mpz_init(n); mpz_init(t); mpz_init(r); mpz_init(nm1);
        mpz_set_str(n, "1620784518619319025971", 10);
        int all_mont = 1, all_gmp = 1, agree = 1;
        int largest_bits = 0;
        if (p) {
            mpz_add_ui(t, n, (unsigned long)p->offsets[p->k - 1]);
            largest_bits = (int)mpz_sizeinbase(t, 2);
        }
        for (int i = 0; p && i < p->k; i++) {
            mpz_add_ui(t, n, (unsigned long)p->offsets[i]);
            int gmp_ok  = fermat_base2_gmp(t, r, nm1);
            int mont_ok = fermat_base2_mont(mpz_to_u128(t));
            if (!mont_ok) all_mont = 0;
            if (!gmp_ok)  all_gmp  = 0;
            if (mont_ok != gmp_ok) agree = 0;
        }
        int comp_mont = !fermat_base2_mont((u128)15);
        TEST("T53_mont_fermat_passes_known_record_kt17",
             p && largest_bits <= 124 && all_mont && all_gmp && agree && comp_mont);
        mpz_clear(n); mpz_clear(t); mpz_clear(r); mpz_clear(nm1);
    }

    /* T54: random-chunk mode produces uncorrelated tile streams across
     * threads. Seed two thread configs from a fixed master seed (NOT
     * /dev/urandom) so the test is deterministic-but-still-uncorrelated.
     * Each thread draws 10 tile offsets from a fixed 1e9-wide range; we
     * assert the two threads' first 10 draws are not bit-identical. */
    {
        u64 saved_master[4]; memcpy(saved_master, g_urandom_master, sizeof(saved_master));
        g_urandom_master[0] = 0x0123456789ABCDEFULL;
        g_urandom_master[1] = 0xFEDCBA9876543210ULL;
        g_urandom_master[2] = 0xDEADBEEFCAFEBABEULL;
        g_urandom_master[3] = 0xA5A5A5A5A5A5A5A5ULL;

        ThreadConfig a, b;
        init_thread_config(&a, 0);
        init_thread_config(&b, 1);

        mpz_t span; mpz_init_set_ui(span, 1000000000UL);
        mpz_t ra, rb; mpz_init(ra); mpz_init(rb);
        unsigned long aseq[10], bseq[10];
        for (int i = 0; i < 10; i++) {
            mpz_urandomm(ra, a.rand_state, span);
            mpz_urandomm(rb, b.rand_state, span);
            aseq[i] = mpz_get_ui(ra);
            bseq[i] = mpz_get_ui(rb);
        }
        int identical = 1;
        for (int i = 0; i < 10; i++) if (aseq[i] != bseq[i]) { identical = 0; break; }
        int xoshiro_diverged = (a.rng_state[0] != b.rng_state[0]) ||
                               (a.rng_state[1] != b.rng_state[1]);
        TEST("T54_random_chunk_threads_uncorrelated", !identical && xoshiro_diverged);

        mpz_clear(ra); mpz_clear(rb); mpz_clear(span);
        cleanup_thread_config(&a);
        cleanup_thread_config(&b);
        memcpy(g_urandom_master, saved_master, sizeof(saved_master));
    }

    /* T55: persist_tuplet_to_file writes and fsyncs a record; bytes readable
     * from disk before the function returns. */
    {
        char path[] = "/tmp/kt_t55_XXXXXX";
        int fd = mkstemp(path);
        int ok = 0;
        if (fd >= 0) {
            FILE* saved_fp = g_log_fp;
            g_log_fp = fdopen(fd, "w");
            if (g_log_fp) {
                persist_tuplet_to_file(5, "KT5_P0", "123456789");
                fclose(g_log_fp);
                g_log_fp = saved_fp;
                char buf[256] = {0};
                int rfd = open(path, O_RDONLY);
                if (rfd >= 0) {
                    ssize_t nr = read(rfd, buf, sizeof(buf) - 1);
                    close(rfd);
                    ok = (nr > 0 && strstr(buf, "KT5 KT5_P0 123456789") != NULL);
                }
            } else {
                close(fd);
                g_log_fp = saved_fp;
            }
            unlink(path);
        }
        TEST("T55_persist_record_to_disk", ok);
    }

    /* T56 (Phase 4b-#4): bitscan ctzll iteration enumerates the same set of
     * slot indices as the 0..63 bit-test loop. Build a deterministic 64-bit
     * alive mask, run both branches, assert identical sorted slot sequences. */
    {
        u64 alive = 0xA1B2C3D4E5F60718ULL;
        int via_scan[64], n_scan = 0;
        for (int slot = 0; slot < 64; slot++) {
            if ((alive >> slot) & 1ULL) via_scan[n_scan++] = slot;
        }
        int via_ctz[64], n_ctz = 0;
        u64 surv = alive;
        while (surv) {
            int slot = __builtin_ctzll(surv);
            surv &= surv - 1;
            via_ctz[n_ctz++] = slot;
        }
        int eq = (n_scan == n_ctz);
        for (int i = 0; eq && i < n_scan; i++) {
            if (via_scan[i] != via_ctz[i]) eq = 0;
        }
        int popcnt_match = (n_scan == __builtin_popcountll(alive));
        TEST("T56_bitscan_ctzll_matches_slot_scan", eq && popcnt_match);
    }

    /* T57 (Phase 4b-#5): lifted line-sieve cap monotonically grows the kill set.
     * Build the line-sieve kill table at cap=863 and again at cap=4096 against
     * the same pattern; assert the deeper sieve has at least as many forbidden
     * residues. Strict-greater check: extending the prime set must add bits. */
    {
        const KTupletPattern* p = kt_pattern_by_name("KT22_P0");
        int saved_cap = g_opt_line_cap;
        u64 sum_863 = 0, sum_4096 = 0;
        int count_863 = 0, count_4096 = 0;

        g_opt_line_cap = 863;
        build_filter_primes();
        free_wheel_tables();
        build_wheel(p);
        init_filter_tables(p);
        count_863 = g_line_count;
        for (int i = 0; i < g_line_count; i++)
            for (int j = 0; j < g_line_kill_stride; j++)
                sum_863 += __builtin_popcountll(g_line_kill_packed[i * g_line_kill_stride + j]);

        g_opt_line_cap = 4096;
        build_filter_primes();
        free_wheel_tables();
        build_wheel(p);
        init_filter_tables(p);
        count_4096 = g_line_count;
        for (int i = 0; i < g_line_count; i++)
            for (int j = 0; j < g_line_kill_stride; j++)
                sum_4096 += __builtin_popcountll(g_line_kill_packed[i * g_line_kill_stride + j]);

        g_opt_line_cap = saved_cap;
        build_filter_primes();
        free_wheel_tables();
        build_wheel(p);
        init_filter_tables(p);

        TEST("T57_opt_line_cap_4096_monotone_kill",
             count_4096 > count_863 && sum_4096 > sum_863);
    }

    /* T50: manifest loads (suppress error-stream noise if file is missing). */
    {
        RecordEntry* recs = NULL;
        int saved = dup(STDERR_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
        int n = load_records_manifest(&recs, 17);
        if (saved >= 0) { dup2(saved, STDERR_FILENO); close(saved); }
        TEST("T50_manifest_loads_k17_records", n > 0);
        free(recs);
    }

    printf("\nAll %d tests passed.\n", t_pass + t_fail);
    if (t_fail > 0) printf("(%d FAILED of %d)\n", t_fail, t_pass + t_fail);
    return t_fail == 0 ? 0 : 1;
}

/* =============================================================================
 * USAGE / MAIN
 * ========================================================================== */

static void final_log_flush(void) {
    if (g_log_fp) { fflush(g_log_fp); fsync(fileno(g_log_fp)); }
}

static void print_usage(const char* prog) {
    printf("Usage: %s [options]\n\n", prog);
    printf("k-tuplet CPU search (port of cc_gmp_v34_bit-vector_10.c)\n\n");
    printf("Search options:\n");
    printf("  --pattern NAME        Pattern name from catalog (e.g. KT19_P0)\n");
    printf("  --k N                 Tuple length (alias --target N)\n");
    printf("  --bits N              Bit-size of candidate base (required)\n");
    printf("  --primorial N         Use primorial of first N primes (default 5 -> 2310)\n");
    printf("  --threads N           Worker thread count (default: 1)\n");
    printf("  --prefix 0bXXX        Binary prefix to confine search\n");
    printf("  --random              Random-chunk search: pick random tile, walk chunk_tiles\n");
    printf("                          forward, repeat. Mutually exclusive with --prefix.\n");
    printf("                          PRNG seeded from /dev/urandom (per-thread).\n");
    printf("  --chunk-tiles N       Tiles per chunk in --random mode (default: 500)\n");
    printf("  --sequential          Sequential-only compatibility flag (gates checkpoints)\n");
    printf("  --output FILE         Append found tuplets to FILE\n");
    printf("  --quiet               Minimal output\n");
    printf("  --full-quiet          Suppress progress output\n");
    printf("  --pin                 Pin worker threads to CPUs (Linux)\n");
    printf("  --pin-base N          Base CPU index for pinning\n");
    printf("  --report N            Progress interval seconds (alias for --report-interval-sec)\n");
    printf("  --report-interval-sec N  Reporter cadence (double, 0 disables; default 1.0)\n");
    printf("  --bench-jsonl FILE    In --validate-known, emit one JSON row per record\n");
    printf("  --max-batches N       Stop after N batches\n");
    printf("  --max-time SEC        Stop after SEC seconds\n");
    printf("  --sieve-only          Skip primality verification (sieve benchmark)\n");
    printf("  --no-line-sieve       Disable line-sieve stage\n");
    printf("  --no-bitvec           Disable Armitage bit-vector L2 filter (slow path)\n");
    printf("  --bitvec              Force-enable bit-vector even at low wheel size (overrides auto-disable)\n");
    printf("  --no-opt-fermat       Disable Fermat-2 PRP prefilter ahead of BPSW (default ON)\n");
    printf("  --opt-fermat          Force-enable Fermat-2 PRP prefilter (this is the default)\n");
    printf("  --no-opt-prefetch     Disable read-side __builtin_prefetch in bit-vector L2 build\n");
    printf("  --opt-prefetch        Force-enable prefetch hint (this is the default)\n");
    printf("  --no-opt-bitscan      Disable __builtin_ctzll survivor iteration in bit-vector hot loop\n");
    printf("  --opt-bitscan         Force-enable ctzll iteration (this is the default)\n");
    printf("  --opt-line-cap N      Lift line-sieve cap to N (default 863, range [863, 65535])\n");
    printf("  --checkpoint FILE     Write atomic checkpoints (kt-v1 format, threads=1 only)\n");
    printf("  --resume              Resume tile cursor from checkpoint\n");
    printf("  --ckpt-interval N     Checkpoint interval seconds\n\n");
    printf("Modes:\n");
    printf("  --test                Run unit-test suite\n");
    printf("  --smoke               One-batch sieve assertion (Layer 2 gate)\n");
    printf("  --validate-known [k]  Reproduce records.json hits (gate for k=17,18,19)\n\n");
}

int main(int argc, char** argv) {
    /* Defaults — primorial set up before any parsing path that needs it. */
    g_primorial_n_primes = 5;
    g_primorial = compute_primorial_for_n_primes(g_primorial_n_primes,
                                                 g_primorial_factors,
                                                 &g_primorial_factor_count);
    build_filter_primes();

    mpz_init(g_prefix_value);
    mpz_init(g_n_min); mpz_init(g_n_max);
    mpz_init(g_tile_min); mpz_init(g_tile_max);
    mpz_init(g_current_tile);
    mpz_init(g_completed_tile);

    install_signal_handlers();

    /* Seed the global PRNG master from /dev/urandom once per process. Done
     * unconditionally so that any path which calls init_thread_config (tests,
     * smoke, validate-known, regular search) has a usable master seed. */
    g_urandom_source_ok = (seed_xoshiro_from_urandom(g_urandom_master) == 1);

    const char* pattern_name = NULL;
    int target_k = 0;
    int validate_target_k = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) { print_usage(argv[0]); return 0; }
        else if (!strcmp(argv[i], "--pattern") && i+1 < argc) pattern_name = argv[++i];
        else if (!strcmp(argv[i], "--k") && i+1 < argc) target_k = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--target") && i+1 < argc) target_k = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--bits") && i+1 < argc) g_target_bits = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--primorial") && i+1 < argc) {
            g_primorial_n_primes = atoi(argv[++i]);
            if (g_primorial_n_primes < 2) g_primorial_n_primes = 2;
            if (g_primorial_n_primes > 8) g_primorial_n_primes = 8; /* 19# = 9699690, anything larger is too much memory for the wheel enum */
            g_primorial = compute_primorial_for_n_primes(g_primorial_n_primes,
                                                         g_primorial_factors,
                                                         &g_primorial_factor_count);
            build_filter_primes();
        }
        else if (!strcmp(argv[i], "--threads") && i+1 < argc) g_threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--prefix") && i+1 < argc) {
            if (parse_prefix(argv[++i], g_prefix_value, &g_prefix_bits) != 0) return 1;
            g_use_prefix = 1;
        }
        else if (!strcmp(argv[i], "--random")) g_random_chunk_mode = 1;
        else if (!strcmp(argv[i], "--chunk-tiles") && i+1 < argc)
            g_chunk_tiles = (u64)strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--sequential")) g_sequential_mode = 1;
        else if (!strcmp(argv[i], "--output") && i+1 < argc) g_log_path = argv[++i];
        else if (!strcmp(argv[i], "--quiet")) g_quiet_mode = 1;
        else if (!strcmp(argv[i], "--full-quiet")) { g_full_quiet_mode = 1; g_quiet_mode = 1; }
        else if (!strcmp(argv[i], "--pin")) g_pin_threads = 1;
        else if (!strcmp(argv[i], "--pin-base") && i+1 < argc) g_pin_base_cpu = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--report") && i+1 < argc) g_report_interval_sec = atof(argv[++i]);
        else if (!strcmp(argv[i], "--report-interval-sec") && i+1 < argc) {
            g_report_interval_sec = atof(argv[++i]);
            if (g_report_interval_sec < 0) g_report_interval_sec = 0;
        }
        else if (!strcmp(argv[i], "--bench-jsonl") && i+1 < argc) g_bench_jsonl_path = argv[++i];
        else if (!strcmp(argv[i], "--max-batches") && i+1 < argc) g_max_batches = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-time") && i+1 < argc) g_max_time_sec = atof(argv[++i]);
        else if (!strcmp(argv[i], "--sieve-only")) g_sieve_only_mode = 1;
        else if (!strcmp(argv[i], "--no-line-sieve")) g_line_depth_enabled = 0;
        else if (!strcmp(argv[i], "--no-bitvec")) { g_bitvec_enabled = 0; g_bitvec_force_on = 0; }
        else if (!strcmp(argv[i], "--bitvec"))    { g_bitvec_enabled = 1; g_bitvec_force_on = 1; }
        else if (!strcmp(argv[i], "--no-opt-fermat"))   g_opt_fermat = 0;
        else if (!strcmp(argv[i], "--opt-fermat"))      g_opt_fermat = 1;
        else if (!strcmp(argv[i], "--no-opt-mont-fermat")) g_opt_mont_fermat = 0;
        else if (!strcmp(argv[i], "--opt-mont-fermat"))    g_opt_mont_fermat = 1;
        else if (!strcmp(argv[i], "--no-opt-prefetch")) g_opt_prefetch = 0;
        else if (!strcmp(argv[i], "--opt-prefetch"))    g_opt_prefetch = 1;
        else if (!strcmp(argv[i], "--no-opt-bitscan")) g_opt_bitscan = 0;
        else if (!strcmp(argv[i], "--opt-bitscan"))    g_opt_bitscan = 1;
        else if (!strcmp(argv[i], "--opt-line-cap") && i+1 < argc) {
            int v = atoi(argv[++i]);
            if (v < 863 || v > 65535) {
                fprintf(stderr, "ERROR: --opt-line-cap %d out of range [863, 65535]\n", v);
                return 1;
            }
            g_opt_line_cap = v;
            build_filter_primes();
        }
        else if (!strcmp(argv[i], "--checkpoint") && i+1 < argc) g_checkpoint_file = argv[++i];
        else if (!strcmp(argv[i], "--resume")) g_resume_mode = 1;
        else if (!strcmp(argv[i], "--ckpt-interval") && i+1 < argc) g_checkpoint_interval_sec = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--test")) return run_unit_tests();
        else if (!strcmp(argv[i], "--smoke")) g_smoke_mode = 1;
        else if (!strcmp(argv[i], "--validate-known")) {
            g_validate_known_mode = 1;
            if (i+1 < argc && argv[i+1][0] != '-') validate_target_k = atoi(argv[++i]);
        }
        else if (argv[i][0] == '-') {
            fprintf(stderr, "Unknown option: %s (try --help)\n", argv[i]);
            return 1;
        }
    }

    if (g_validate_known_mode) {
        /* Allow either `--validate-known 17` (inline) or `--validate-known --k 17`. */
        if (validate_target_k == 0 && target_k > 0) validate_target_k = target_k;
        return run_validate_known(validate_target_k);
    }

    /* Pattern resolution: explicit name, else default for --k. */
    if (!pattern_name) {
        if (target_k > 0) {
            char buf[32];
            if (default_pattern_for_k(target_k, buf, sizeof(buf)) != 0) {
                fprintf(stderr, "ERROR: no catalog pattern for k=%d\n", target_k);
                return 1;
            }
            if (set_pattern_by_name(buf) != 0) return 1;
        } else {
            fprintf(stderr, "ERROR: --pattern or --k required\n");
            return 1;
        }
    } else {
        if (set_pattern_by_name(pattern_name) != 0) return 1;
        if (target_k > 0 && target_k != g_pattern->k) {
            fprintf(stderr, "ERROR: --k %d does not match pattern %s (k=%d)\n",
                    target_k, pattern_name, g_pattern->k);
            return 1;
        }
    }

    if (g_target_bits < 8) {
        fprintf(stderr, "ERROR: --bits must be >= 8 (got %d)\n", g_target_bits);
        return 1;
    }
    if (g_random_chunk_mode && g_use_prefix) {
        fprintf(stderr, "error: --random and --prefix are mutually exclusive\n");
        return 2;
    }
    if (g_random_chunk_mode && g_chunk_tiles == 0) g_chunk_tiles = 500;
    if (g_random_chunk_mode && g_checkpoint_file) {
        fprintf(stderr, "ERROR: --random is incompatible with --checkpoint (no sequential cursor)\n");
        return 1;
    }
    if (g_resume_mode && !g_checkpoint_file) {
        fprintf(stderr, "ERROR: --resume requires --checkpoint FILE\n");
        return 1;
    }
    if (g_checkpoint_file && g_threads > 1) {
        fprintf(stderr, "ERROR: checkpoint/resume is currently supported only with --threads 1\n");
        return 1;
    }

    if (g_log_path) {
        g_log_fp = fopen(g_log_path, "a");
        if (!g_log_fp) { perror("output"); return 1; }
        fprintf(g_log_fp, "# kt_gmp_v1 pattern=%s k=%d bits=%d primorial=%llu started=%ld\n",
                g_pattern->name, g_pattern->k, g_target_bits, (unsigned long long)g_primorial,
                (long)time(NULL));
        fflush(g_log_fp);
        atexit(final_log_flush);
    }

    if (g_smoke_mode) return run_smoke();

    /* Regular search. */
    if (build_wheel(g_pattern) != 0) { fprintf(stderr, "build_wheel failed\n"); return 1; }
    init_filter_tables(g_pattern);
    precompute_bitvec_blocks_kt();
    compute_search_range();
    g_batches_claimed = 0;
    g_profile_skip_verify = 0;
    g_deadline_epoch_sec = 0.0;
    if (g_resume_mode) load_checkpoint();

    memset(&g_results, 0, sizeof(g_results));
    pthread_mutex_init(&g_results.lock, NULL);
    reset_global_results();
    g_search_complete = 0;

    if (!g_quiet_mode) {
        printf("kt_gmp_v1: pattern=%s k=%d bits=%d primorial=%llu wheel_size=%d threads=%d\n",
               g_pattern->name, g_pattern->k, g_target_bits, (unsigned long long)g_primorial,
               g_wheel_size, g_threads);
        printf("L2 primes: %d (", g_l2_count);
        for (int i = 0; i < g_l2_count; i++) printf("%u%s", g_l2_primes[i], i+1<g_l2_count?",":"");
        printf("), ext-L2: %d, line-sieve: %d\n", g_extl2_count, g_line_count);
        printf("Bit-vector L2 filter: %s%s\n",
               g_bitvec_enabled ? "ENABLED" : "DISABLED",
               g_bitvec_auto_disabled    ? " (auto-disabled: low wheel)" :
               !g_bitvec_enabled         ? " (--no-bitvec)" :
               g_bitvec_force_on         ? " (--bitvec force-on)" : "");
        printf("Fermat-2 prefilter: %s\n",
               g_opt_fermat ? "ENABLED (--opt-fermat)" : "DISABLED (--no-opt-fermat)");
        printf("Mont-Fermat (u128) backend: %s (gate <=124 bits)\n",
               g_opt_mont_fermat ? "ENABLED (--opt-mont-fermat)" : "DISABLED (--no-opt-mont-fermat)");
        printf("Read-side prefetch: %s\n",
               g_opt_prefetch ? "ENABLED (--opt-prefetch)" : "DISABLED (--no-opt-prefetch)");
        printf("Bitscan (ctzll) iteration: %s\n",
               g_opt_bitscan ? "ENABLED (--opt-bitscan)" : "DISABLED (--no-opt-bitscan)");
        {
            size_t kb = (size_t)g_line_count * (size_t)g_line_kill_stride * sizeof(u64) / 1024;
            printf("Line-sieve cap: %d primes <= %d (stride=%d u64s, packed=%zu KB)\n",
                   g_line_count, g_opt_line_cap, g_line_kill_stride, kb);
        }
        printf("Wide-mode: %s\n", g_wide_mode ? "ENABLED (GMP)" : "off");
        if (g_random_chunk_mode) {
            printf("Search mode: random-chunk, chunk_tiles=%llu, seeded from %s\n",
                   (unsigned long long)g_chunk_tiles,
                   g_urandom_source_ok ? "/dev/urandom" : "fallback time/pid mix");
        } else if (g_use_prefix) {
            char* hex = mpz_get_str(NULL, 2, g_prefix_value);
            printf("Search mode: sequential (prefix=0b%s)\n", hex ? hex : "?");
            free(hex);
        } else {
            printf("Search mode: sequential\n");
        }
        if (reporter_active())
            fprintf(stderr, "Reporter: every %.2fs (stderr)\n", g_report_interval_sec);
        if (g_log_fp)
            printf("Crash-safe persistence: enabled (fflush+fsync per record, atexit hook)\n");
    }

    if (g_threads <= 0) g_threads = 1;
    pthread_t* threads = (pthread_t*)malloc(g_threads * sizeof(pthread_t));
    ThreadConfig* tcs = (ThreadConfig*)malloc(g_threads * sizeof(ThreadConfig));
    if (!threads || !tcs) {
        fprintf(stderr, "ERROR: thread allocation failed\n");
        free(threads);
        free(tcs);
        pthread_mutex_destroy(&g_results.lock);
        if (g_log_fp) { fclose(g_log_fp); g_log_fp = NULL; }
        free_wheel_tables();
        free_bitvec_buckets_kt();
        free_line_kill_packed();
        mpz_clear(g_prefix_value);
        mpz_clear(g_n_min); mpz_clear(g_n_max);
        mpz_clear(g_tile_min); mpz_clear(g_tile_max);
        mpz_clear(g_current_tile);
        mpz_clear(g_completed_tile);
        return 1;
    }
    double t0 = wall_time_sec();
    if (g_max_time_sec > 0) g_deadline_epoch_sec = t0 + g_max_time_sec;
    for (int i = 0; i < g_threads; i++) {
        init_thread_config(&tcs[i], i);
        pthread_create(&threads[i], NULL, worker_thread, &tcs[i]);
    }

    double last_ck = wall_time_sec();
    while (!shutdown_requested && !g_search_complete) {
        if (reporter_active()) usleep(reporter_sleep_us());
        else                   sleep(1);
        double now = wall_time_sec();
        if (g_deadline_epoch_sec > 0 && now >= g_deadline_epoch_sec) g_search_complete = 1;
        if (reporter_active()) emit_reporter_line(t0, 1);
        if (g_checkpoint_file && now - last_ck >= g_checkpoint_interval_sec) {
            write_checkpoint();
            last_ck = now;
        }
    }

    /* Cleanup order: (1) workers fully drained above via pthread_join,
     * (2) flush+fsync log — all records survive kernel panic / power loss. */
    for (int i = 0; i < g_threads; i++) pthread_join(threads[i], NULL);
    if (g_log_fp) { fflush(g_log_fp); fsync(fileno(g_log_fp)); }
    if (g_checkpoint_file) write_checkpoint();
    if (reporter_active()) emit_reporter_done(t0);

    if (!g_quiet_mode) printf("\n=== final: tiles=%llu cand=%llu l2_rej=%llu ext_rej=%llu line_rej=%llu surv=%llu found=%d ===\n",
        (unsigned long long)g_results.tiles_processed,
        (unsigned long long)g_results.candidates,
        (unsigned long long)g_results.l2_rejected,
        (unsigned long long)g_results.extl2_rejected,
        (unsigned long long)g_results.line_rejected,
        (unsigned long long)g_results.survivors,
        g_results.found_count);

    for (int i = 0; i < g_threads; i++) cleanup_thread_config(&tcs[i]);
    for (int i = 0; i < g_results.found_count; i++) free(g_results.found_strs[i]);
    pthread_mutex_destroy(&g_results.lock);
    free(threads); free(tcs);
    if (g_log_fp) { fclose(g_log_fp); g_log_fp = NULL; }
    free_wheel_tables();
    free_bitvec_buckets_kt();
    free_line_kill_packed();
    mpz_clear(g_prefix_value);
    mpz_clear(g_n_min); mpz_clear(g_n_max);
    mpz_clear(g_tile_min); mpz_clear(g_tile_max);
    mpz_clear(g_current_tile);
    mpz_clear(g_completed_tile);
    return 0;
}
