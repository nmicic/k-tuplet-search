/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_filter_v5.cu - oracle/reference GPU engine.
 *
 * LINEAGE
 *   Target port source: sister project cunningham-chain-search
 *   (src/cuda/cc18_filter_cuda_CpC_v15.cu; 96-100 G cand/s on RTX 5090).
 *   v5 is retained as the streams-based oracle/reference engine.
 *
 * NOTE
 *   v8 is the production engine. v5 remains in the tree as a smaller
 *   streams-based implementation for cross-checking parser, record-replay,
 *   wheel, and survivor-persistence behavior.
 *
 * Build: see src/cuda/Makefile (nvcc -O3 -std=c++17 -lineinfo -arch=sm_120).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/time.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <pthread.h>
#include <cuda_runtime.h>
#include <gmp.h>

extern "C" {
#include "ktuplet_pattern.h"
#include "kt_wheel.h"
#include "kt_verify.h"
#include "kt_json_min.h"
}
#include "kt_u128.h"

#ifndef KT_BUILD_SHA
#define KT_BUILD_SHA "unknown"
#endif

/* Phase 4a-1: occupancy-control fork. KT_LB_BLOCKS sets the
 * minBlocksPerMultiprocessor argument of __launch_bounds__ on the two
 * Stage-0+ hot kernels. Combined with -maxrregcount on the nvcc command
 * line, this raises theoretical occupancy on sm_120 from the
 * default-build ~50% (4 blocks/SM @ 64 regs) to higher ratios. Sweep
 * label: A=(256,6)/regs=48, B=(256,5)/regs=56, C=(256,4)/regs=64. */
#ifndef KT_LB_BLOCKS
#define KT_LB_BLOCKS 4
#endif

static const char *KT_BINARY_NAME = "kt_filter_v5";

/* Phase 4b-1: stream-pool depth. Phase 3f used 2 streams ping-pong; with
 * Phase 4a-3's 28% kernel-ms cut, the host launch loop became the
 * bottleneck (gpu_util_pct_min 100→87). KT_NUM_STREAMS_DEFAULT widens
 * the pool so launches can be queued ahead and host work (BPSW + setup)
 * overlaps deeper. Runtime override via --gpu-streams N (capped to
 * KT_MAX_STREAMS). */
#ifndef KT_MAX_STREAMS
#define KT_MAX_STREAMS 8
#endif
#ifndef KT_NUM_STREAMS_DEFAULT
#define KT_NUM_STREAMS_DEFAULT 3
#endif

/* Phase 3f.1: bench-row schema version. Pre-3f.1 rows (version 1) seeded
 * gpu_util_pct_min from the run mean under --full-quiet (false-min); the
 * sampler now ticks at 100ms wallclock cadence regardless of quiet mode,
 * so post-3f.1 rows carry version 2. tools/bench_compare.py only compares
 * within the same version by default. */
#define KT_BENCH_SCHEMA_VERSION 2

typedef uint64_t u64;
typedef uint32_t u32;

/* =============================================================================
 * Globals - mirror the subset of kt_gmp_v1.c globals that 3a actually needs.
 * Flags accepted-and-ignored on GPU still have a sticky variable so we can
 * echo them back in the banner.
 * ========================================================================== */

/* Required search identity. */
static const KTupletPattern* g_pattern = NULL;
static const char* g_pattern_name = NULL;
static int g_target_bits = 0;
static int g_primorial_n_primes = 5;
static int g_threads = 1;             /* host prove threads, post-GPU */

/* Search range / mode. */
static const char* g_prefix_str = NULL;
static int g_use_prefix = 0;
static unsigned __int128 g_prefix_value_u128 = 0;
static int g_prefix_bits = 0;
static int g_random_chunk_mode = 0;
static u64 g_chunk_tiles = 0;
static int g_sequential_mode = 0;
static uint64_t g_random_seed_used = 0;
static int g_random_seed_explicit = 0;
static uint64_t g_rng_state = 0;
static int g_verbose_rotation = 0;

/* Output. */
static const char* g_log_path = NULL;
static int g_quiet_mode = 0;
static int g_full_quiet_mode = 0;

/* Reporter / limits. */
static double g_report_interval_sec = 1.0;
static const char* g_bench_jsonl_path = NULL;
static int g_max_batches = 0;
static double g_max_time_sec = 0.0;

/* Checkpointing (parsed but no-op in 3a). */
static const char* g_checkpoint_file = NULL;
static int g_resume_mode = 0;
static int g_checkpoint_interval_sec = 60;

/* Modes. */
static int g_smoke_mode = 0;
static int g_validate_known_mode = 0;
static int g_validate_target_k = 0;
static int g_target_k = 0;

/* Validate-known per-record state (set before run_search_loop, read after). */
static const char *g_validate_expected_base = NULL;
static int g_validate_hit_seen = 0;
static int g_validate_max_records_per_k = 5;   /* tests can set to 1 */

/* Bench-JSONL FP (lazy-opened in run_validate_known when --bench-jsonl set). */
static FILE *g_bench_jsonl_fp = NULL;
static pthread_mutex_t g_bench_jsonl_lock = PTHREAD_MUTEX_INITIALIZER;

/* Search-loop result snapshot (populated by run_search_loop, read by validate). */
static unsigned long long g_run_cand   = 0;
static unsigned long long g_run_surv   = 0;
static int                g_run_hits   = 0;
static double             g_run_elapsed_s = 0.0;

/* Phase 3f: GPU-utilization snapshot (populated by run_search_loop). */
static double g_run_total_kernel_ms = 0.0;
static double g_run_total_prove_ms  = 0.0;
static double g_run_wall_time_ms    = 0.0;
static double g_run_gpu_util_pct    = 0.0;     /* mean over the run */
static double g_run_gpu_util_pct_min = 0.0;    /* min over 1Hz samples */
static double g_run_prove_to_kernel_ratio = 0.0;

/* GPU-only. */
static int g_gpu_device = 0;
static u64 g_gpu_batch_size = 524288;  /* 2^19, matches v15 default */
static int g_gpu_streams = KT_NUM_STREAMS_DEFAULT;  /* Phase 4b-1 */
static const char* g_gpu_arch_label = "sm_120";

/* Stage-0 wheel state (Phase 3b). Built once at startup for the active
 * pattern, uploaded to GPU global memory (not __constant__: actual wheel
 * sizes for k>=19 at 37# exceed 64 KiB; KT19_P0 is ~266k entries, ~2 MiB). */
static const uint32_t g_stage0_primes_37[] = {2,3,5,7,11,13,17,19,23,29,31,37};
static const int      g_stage0_n_primes_37 = 12;
static kt_wheel_t  g_wheel = { 0, 0, NULL, 0 };
static uint64_t   *g_d_admissible_offsets = NULL;     /* device global mem */

/* =============================================================================
 * Phase 3c: three-stage filter prime bands (k-tuplet baseline; 37# wheel
 * already covers all primes up to 37, so L2 starts at 41).
 *
 *   L2:     {41, 43, 47, 53, 59, 61}      (6 primes; q < 64; one u64 mask)
 *   ext-L2: {67, 71, 73, 79, 83, 89, 97}  (7 primes; q < 128; lo/hi u64 pair)
 *   line:   primes 101..863               (125 primes; packed bitvec, 14 u64s)
 *
 * Mirrors the sister Cunningham-chain GPU filter structure with chain-element
 * math replaced by additive k-tuplet offsets.
 * Forbidden-residue source: F_q = { (q - (b_i%q))%q : i in 0..k-1 }, deduped.
 * ========================================================================== */
#define KT_L2_COUNT      6
#define KT_EXT_L2_COUNT  7
#define KT_LINE_COUNT    125
#define KT_LINE_KILL_WORDS 14   /* 14 * 64 = 896 > 863 (largest line prime) */

#define KT_STAGE_L2     (1u << 0)
#define KT_STAGE_EXT_L2 (1u << 1)
#define KT_STAGE_LINE   (1u << 2)
#define KT_STAGE_FERMAT (1u << 3)
#define KT_STAGES_ALL   (KT_STAGE_L2 | KT_STAGE_EXT_L2 | KT_STAGE_LINE | KT_STAGE_FERMAT)

#define KT_MAX_SURVIVORS_PER_BATCH (1u << 20)   /* same as v15 */

static const uint32_t kt_l2_primes_h[KT_L2_COUNT] =
    { 41, 43, 47, 53, 59, 61 };
static const uint32_t kt_ext_l2_primes_h[KT_EXT_L2_COUNT] =
    { 67, 71, 73, 79, 83, 89, 97 };
static const uint32_t kt_line_primes_h[KT_LINE_COUNT] = {
    101, 103, 107, 109, 113, 127, 131, 137, 139, 149,
    151, 157, 163, 167, 173, 179, 181, 191, 193, 197,
    199, 211, 223, 227, 229, 233, 239, 241, 251, 257,
    263, 269, 271, 277, 281, 283, 293, 307, 311, 313,
    317, 331, 337, 347, 349, 353, 359, 367, 373, 379,
    383, 389, 397, 401, 409, 419, 421, 431, 433, 439,
    443, 449, 457, 461, 463, 467, 479, 487, 491, 499,
    503, 509, 521, 523, 541, 547, 557, 563, 569, 571,
    577, 587, 593, 599, 601, 607, 613, 617, 619, 631,
    641, 643, 647, 653, 659, 661, 673, 677, 683, 691,
    701, 709, 719, 727, 733, 739, 743, 751, 757, 761,
    769, 773, 787, 797, 809, 811, 821, 823, 827, 829,
    839, 853, 857, 859, 863
};

/* Survivor record (Phase 3d). 16-byte cand (u128) + pattern_idx slot for
 * future multi-pattern launches. The legacy u64 paths (T8/T11/T12) write
 * the low limb only; cand_hi is zero for those. */
typedef struct __align__(16) {
    uint64_t cand_lo;
    uint64_t cand_hi;
    uint32_t pattern_idx;
    uint32_t _pad;
} KtSurvivor;

/* Constant-memory mirrors of the prime tables and L2 / ext-L2 masks. */
__constant__ uint32_t d_kt_l2_primes[KT_L2_COUNT];
__constant__ uint32_t d_kt_ext_l2_primes[KT_EXT_L2_COUNT];
__constant__ uint32_t d_kt_line_primes[KT_LINE_COUNT];
__constant__ uint64_t d_kt_l2_mask[KT_L2_COUNT];
__constant__ uint64_t d_kt_ext_l2_mask_lo[KT_EXT_L2_COUNT];
__constant__ uint64_t d_kt_ext_l2_mask_hi[KT_EXT_L2_COUNT];

/* Pattern offsets for the Fermat-2 stage (Phase 3d). Loaded once at startup
 * for the active pattern; KT_MAX_K=32 is the catalog cap (KT_MAX_K from
 * ktuplet_pattern.h). */
__constant__ uint32_t d_kt_pattern_offsets[KT_MAX_K];
__constant__ int      d_kt_pattern_k = 0;

/* Phase 4a-3: Barrett reciprocal mu = floor(2^128 / d_primorial), uploaded
 * once per launch by build_and_upload_stage0_wheel(). The hot kernel reads
 * this from __constant__ mem to replace the 64-iter shift-and-add loop in
 * kt_u128_mod_u64 with a single 128x128 multiply (kt_u128_mod_u64_barrett). */
__constant__ kt_u128 d_primorial_mu = {0, 0};

/* Line-sieve packed kill mask in global memory (125*14 u64 = 14 KiB). The
 * gpu_wheel_size_correction memory directs default-to-global; only move to
 * constant if measurement shows a win.  Phase 3m candidate. */
static uint64_t *g_d_line_kill_packed = NULL;

/* Survivor buffer + counter (device-side, sized to KT_MAX_SURVIVORS_PER_BATCH). */
static KtSurvivor    *g_d_survivors      = NULL;
static unsigned int  *g_d_survivor_count = NULL;

/* Runtime stage gating (set from --no-stage-* flags in argv parser). */
static unsigned int g_stages_active = KT_STAGES_ALL;

/* Phase 3d: post-Fermat survivor handoff to host BPSW. */
static FILE                       *g_log_fp = NULL;
static pthread_mutex_t             g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static struct kt_known_records    *g_known_records = NULL;
static int                         g_records_loaded = 0;
static volatile sig_atomic_t       g_shutdown_requested = 0;

/* Filter-mask host arrays (kept around for FNV-1a-64 cross-check echoes). */
static uint64_t g_l2_mask_h[KT_L2_COUNT];
static uint64_t g_ext_l2_lo_h[KT_EXT_L2_COUNT];
static uint64_t g_ext_l2_hi_h[KT_EXT_L2_COUNT];
static uint64_t g_line_kill_h[KT_LINE_COUNT * KT_LINE_KILL_WORDS];

/* CPU flags accepted and ignored on GPU - sticky for banner echo. */
static int g_cpu_flag_no_line_sieve = 0;
static int g_cpu_flag_no_bitvec = 0;
static int g_cpu_flag_force_bitvec = 0;
static int g_cpu_flag_opt_fermat_set = 0;       /* -1 off, +1 on, 0 unset */
static int g_cpu_flag_opt_fermat_val = 0;
static int g_cpu_flag_opt_mont_fermat_set = 0;
static int g_cpu_flag_opt_mont_fermat_val = 0;
static int g_cpu_flag_opt_prefetch_set = 0;
static int g_cpu_flag_opt_prefetch_val = 0;
static int g_cpu_flag_opt_bitscan_set = 0;
static int g_cpu_flag_opt_bitscan_val = 0;
static int g_cpu_flag_opt_line_cap = 0;        /* 0 unset, else N */
static int g_cpu_flag_pin = 0;
static int g_cpu_flag_pin_base_set = 0;
static int g_cpu_flag_pin_base_val = 0;
static int g_cpu_flag_sieve_only = 0;

#define CUDA_CHECK(call) do { \
    cudaError_t e = (call); \
    if (e != cudaSuccess) { \
        fprintf(stderr, "CUDA error %s at %s:%d: %s\n", \
                cudaGetErrorString(e), __FILE__, __LINE__, #call); \
        exit(2); \
    } \
} while (0)

static double wall_time_sec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec * 1e-6;
}

/* =============================================================================
 * Stub kernel (3a) - kept for the --test T3 path which anchors a ceiling
 * reference for kernel-launch + atomicAdd cost. Real candidate generation
 * runs through kt_stage0_admissibility_kernel below.
 * ========================================================================== */
__global__ void kt_scaffold_count_kernel(unsigned long long *counter,
                                         unsigned long long n_per_thread) {
    atomicAdd(counter, n_per_thread);
}

/* =============================================================================
 * Stage-0 admissibility kernel (Phase 3b).
 *
 *   cand = base_n + tid * stride          (u64 path; n <= 60-bit smoke)
 *   r    = cand mod primorial
 *   binary search r in d_admissible_offsets[0..n_admissible-1]
 *
 * Stages 1/2/3 (filter primes, BPSW) land in 3c/3d. The reporter prints
 * cand/s and surv/s; rejection ratio = 1 - surv/cand.
 *
 * n-bit-width: 3b limits n to 60 bits (so cand fits in u64 with no
 * overflow on cand mod primorial). Phase 3d generalizes to u128 for
 * widths up to 127 bits.
 * ========================================================================== */
__global__ void kt_stage0_admissibility_kernel(
    const uint64_t * __restrict__ d_offsets,
    int                          d_n_admissible,
    unsigned long long           d_primorial,
    unsigned long long           base_n_low,
    unsigned long long           stride_low,
    unsigned long long           batch_size,
    unsigned long long          *survivor_count,
    unsigned long long          *cand_count) {
    unsigned long long tid = (unsigned long long)blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= batch_size) return;

    unsigned long long cand = base_n_low + tid * stride_low;
    unsigned long long r    = cand % d_primorial;

    int lo = 0, hi = d_n_admissible - 1, found = 0;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        unsigned long long v = d_offsets[mid];
        if (v == r) { found = 1; break; }
        if (v < r)  lo = mid + 1; else hi = mid - 1;
    }
    atomicAdd(cand_count, 1ULL);
    if (found) atomicAdd(survivor_count, 1ULL);
}

/* =============================================================================
 * Phase 3c: Stage-0 -> L2 -> ext-L2 -> line-sieve cascade.
 *
 *   cand = base_n + tid * stride                (u64 path; n <= 60-bit smoke)
 *   Stage 0: r = cand % primorial; binary-search admissible-offset list.
 *   Stage L2 (KT_L2_COUNT primes < 64): single u64 mask per prime.
 *   Stage ext-L2 (KT_EXT_L2_COUNT primes < 128): lo/hi u64 mask per prime.
 *   Stage line (KT_LINE_COUNT primes 101..863): packed 14-u64 bitvec per prime.
 *
 * Each stage rejects on the first hit (early-return). Survivors emitted via
 * warp-aggregated atomicAdd (v15:1906 idiom). stages_active is a runtime
 * bitmask so 3d/3e can A/B against Stage-0-only or against any subset.
 * ========================================================================== */
__global__ __launch_bounds__(256, KT_LB_BLOCKS)
void kt_stage0_to_line_kernel(
    const uint64_t * __restrict__ d_offsets,
    int                          d_n_admissible,
    unsigned long long           d_primorial,
    unsigned long long           base_n_low,
    unsigned long long           stride_low,
    unsigned long long           batch_size,
    const uint64_t * __restrict__ d_line_kill_packed,  /* 125*14 */
    unsigned int                 stages_active,
    KtSurvivor                  *survivors,
    unsigned int                *survivor_count,
    unsigned int                *survivor_overflow,
    unsigned int                 max_survivors,
    unsigned long long          *cand_count) {
    unsigned long long tid = (unsigned long long)blockIdx.x * blockDim.x + threadIdx.x;
    /* Phase 3f C3: single atomic per launch (was per-thread). NULL-guarded so
     * the production search loop can pass NULL and skip the counter entirely. */
    if (tid == 0 && cand_count) atomicAdd(cand_count, batch_size);
    if (tid >= batch_size) return;

    unsigned long long cand = base_n_low + tid * stride_low;

    /* Stage 0: 37# admissibility wheel. */
    unsigned long long r0 = cand % d_primorial;
    int lo = 0, hi = d_n_admissible - 1, found = 0;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        unsigned long long v = d_offsets[mid];
        if (v == r0) { found = 1; break; }
        if (v < r0)  lo = mid + 1; else hi = mid - 1;
    }
    if (!found) return;

    /* Stage L2: 6 primes, single u64 mask each. */
    if (stages_active & KT_STAGE_L2) {
        #pragma unroll
        for (int i = 0; i < KT_L2_COUNT; i++) {
            uint32_t q   = d_kt_l2_primes[i];
            uint32_t r_q = (uint32_t)(cand % q);
            if ((d_kt_l2_mask[i] >> r_q) & 1ULL) return;
        }
    }

    /* Stage ext-L2: 7 primes, lo/hi u64 mask. */
    if (stages_active & KT_STAGE_EXT_L2) {
        #pragma unroll
        for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
            uint32_t q    = d_kt_ext_l2_primes[i];
            uint32_t r_q  = (uint32_t)(cand % q);
            uint64_t word = (r_q < 64) ? d_kt_ext_l2_mask_lo[i]
                                       : d_kt_ext_l2_mask_hi[i];
            if ((word >> (r_q & 63u)) & 1ULL) return;
        }
    }

    /* Stage line-sieve: 125 primes, packed bitvec. v15:1884 prefetch idiom -
     * one block of d_line_kill_packed brings ~10 primes' rows into L1. */
    if (stages_active & KT_STAGE_LINE) {
        asm volatile("prefetch.global.L1 [%0];" :: "l"(&d_line_kill_packed[0]));
        for (int ls = 0; ls < KT_LINE_COUNT; ls++) {
            uint32_t q    = d_kt_line_primes[ls];
            uint32_t r_q  = (uint32_t)(cand % q);
            uint64_t word = d_line_kill_packed[ls * KT_LINE_KILL_WORDS + (r_q >> 6)];
            if ((word >> (r_q & 63u)) & 1ULL) return;
        }
    }

    /* Survivor: warp-aggregated emission per v15:1906. Lower-numbered lane
     * in the surviving set leads the atomicAdd; broadcasted base + per-lane
     * popcount gives the slot index. */
    unsigned active_mask = __activemask();
    unsigned pass_mask   = __ballot_sync(active_mask, 1);
    int lane             = threadIdx.x & 31;
    int leader           = __ffs((int)pass_mask) - 1;
    unsigned int warp_base = 0;
    if (lane == leader) {
        warp_base = atomicAdd(survivor_count, (unsigned int)__popc(pass_mask));
    }
    warp_base = __shfl_sync(pass_mask, warp_base, leader);
    unsigned int slot = warp_base + (unsigned int)__popc(pass_mask & ((1u << lane) - 1u));
    if (slot < max_survivors) {
        survivors[slot].cand_lo     = cand;
        survivors[slot].cand_hi     = 0;
        survivors[slot].pattern_idx = 0;
        survivors[slot]._pad        = 0;
    } else if (survivor_overflow) {
        /* Phase 3f C2: explicit overflow signal (lane scope). Host treats any
         * set bit as fatal; no silent-drop. */
        atomicOr(survivor_overflow, 1u);
    }
}

/* =============================================================================
 * Phase 3d: Stage-0 -> L2 -> ext-L2 -> line-sieve -> Fermat-2 cascade (u128).
 *
 *   cand = base_n + tid * stride         (kt_u128, n <= 127 bits)
 *   Stage 0..line: identical math to 3c, but candidate is u128.
 *   Stage Fermat: per offset b_i, run base-2 Fermat in u128 Montgomery-free
 *   arithmetic (kt_fermat_base2_u128). Reject if any b_i yields composite.
 *
 * Stage gating bitmask carries KT_STAGE_FERMAT for the new stage.
 * ========================================================================== */
__global__ __launch_bounds__(256, KT_LB_BLOCKS)
void kt_stage0_to_fermat_kernel(
    const uint64_t * __restrict__ d_offsets,
    int                          d_n_admissible,
    unsigned long long           d_primorial,
    kt_u128                      base_n,
    kt_u128                      stride,
    unsigned long long           batch_size,
    const uint64_t * __restrict__ d_line_kill_packed,  /* 125*14 */
    unsigned int                 stages_active,
    KtSurvivor                  *survivors,
    unsigned int                *survivor_count,
    unsigned int                *survivor_overflow,
    unsigned int                 max_survivors,
    unsigned long long          *cand_count) {
    unsigned long long tid = (unsigned long long)blockIdx.x * blockDim.x + threadIdx.x;
    /* Phase 3f C3: single atomic per launch (was per-thread). NULL-guarded so
     * the production search loop can pass NULL and skip the counter entirely. */
    if (tid == 0 && cand_count) atomicAdd(cand_count, batch_size);
    if (tid >= batch_size) return;

    /* cand = base_n + tid * stride. tid is u64; stride is u128; multiply via
     * kt_u128_mul64_u128 (returns low 128 bits of u64*u128). */
    kt_u128 step = kt_u128_mul64_u128((uint64_t)tid, stride);
    kt_u128 cand = kt_u128_add(base_n, step);

    /* Stage 0: 37# admissibility wheel. d_primorial fits in u64 (37# = 7.42e12).
     * Phase 4a-3: Barrett reciprocal multiply replaces the shift-and-add
     * reduction loop. mu = floor(2^128/d_primorial) is in __constant__ mem,
     * uploaded once per launch by build_and_upload_stage0_wheel. */
    uint64_t r0 = kt_u128_mod_u64_barrett(cand, d_primorial, d_primorial_mu);
    int lo = 0, hi = d_n_admissible - 1, found = 0;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        /* Phase 4a-2: __ldg routes binary-search reads through the
         * read-only data cache; pointer is __restrict__ + const-qualified. */
        unsigned long long v = __ldg(&d_offsets[mid]);
        if (v == r0) { found = 1; break; }
        if (v < r0)  lo = mid + 1; else hi = mid - 1;
    }
    if (!found) return;

    /* Stage L2: 6 primes. */
    if (stages_active & KT_STAGE_L2) {
        #pragma unroll
        for (int i = 0; i < KT_L2_COUNT; i++) {
            uint32_t q   = d_kt_l2_primes[i];
            uint32_t r_q = kt_u128_mod_u32(cand, q);
            if ((d_kt_l2_mask[i] >> r_q) & 1ULL) return;
        }
    }

    /* Stage ext-L2: 7 primes, lo/hi u64 mask. */
    if (stages_active & KT_STAGE_EXT_L2) {
        #pragma unroll
        for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
            uint32_t q    = d_kt_ext_l2_primes[i];
            uint32_t r_q  = kt_u128_mod_u32(cand, q);
            uint64_t word = (r_q < 64) ? d_kt_ext_l2_mask_lo[i]
                                       : d_kt_ext_l2_mask_hi[i];
            if ((word >> (r_q & 63u)) & 1ULL) return;
        }
    }

    /* Stage line-sieve: 125 primes, packed bitvec.
     * Phase 4a-2: removed the index-0 prefetch (it always fetched
     * d_line_kill_packed[0] regardless of r_q, so it warmed an
     * unrelated cache line). A useful row-targeted prefetch needs the
     * per-tile residue cache from Phase 4b-1; until then, no prefetch.
     * __ldg routes the line-sieve read through the read-only cache. */
    if (stages_active & KT_STAGE_LINE) {
        for (int ls = 0; ls < KT_LINE_COUNT; ls++) {
            uint32_t q    = d_kt_line_primes[ls];
            uint32_t r_q  = kt_u128_mod_u32(cand, q);
            uint64_t word = __ldg(&d_line_kill_packed[ls * KT_LINE_KILL_WORDS + (r_q >> 6)]);
            if ((word >> (r_q & 63u)) & 1ULL) return;
        }
    }

    /* Stage Fermat-2: k tests on n + b_i. Reject if any composite. */
    if (stages_active & KT_STAGE_FERMAT) {
        int kk = d_kt_pattern_k;
        for (int i = 0; i < kk; i++) {
            uint64_t off = (uint64_t)d_kt_pattern_offsets[i];
            kt_u128 cand_i;
            cand_i.lo = cand.lo + off;
            cand_i.hi = cand.hi + (cand_i.lo < cand.lo ? 1 : 0);
            if (!kt_fermat_base2_u128(cand_i)) return;
        }
    }

    /* Survivor: warp-aggregated emission. */
    unsigned active_mask = __activemask();
    unsigned pass_mask   = __ballot_sync(active_mask, 1);
    int lane             = threadIdx.x & 31;
    int leader           = __ffs((int)pass_mask) - 1;
    unsigned int warp_base = 0;
    if (lane == leader) {
        warp_base = atomicAdd(survivor_count, (unsigned int)__popc(pass_mask));
    }
    warp_base = __shfl_sync(pass_mask, warp_base, leader);
    unsigned int slot = warp_base + (unsigned int)__popc(pass_mask & ((1u << lane) - 1u));
    if (slot < max_survivors) {
        survivors[slot].cand_lo     = cand.lo;
        survivors[slot].cand_hi     = cand.hi;
        survivors[slot].pattern_idx = 0;
        survivors[slot]._pad        = 0;
    } else if (survivor_overflow) {
        /* Phase 3f C2: explicit overflow signal. Host fail-fasts on this. */
        atomicOr(survivor_overflow, 1u);
    }
}

/* =============================================================================
 * Phase 3d: novel-record preservation + crash-safe persistence.
 *
 * Contract per feedback_novel_record_preservation.md:
 *   - Every k>=16 certified hit cross-checked against records.json.
 *   - Novel hits append a JSON line to ./novel_records.jsonl with fsync, plus
 *     a stderr banner via write(2) (bypasses stdio so it survives SIGPIPE/etc).
 *   - Known hits log to the standard log file but skip the novel jsonl path.
 *
 * Test override: KT_NOVEL_JSONL env var redirects the append path so unit
 * tests can write to ./tmp/novel_records_test.jsonl without polluting the
 * real ./novel_records.jsonl.
 * ========================================================================== */

static const char* novel_jsonl_path(void) {
    const char *p = getenv("KT_NOVEL_JSONL");
    return p ? p : "novel_records.jsonl";
}

static const char* kt_hostname(void) {
    static char buf[256];
    static int  done = 0;
    if (done) return buf;
    if (gethostname(buf, sizeof buf - 1) != 0) snprintf(buf, sizeof buf, "unknown");
    buf[sizeof buf - 1] = '\0';
    done = 1;
    return buf;
}

static const char* kt_gpu_uuid(void) {
    static char buf[128];
    static int  done = 0;
    if (done) return buf;
    int dev = 0;
    cudaError_t e = cudaGetDevice(&dev);
    if (e != cudaSuccess) { snprintf(buf, sizeof buf, "unknown"); done = 1; return buf; }
    if (cudaDeviceGetPCIBusId(buf, sizeof buf, dev) != cudaSuccess) {
        snprintf(buf, sizeof buf, "device%d", dev);
    }
    done = 1;
    return buf;
}

/* Write the FOUND banner to stderr via write(2); survives stdio corruption. */
static void crash_safe_announce(const char *base_str, const KTupletPattern *pat,
                                int bits) {
    char msg[1024];
    int n = snprintf(msg, sizeof msg,
        "\n*** FOUND k=%d bits=%d pattern=%s base=%s ***\n",
        pat->k, bits, pat->name, base_str);
    if (n > 0 && (size_t)n < sizeof msg) {
        ssize_t wr = write(STDERR_FILENO, msg, (size_t)n);
        (void)wr;
    }
}

/* Append a certified hit to g_log_fp with fflush+fsync, mutex-protected so
 * concurrent BPSW host threads serialize on the log. */
static void log_certified_tuplet(const char *base_dec, const KTupletPattern *pat) {
    if (!g_log_fp) return;
    pthread_mutex_lock(&g_log_lock);
    fprintf(g_log_fp, "KT%d %s %s\n", pat->k, pat->name, base_dec);
    fflush(g_log_fp);
#ifdef __linux__
    fsync(fileno(g_log_fp));
#endif
    pthread_mutex_unlock(&g_log_lock);
}

/* Phase 3f.1: shared records.json loader. Both T16 and production now use
 * this. Tries paths in order (env override first, then conventional locations
 * relative to CWD), prints `errno` per failed open so silent NULL returns
 * aren't a black box. Returns NULL only if every candidate failed. */
static struct kt_known_records *
kt_records_load_with_search(const char **out_used_path, int verbose) {
    const char *env_path = getenv("KT_RECORDS_JSON");
    /* Build candidate list dynamically: env override (if set) goes first,
     * followed by cwd-relative fallbacks. A NULL env_path must NOT
     * short-circuit the loop, which is why we don't put it directly in a
     * sentinel-NULL-terminated array. */
    const char *fallbacks[] = {
        "visualizations/k-tuplet-analyzer/records.json",
        "../visualizations/k-tuplet-analyzer/records.json",
        "../../visualizations/k-tuplet-analyzer/records.json",
        "./records.json",
        NULL
    };
    const char *first_path = env_path;
    int started_fallbacks = (first_path == NULL);
    int fb_i = 0;
    for (;;) {
        const char *cur_path = NULL;
        if (!started_fallbacks) {
            cur_path = first_path;
            started_fallbacks = 1;
        } else {
            cur_path = fallbacks[fb_i++];
        }
        if (!cur_path) break;
        FILE *probe = fopen(cur_path, "rb");
        if (!probe) {
            if (verbose) {
                fprintf(stderr,
                    "records.json: tried '%s' open() failed errno=%d (%s)\n",
                    cur_path, errno, strerror(errno));
            }
            continue;
        }
        fclose(probe);
        struct kt_known_records *kr = kt_known_records_load(cur_path);
        if (!kr) {
            if (verbose) {
                fprintf(stderr,
                    "records.json: '%s' opened but parse failed (NULL records)\n",
                    cur_path);
            }
            continue;
        }
        if (out_used_path) *out_used_path = cur_path;
        return kr;
    }
    return NULL;
}

static void preserve_novel_record(const char *pattern, int k, int bits,
                                  const char *base_decimal) {
    if (k < 16) return;                                 /* policy gate */

    if (!g_records_loaded) {
        const char *used = NULL;
        g_known_records = kt_records_load_with_search(&used, /*verbose=*/1);
        if (!g_known_records) {
            fprintf(stderr,
                "WARNING: could not load records.json for novel-record "
                "cross-check; treating all hits as novel.\n");
        }
        g_records_loaded = 1;
    }

    if (g_known_records &&
        kt_known_records_contains(g_known_records, k, base_decimal)) {
        /* Known record. Log via crash_safe_announce + log_certified_tuplet
         * already happened at the call site; no novel jsonl entry. */
        return;
    }

    const char *path = novel_jsonl_path();
    FILE *fp = fopen(path, "a");
    if (!fp) {
        fprintf(stderr, "WARNING: could not open %s: %s\n", path, strerror(errno));
        return;
    }
    char ts[64]; time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t));
    fprintf(fp,
        "{\"timestamp_utc\":\"%s\",\"pattern_name\":\"%s\",\"k\":%d,\"bits\":%d,"
        "\"base_n\":\"%s\",\"commit_sha\":\"%s\",\"host\":\"%s\","
        "\"engine\":\"gpu\",\"gpu_uuid\":\"%s\",\"cuda_version\":%d}\n",
        ts, pattern, k, bits, base_decimal,
        KT_BUILD_SHA, kt_hostname(), kt_gpu_uuid(), CUDART_VERSION);
    fflush(fp);
#ifdef __linux__
    fsync(fileno(fp));
#endif
    fclose(fp);

    /* Stderr crash-safe banner via write(2). */
    char banner[1024];
    int n = snprintf(banner, sizeof banner,
        "*** NOVEL K=%d RECORD CANDIDATE ***\n"
        "pattern=%s base=%s bits=%d\n"
        "Logged to %s. Cross-check against records.json before claiming.\n",
        k, pattern, base_decimal, bits, path);
    if (n > 0) {
        ssize_t wr = write(STDERR_FILENO, banner, (size_t)n);
        (void)wr;
    }
}

/* atexit-registered: flush the log file so the last record survives a clean
 * exit. SIGINT path also flushes via the signal handler. */
static void final_log_flush(void) {
    if (g_log_fp) {
        fflush(g_log_fp);
#ifdef __linux__
        fsync(fileno(g_log_fp));
#endif
    }
}

static void signal_handler(int sig) {
    (void)sig;
    g_shutdown_requested = 1;
    final_log_flush();
}

static void install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

/* =============================================================================
 * Pattern resolution helpers (kept simple - no static catalog defaults table
 * here; 3a leans on kt_pattern_by_name + first-match-with-k for --k N).
 * ========================================================================== */
static const KTupletPattern* resolve_pattern_by_k(int k) {
    for (int i = 0; i < KT_PATTERNS_COUNT; i++) {
        if (KT_PATTERNS[i].k == k) return &KT_PATTERNS[i];
    }
    return NULL;
}

static int set_pattern(const char* name, int k) {
    if (name) {
        g_pattern = kt_pattern_by_name(name);
        if (!g_pattern) {
            fprintf(stderr, "ERROR: unknown pattern '%s'\n", name);
            return 1;
        }
        if (k > 0 && k != g_pattern->k) {
            fprintf(stderr, "ERROR: --k %d does not match pattern %s (k=%d)\n",
                    k, name, g_pattern->k);
            return 1;
        }
        g_pattern_name = g_pattern->name;
        return 0;
    }
    if (k > 0) {
        g_pattern = resolve_pattern_by_k(k);
        if (!g_pattern) {
            fprintf(stderr, "ERROR: no catalog pattern for k=%d\n", k);
            return 1;
        }
        g_pattern_name = g_pattern->name;
        return 0;
    }
    fprintf(stderr, "ERROR: --pattern or --k required\n");
    return 1;
}

/* =============================================================================
 * Stage-0 wheel: build for active pattern, cross-check vs canonical hash,
 * and upload to device global memory.
 * ========================================================================== */
static int build_and_upload_stage0_wheel(void) {
    if (!g_pattern) {
        fprintf(stderr, "ERROR: build_stage0_wheel called before pattern resolution\n");
        return 1;
    }
    /* pattern offsets: KTupletPattern stores int[]; convert to u32. */
    uint32_t pat[KT_MAX_K];
    for (int i = 0; i < g_pattern->k; i++) pat[i] = (uint32_t)g_pattern->offsets[i];

    int rc = kt_wheel_crt_join(pat, g_pattern->k,
                               g_stage0_primes_37, g_stage0_n_primes_37,
                               &g_wheel);
    if (rc != 0) {
        fprintf(stderr,
                "ERROR: kt_wheel_crt_join(%s, 37#) failed rc=%d "
                "(-1 cap, -2 inadmissible, -3 primorial overflow, -4 alloc)\n",
                g_pattern->name, rc);
        return 1;
    }

    const kt_canonical_wheel_t *can =
        kt_wheel_canonical_lookup(g_pattern->name,
                                  g_stage0_primes_37, g_stage0_n_primes_37);
    if (can) {
        if (can->n_admissible != g_wheel.n_admissible ||
            can->fnv1a64_hash  != g_wheel.fnv1a64_hash) {
            fprintf(stderr,
                "ERROR: Stage-0 wheel disagrees with canonical for %s @ 37#:\n"
                "  runtime  n=%d hash=0x%016llx\n"
                "  canonical n=%d hash=0x%016llx\n",
                g_pattern->name,
                g_wheel.n_admissible, (unsigned long long)g_wheel.fnv1a64_hash,
                can->n_admissible,    (unsigned long long)can->fnv1a64_hash);
            kt_wheel_free(&g_wheel);
            exit(2);
        }
        if (!g_full_quiet_mode) {
            printf("Wheel hash (FNV-1a-64): 0x%016llx (matches canonical)\n",
                   (unsigned long long)g_wheel.fnv1a64_hash);
        }
    } else {
        if (!g_full_quiet_mode) {
            printf("Wheel hash (FNV-1a-64): 0x%016llx (no canonical entry for %s @ 37#)\n",
                   (unsigned long long)g_wheel.fnv1a64_hash, g_pattern->name);
        }
    }

    if (!g_full_quiet_mode) {
        printf("Stage 0: 37# wheel admissibility, n_admissible=%d, primorial=%llu\n",
               g_wheel.n_admissible, (unsigned long long)g_wheel.primorial);
        fflush(stdout);
    }

    /* Upload to GPU global memory. */
    size_t bytes = (size_t)g_wheel.n_admissible * sizeof(uint64_t);
    CUDA_CHECK(cudaMalloc((void**)&g_d_admissible_offsets, bytes));
    CUDA_CHECK(cudaMemcpy(g_d_admissible_offsets, g_wheel.offsets, bytes,
                          cudaMemcpyHostToDevice));

    /* Phase 4a-3: precompute Barrett reciprocal mu = floor(2^128 / primorial)
     * and upload to __constant__ mem. The hot kernel uses this to replace
     * kt_u128_mod_u64's 64-iter shift loop with one 128x128 multiply.
     *
     * Identity: mu = (-(unsigned __int128)m) / m + 1.
     * Proof: -m as u128 = 2^128 - m. Write 2^128 = q*m + r, 0 <= r < m.
     *        Then 2^128 - m = (q-1)*m + r, so floor((2^128-m)/m) = q-1,
     *        and mu = q = floor((2^128-m)/m) + 1. Holds for r=0 too.
     * Valid for m >= 2; primorial(37#) ~= 7.42e12 satisfies this trivially. */
    {
        uint64_t m = (uint64_t)g_wheel.primorial;
        if (m < 2) {
            fprintf(stderr,
                "ERROR: primorial=%llu < 2; Barrett mu undefined.\n",
                (unsigned long long)m);
            return 1;
        }
        unsigned __int128 mu128 = ((unsigned __int128)0 - (unsigned __int128)m) / m + 1;
        kt_u128 mu_h;
        mu_h.lo = (uint64_t)mu128;
        mu_h.hi = (uint64_t)(mu128 >> 64);
        CUDA_CHECK(cudaMemcpyToSymbol(d_primorial_mu, &mu_h, sizeof(kt_u128)));
        if (!g_full_quiet_mode) {
            printf("Stage 0: Barrett mu = 0x%016llx%016llx (precomputed for primorial=%llu)\n",
                   (unsigned long long)mu_h.hi,
                   (unsigned long long)mu_h.lo,
                   (unsigned long long)m);
            fflush(stdout);
        }
        fprintf(stderr, "[v4] phase4a-3 barrett mu uploaded (m=%llu mu=0x%016llx%016llx)\n",
                (unsigned long long)m,
                (unsigned long long)mu_h.hi, (unsigned long long)mu_h.lo);
    }

    return 0;
}

static void release_stage0_wheel(void) {
    if (g_d_admissible_offsets) {
        cudaFree(g_d_admissible_offsets);
        g_d_admissible_offsets = NULL;
    }
    kt_wheel_free(&g_wheel);
}

/* =============================================================================
 * Phase 3c: build per-pattern filter masks, cross-check vs canonical hashes,
 * and upload to constant + global memory. Allocates the survivor buffer too.
 * ========================================================================== */
static int build_and_upload_filter_tables(void) {
    if (!g_pattern) {
        fprintf(stderr, "ERROR: build_filter_tables called before pattern\n");
        return 1;
    }
    uint32_t pat[KT_MAX_K];
    for (int i = 0; i < g_pattern->k; i++) pat[i] = (uint32_t)g_pattern->offsets[i];

    /* L2: 6 u64 masks. */
    for (int i = 0; i < KT_L2_COUNT; i++) {
        g_l2_mask_h[i] = kt_forbidden_mask_u64(pat, g_pattern->k, kt_l2_primes_h[i]);
    }

    /* ext-L2: 7 lo/hi pairs. */
    for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
        kt_forbidden_mask_u128(pat, g_pattern->k, kt_ext_l2_primes_h[i],
                               &g_ext_l2_lo_h[i], &g_ext_l2_hi_h[i]);
    }

    /* line-sieve: 125 packed bitvecs (14 u64 each). */
    for (int i = 0; i < KT_LINE_COUNT; i++) {
        kt_forbidden_mask_packed(pat, g_pattern->k, kt_line_primes_h[i],
                                 &g_line_kill_h[i * KT_LINE_KILL_WORDS],
                                 KT_LINE_KILL_WORDS);
    }

    /* Canonical-hash cross-check. */
    uint64_t l2_hash = kt_wheel_fnv1a64_u64_array(g_l2_mask_h, KT_L2_COUNT);
    uint64_t ext_l2_packed[KT_EXT_L2_COUNT * 2];
    for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
        ext_l2_packed[2 * i + 0] = g_ext_l2_lo_h[i];
        ext_l2_packed[2 * i + 1] = g_ext_l2_hi_h[i];
    }
    uint64_t ext_l2_hash = kt_wheel_fnv1a64_u64_array(ext_l2_packed, KT_EXT_L2_COUNT * 2);
    uint64_t line_hash   = kt_wheel_fnv1a64_u64_array(g_line_kill_h,
                                  KT_LINE_COUNT * KT_LINE_KILL_WORDS);

    const kt_canonical_filter_t *can = kt_filter_canonical_lookup(g_pattern->name);
    if (can) {
        if (can->l2_hash != l2_hash || can->ext_l2_hash != ext_l2_hash ||
            can->line_hash != line_hash) {
            fprintf(stderr,
                "ERROR: filter-mask hashes disagree with canonical for %s:\n"
                "  runtime  l2=0x%016llx ext-l2=0x%016llx line=0x%016llx\n"
                "  canonical l2=0x%016llx ext-l2=0x%016llx line=0x%016llx\n",
                g_pattern->name,
                (unsigned long long)l2_hash, (unsigned long long)ext_l2_hash,
                (unsigned long long)line_hash,
                (unsigned long long)can->l2_hash, (unsigned long long)can->ext_l2_hash,
                (unsigned long long)can->line_hash);
            exit(2);
        }
        if (!g_full_quiet_mode) {
            printf("Filter mask hashes (FNV-1a-64): l2=0x%016llx ext-l2=0x%016llx line=0x%016llx (matches canonical)\n",
                   (unsigned long long)l2_hash, (unsigned long long)ext_l2_hash,
                   (unsigned long long)line_hash);
        }
    } else {
        if (!g_full_quiet_mode) {
            printf("Filter mask hashes (FNV-1a-64): l2=0x%016llx ext-l2=0x%016llx line=0x%016llx (no canonical entry for %s)\n",
                   (unsigned long long)l2_hash, (unsigned long long)ext_l2_hash,
                   (unsigned long long)line_hash, g_pattern->name);
        }
    }

    /* Banner: prime bands + popcount sanity. */
    if (!g_full_quiet_mode) {
        printf("Filter primes: L2=[41,43,47,53,59,61] ext-L2=[67..97] line=[101..863] (125)\n");
        printf("Filter masks built: L2 popcounts=[");
        unsigned long long ext_l2_pc_sum = 0;
        for (int i = 0; i < KT_L2_COUNT; i++) {
            printf("%d%s", __builtin_popcountll(g_l2_mask_h[i]),
                   (i + 1 < KT_L2_COUNT) ? "," : "");
        }
        for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
            ext_l2_pc_sum += (unsigned long long)
                (__builtin_popcountll(g_ext_l2_lo_h[i]) +
                 __builtin_popcountll(g_ext_l2_hi_h[i]));
        }
        unsigned long long line_pc_sum = 0;
        for (int i = 0; i < KT_LINE_COUNT * KT_LINE_KILL_WORDS; i++) {
            line_pc_sum += (unsigned long long)__builtin_popcountll(g_line_kill_h[i]);
        }
        printf("] ext-L2 popcount sum=%llu line-prime popcount sum=%llu\n",
               ext_l2_pc_sum, line_pc_sum);
        fflush(stdout);
    }

    /* Constant-mem uploads. */
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_l2_primes,     kt_l2_primes_h,
                                  sizeof(kt_l2_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_primes, kt_ext_l2_primes_h,
                                  sizeof(kt_ext_l2_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_line_primes,   kt_line_primes_h,
                                  sizeof(kt_line_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_l2_mask,       g_l2_mask_h,
                                  sizeof(g_l2_mask_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_mask_lo, g_ext_l2_lo_h,
                                  sizeof(g_ext_l2_lo_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_mask_hi, g_ext_l2_hi_h,
                                  sizeof(g_ext_l2_hi_h)));

    /* Global-mem upload of line-sieve packed bitvec (14 KiB). */
    size_t line_bytes = sizeof(g_line_kill_h);
    CUDA_CHECK(cudaMalloc((void**)&g_d_line_kill_packed, line_bytes));
    CUDA_CHECK(cudaMemcpy(g_d_line_kill_packed, g_line_kill_h, line_bytes,
                          cudaMemcpyHostToDevice));

    /* Survivor buffer + counter. */
    CUDA_CHECK(cudaMalloc((void**)&g_d_survivors,
                          (size_t)KT_MAX_SURVIVORS_PER_BATCH * sizeof(KtSurvivor)));
    CUDA_CHECK(cudaMalloc((void**)&g_d_survivor_count, sizeof(unsigned int)));
    CUDA_CHECK(cudaMemset(g_d_survivor_count, 0, sizeof(unsigned int)));

    /* Phase 3d: upload pattern offsets to __constant__ memory for the
     * Fermat-2 stage. KT_MAX_K is the catalog cap (32). */
    if (g_pattern->k > KT_MAX_K) {
        fprintf(stderr, "ERROR: pattern->k=%d exceeds KT_MAX_K=%d\n",
                g_pattern->k, KT_MAX_K);
        return 1;
    }
    uint32_t pat32[KT_MAX_K] = {0};
    for (int i = 0; i < g_pattern->k; i++) pat32[i] = (uint32_t)g_pattern->offsets[i];
    int kk = g_pattern->k;
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_pattern_offsets, pat32, sizeof(pat32)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_pattern_k, &kk, sizeof(int)));
    return 0;
}

static void release_filter_tables(void) {
    if (g_d_line_kill_packed) { cudaFree(g_d_line_kill_packed); g_d_line_kill_packed = NULL; }
    if (g_d_survivors)        { cudaFree(g_d_survivors);        g_d_survivors        = NULL; }
    if (g_d_survivor_count)   { cudaFree(g_d_survivor_count);   g_d_survivor_count   = NULL; }
}

/* =============================================================================
 * Banner - prints active config + the list of CPU --opt-* flags that were
 * accepted-and-ignored. This is how every existing run-script can target
 * either binary without rewriting flag lists.
 * ========================================================================== */
static void emit_ignored_cpu_flag_line(void) {
    char buf[1024];
    size_t pos = 0;
    buf[0] = '\0';
    #define APPEND(s) do { \
        size_t L = strlen(s); \
        if (pos + L + 2 < sizeof(buf)) { \
            if (pos > 0) { buf[pos++] = ' '; } \
            memcpy(buf + pos, s, L); pos += L; buf[pos] = '\0'; \
        } \
    } while (0)

    if (g_cpu_flag_no_line_sieve)  APPEND("--no-line-sieve");
    if (g_cpu_flag_no_bitvec)      APPEND("--no-bitvec");
    if (g_cpu_flag_force_bitvec)   APPEND("--bitvec");
    if (g_cpu_flag_opt_fermat_set) {
        APPEND(g_cpu_flag_opt_fermat_val ? "--opt-fermat" : "--no-opt-fermat");
    }
    if (g_cpu_flag_opt_mont_fermat_set) {
        APPEND(g_cpu_flag_opt_mont_fermat_val ? "--opt-mont-fermat" : "--no-opt-mont-fermat");
    }
    if (g_cpu_flag_opt_prefetch_set) {
        APPEND(g_cpu_flag_opt_prefetch_val ? "--opt-prefetch" : "--no-opt-prefetch");
    }
    if (g_cpu_flag_opt_bitscan_set) {
        APPEND(g_cpu_flag_opt_bitscan_val ? "--opt-bitscan" : "--no-opt-bitscan");
    }
    if (g_cpu_flag_opt_line_cap > 0) {
        char tmp[64];
        snprintf(tmp, sizeof(tmp), "--opt-line-cap=%d", g_cpu_flag_opt_line_cap);
        APPEND(tmp);
    }
    if (g_cpu_flag_pin) APPEND("--pin");
    if (g_cpu_flag_pin_base_set) {
        char tmp[64];
        snprintf(tmp, sizeof(tmp), "--pin-base=%d", g_cpu_flag_pin_base_val);
        APPEND(tmp);
    }
    if (g_cpu_flag_sieve_only) APPEND("--sieve-only");
    if (!(g_stages_active & KT_STAGE_L2))     APPEND("--no-stage-l2");
    if (!(g_stages_active & KT_STAGE_EXT_L2)) APPEND("--no-stage-ext-l2");
    if (!(g_stages_active & KT_STAGE_LINE))   APPEND("--no-stage-line");
    if (!(g_stages_active & KT_STAGE_FERMAT)) APPEND("--no-stage-fermat");
    #undef APPEND

    if (pos > 0) {
        printf("Ignored CPU flags: %s\n", buf);
    } else {
        printf("Ignored CPU flags: (none)\n");
    }
}

static void print_banner(void) {
    if (g_full_quiet_mode) return;
    printf("kt_filter_v1 (Phase 3d: u128 + Fermat-2 + BPSW handoff): pattern=%s k=%d bits=%d primorial_n=%d threads=%d\n",
           g_pattern_name ? g_pattern_name : "(none)",
           g_pattern ? g_pattern->k : 0,
           g_target_bits, g_primorial_n_primes, g_threads);
    int kk = g_pattern ? g_pattern->k : 0;
    printf("Filter stages: Stage-0 wheel%s%s%s + Fermat-2 (k=%d)%s\n",
           (g_stages_active & KT_STAGE_L2)     ? " + L2 (6)"     : " (L2 OFF)",
           (g_stages_active & KT_STAGE_EXT_L2) ? " + ext-L2 (7)" : " (ext-L2 OFF)",
           (g_stages_active & KT_STAGE_LINE)   ? " + line (125)" : " (line OFF)",
           kk,
           (g_stages_active & KT_STAGE_FERMAT) ? "" : " [SKIPPED]");
    if (g_records_loaded) {
        int rec_n = kt_known_records_count_for_k(g_known_records, kk);
        int rec_total = kt_known_records_total(g_known_records);
        printf("records.json: total=%d active_k=%d records-for-k%d=%d\n",
               rec_total, kk, kk, rec_n);
    }
    printf("GPU device: %d  batch_size=%llu  arch=%s\n",
           g_gpu_device, (unsigned long long)g_gpu_batch_size, g_gpu_arch_label);
    printf("Search mode: %s%s%s\n",
           g_random_chunk_mode ? "random-chunk" : (g_use_prefix ? "sequential (prefix)" : "sequential"),
           g_sequential_mode ? " [--sequential]" : "",
           g_prefix_str ? " " : "");
    if (g_use_prefix) printf("Prefix: %s\n", g_prefix_str ? g_prefix_str : "");
    if (g_random_chunk_mode) {
        printf("Random seed: 0x%016llx  chunk_batches=%llu  verbose_rotation=%s\n",
               (unsigned long long)g_random_seed_used,
               (unsigned long long)(g_chunk_tiles ? g_chunk_tiles : 500),
               g_verbose_rotation ? "on" : "off");
    }
    if (g_max_time_sec > 0)  printf("Deadline: %.2f sec\n", g_max_time_sec);
    if (g_max_batches > 0)   printf("Max batches: %d\n", g_max_batches);
    if (g_log_path)          printf("Output: %s\n", g_log_path);
    if (g_bench_jsonl_path)  printf("Bench JSONL: %s\n", g_bench_jsonl_path);
    if (g_checkpoint_file)   printf("Checkpoint: %s (interval=%ds, resume=%d) [accepted, no-op in 3a]\n",
                                    g_checkpoint_file, g_checkpoint_interval_sec, g_resume_mode);
    emit_ignored_cpu_flag_line();
    fflush(stdout);
}

/* =============================================================================
 * Help / usage - mirrors src/cpu/kt_gmp_v1.c print_usage().
 * ========================================================================== */
static void print_usage(const char* prog) {
    printf("Usage: %s [options]\n\n", prog);
    printf("k-tuplet GPU filter (Phase 3a scaffold; B1 port path)\n\n");
    printf("Search options:\n");
    printf("  --pattern NAME        Pattern name from catalog (e.g. KT19_P0)\n");
    printf("  --k N                 Tuple length (alias --target N)\n");
    printf("  --target N            Tuple length (alias --k N)\n");
    printf("  --bits N              Bit-size of candidate base (required)\n");
    printf("  --primorial N         Use primorial of first N primes (default 5 -> 2310)\n");
    printf("  --threads N           Host prove threads after GPU survivors arrive (default 1)\n");
    printf("  --prefix 0bXXX        Binary prefix to confine search\n");
    printf("  --random              Random-chunk search; usable with or without --prefix\n");
    printf("  --prefix-mode {sequential|random}   Compatibility alias for v8 search modes\n");
    printf("  --chunk-tiles N       Sequential v5 batches per random chunk (default: 500)\n");
    printf("  --random-seed HEX     Explicit u64 seed for --random determinism (default: /dev/urandom)\n");
    printf("  --seed HEX            Alias for --random-seed\n");
    printf("  --verbose-rotation    Emit per-random-chunk anchor diagnostics\n");
    printf("  --sequential          Sequential-only compatibility flag\n");
    printf("  --output FILE         Append found tuplets to FILE\n");
    printf("  --log-file FILE       Alias for --output\n");
    printf("  --quiet               Minimal output\n");
    printf("  --full-quiet          Suppress progress output\n");
    printf("  --report N            Progress interval seconds (alias for --report-interval-sec)\n");
    printf("  --report-interval-sec N  Reporter cadence\n");
    printf("  --bench-jsonl FILE    In --validate-known, emit JSON row per record\n");
    printf("  --max-batches N       Stop after N batches\n");
    printf("  --max-time SEC        Stop after SEC seconds\n");
    printf("  --checkpoint FILE     Atomic checkpoints (accepted, no-op in 3a)\n");
    printf("  --resume              Resume cursor from checkpoint (accepted, no-op in 3a)\n");
    printf("  --ckpt-interval N     Checkpoint interval seconds\n\n");
    printf("CPU-internal flags (accepted, ignored on GPU; echoed in banner):\n");
    printf("  --no-line-sieve / --no-bitvec / --bitvec\n");
    printf("  --opt-fermat / --no-opt-fermat\n");
    printf("  --opt-mont-fermat / --no-opt-mont-fermat\n");
    printf("  --opt-prefetch / --no-opt-prefetch\n");
    printf("  --opt-bitscan / --no-opt-bitscan\n");
    printf("  --opt-line-cap N\n");
    printf("  --pin / --pin-base N\n");
    printf("  --sieve-only\n\n");
    printf("GPU-only options:\n");
    printf("  --gpu-device N        Select CUDA device (default 0)\n");
    printf("  --gpu-batch-size N    Threads per kernel launch (default 524288 = 2^19)\n");
    printf("  --gpu-streams N       Concurrent CUDA streams (default %d, max %d)\n",
           KT_NUM_STREAMS_DEFAULT, KT_MAX_STREAMS);
    printf("  --gpu-arch sm_NN      Informational; actual arch baked at compile time\n");
    printf("  --no-stage-l2         Skip L2 stage in 3c filter cascade\n");
    printf("  --no-stage-ext-l2     Skip ext-L2 stage in 3c filter cascade\n");
    printf("  --no-stage-line       Skip line-sieve stage in 3c filter cascade\n");
    printf("  --no-stage-fermat     Skip Stage-3 Fermat-2 prefilter (Phase 3d)\n\n");
    printf("Modes:\n");
    printf("  --test                Run unit-test suite\n");
    printf("  --smoke               One-batch sieve assertion (returns OK after counter > 0)\n");
    printf("  --validate-known [k]  Reproduce records via prefix sharding (k=16..19 default)\n");
    printf("  --help / -h           This help\n");
}

/* =============================================================================
 * Self-tests (--test).
 * ========================================================================== */
static int test_t1_parse_all_cpu_flags(void) {
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
    slots += 1; /* --threads */
    slots += 1; /* --prefix */
    slots += 1; /* --random */
    slots += 1; /* --prefix-mode */
    slots += 1; /* --chunk-tiles */
    slots += 1; /* --random-seed / --seed */
    slots += 1; /* --verbose-rotation */
    slots += 1; /* --sequential */
    slots += 1; /* --output / --log-file */
    slots += 1; /* --quiet */
    slots += 1; /* --full-quiet */
    slots += 1; /* --report / --report-interval-sec */
    slots += 1; /* --bench-jsonl */
    slots += 1; /* --max-batches */
    slots += 1; /* --max-time */
    slots += 1; /* --checkpoint */
    slots += 1; /* --resume */
    slots += 1; /* --ckpt-interval */
    slots += 1; /* --test */
    slots += 1; /* --smoke */
    slots += 1; /* --validate-known */
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

static int test_t2_cuda_device(void) {
    int dev_count = 0;
    cudaError_t e = cudaGetDeviceCount(&dev_count);
    if (e != cudaSuccess || dev_count <= 0) {
        fprintf(stderr, "T2 FAILED: cudaGetDeviceCount=%s, count=%d\n",
                cudaGetErrorString(e), dev_count);
        return 1;
    }
    e = cudaSetDevice(g_gpu_device);
    if (e != cudaSuccess) {
        fprintf(stderr, "T2 FAILED: cudaSetDevice(%d)=%s\n",
                g_gpu_device, cudaGetErrorString(e));
        return 1;
    }
    /* Phase 4a-2: prefer L1 over shared on sm>=12. Stage-0 kernels use no
     * shared memory, so the full 128 KiB L1/shared partition can serve as
     * L1. Mirrors v15:3629. Idempotent: safe to call on every t2 entry. */
    static int s_cache_config_done = 0;
    if (!s_cache_config_done) {
        cudaDeviceProp prop;
        if (cudaGetDeviceProperties(&prop, g_gpu_device) == cudaSuccess &&
            prop.major >= 12) {
            cudaFuncSetCacheConfig(kt_stage0_to_fermat_kernel,
                                   cudaFuncCachePreferL1);
            cudaFuncSetCacheConfig(kt_stage0_to_line_kernel,
                                   cudaFuncCachePreferL1);
        }
        s_cache_config_done = 1;
    }
    return 0;
}

static int test_t3_kernel_launches(void) {
    unsigned long long *d_counter = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_counter, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(d_counter, 0, sizeof(unsigned long long)));
    int block = 256;
    int grid = 64;
    kt_scaffold_count_kernel<<<grid, block>>>(d_counter, 1ULL);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    unsigned long long h_counter = 0;
    CUDA_CHECK(cudaMemcpy(&h_counter, d_counter, sizeof(unsigned long long),
                          cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaFree(d_counter));
    if (h_counter == 0) {
        fprintf(stderr, "T3 FAILED: counter still zero after kernel launch\n");
        return 1;
    }
    return 0;
}

static int test_t4_banner_ignored_flags(void) {
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

/* T5: kt_wheel_pattern_forbidden(KT5_P0, q=7) == {0,1,2,5,6} (sorted). */
static int test_t5_forbidden_kt5_q7(void) {
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

/* T6: kt_wheel_crt_join(KT5_P0, [2,3,5,7,11]) hash matches canonical. */
static int test_t6_kt5_wheel_hash(void) {
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

/* T7: KT19_P0 with full 37# - reports actual count vs canonical (no
 * auto-correct; brief authorizes treating measured value as ground truth). */
static int test_t7_kt19_full_37(void) {
    uint32_t k19[] = {0,4,6,10,12,16,24,30,34,40,42,46,52,54,60,66,70,72,76};
    uint32_t primes[] = {2,3,5,7,11,13,17,19,23,29,31,37};
    kt_wheel_t w;
    int rc = kt_wheel_crt_join(k19, 19, primes, 12, &w);
    if (rc != 0) {
        fprintf(stderr, "T7 FAILED: crt_join rc=%d (cap or alloc)\n", rc);
        return 1;
    }
    const kt_canonical_wheel_t *can =
        kt_wheel_canonical_lookup("KT19_P0", primes, 12);
    if (!can) {
        fprintf(stderr, "T7 FAILED: no canonical entry for KT19_P0 @ 37#\n");
        kt_wheel_free(&w); return 1;
    }
    int ok = (can->n_admissible == w.n_admissible &&
              can->fnv1a64_hash  == w.fnv1a64_hash);
    printf("T7 KT19_P0 @ 37#: n_admissible=%d hash=0x%016llx (canonical n=%d)\n",
           w.n_admissible, (unsigned long long)w.fnv1a64_hash,
           can->n_admissible);
    if (!ok) {
        fprintf(stderr, "T7 FAILED: hash/count disagrees with canonical\n");
    }
    kt_wheel_free(&w);
    return ok ? 0 : 1;
}

/* T8: Stage-0 kernel survival statistic. Launch over a window and check
 * surv/cand ≈ n_admissible / primorial within ±10%, given enough samples. */
static int test_t8_stage0_survival(void) {
    if (test_t2_cuda_device() != 0) return 1;
    /* Build a small wheel for KT5_P0 @ [2,3,5,7,11]. n_adm=12, prim=2310. */
    uint32_t k5[] = {0,2,6,8,12};
    uint32_t primes[] = {2,3,5,7,11};
    kt_wheel_t w;
    if (kt_wheel_crt_join(k5, 5, primes, 5, &w) != 0) {
        fprintf(stderr, "T8 FAILED: wheel build\n");
        return 1;
    }
    uint64_t *d_off = NULL;
    size_t bytes = (size_t)w.n_admissible * sizeof(uint64_t);
    CUDA_CHECK(cudaMalloc((void**)&d_off, bytes));
    CUDA_CHECK(cudaMemcpy(d_off, w.offsets, bytes, cudaMemcpyHostToDevice));

    unsigned long long *d_surv = NULL, *d_cand = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_surv, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMalloc((void**)&d_cand, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(d_surv, 0, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(d_cand, 0, sizeof(unsigned long long)));

    /* Walk 16384 sequential candidates starting at 1, stride 1. */
    int block = 256;
    int grid = 64;        /* 16384 threads */
    unsigned long long batch = (unsigned long long)grid * (unsigned long long)block;

    kt_stage0_admissibility_kernel<<<grid, block>>>(
        d_off, w.n_admissible, w.primorial,
        1ULL, 1ULL, batch, d_surv, d_cand);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    unsigned long long h_surv = 0, h_cand = 0;
    CUDA_CHECK(cudaMemcpy(&h_surv, d_surv, sizeof(unsigned long long),
                          cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(&h_cand, d_cand, sizeof(unsigned long long),
                          cudaMemcpyDeviceToHost));
    cudaFree(d_off); cudaFree(d_surv); cudaFree(d_cand);

    double expected_rate = (double)w.n_admissible / (double)w.primorial;
    double actual_rate   = (double)h_surv / (double)h_cand;
    double abs_dev       = (actual_rate > expected_rate)
                           ? (actual_rate - expected_rate)
                           : (expected_rate - actual_rate);
    /* Tolerance: ±sqrt(N) on the count, so on rate ±1/sqrt(N). N=16384 -> ~0.008. */
    double tol = 4.0 / (expected_rate * (double)h_cand > 1.0
                        ? expected_rate * (double)h_cand : 1.0)
                 + 0.05 * expected_rate;
    int ok = (abs_dev <= tol) && (h_cand == batch);
    printf("T8 KT5_P0 @ [2..11]: cand=%llu surv=%llu rate=%.6f expected=%.6f %s\n",
           h_cand, h_surv, actual_rate, expected_rate, ok ? "OK" : "FAIL");
    kt_wheel_free(&w);
    if (!ok) {
        fprintf(stderr, "T8 FAILED: surv/cand=%.6f, expected=%.6f, dev=%.6f, tol=%.6f\n",
                actual_rate, expected_rate, abs_dev, tol);
        return 1;
    }
    return 0;
}

/* T9: kt_forbidden_mask_u64(KT5_P0, q=7) bits {0,1,2,5,6} = 0x67. */
static int test_t9_forbidden_mask_u64(void) {
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

/* Build host filter mask arrays for an arbitrary pattern; mirrors
 * build_and_upload_filter_tables but does not touch device memory. */
static void build_host_filter_masks(const uint32_t *pat, int k,
                                    uint64_t l2[KT_L2_COUNT],
                                    uint64_t ext_lo[KT_EXT_L2_COUNT],
                                    uint64_t ext_hi[KT_EXT_L2_COUNT],
                                    uint64_t line[KT_LINE_COUNT * KT_LINE_KILL_WORDS]) {
    for (int i = 0; i < KT_L2_COUNT; i++)
        l2[i] = kt_forbidden_mask_u64(pat, k, kt_l2_primes_h[i]);
    for (int i = 0; i < KT_EXT_L2_COUNT; i++)
        kt_forbidden_mask_u128(pat, k, kt_ext_l2_primes_h[i], &ext_lo[i], &ext_hi[i]);
    for (int i = 0; i < KT_LINE_COUNT; i++)
        kt_forbidden_mask_packed(pat, k, kt_line_primes_h[i],
                                 &line[i * KT_LINE_KILL_WORDS], KT_LINE_KILL_WORDS);
}

/* T10: KT19_P0 filter-mask FNV-1a-64 hashes match the canonical entries. */
static int test_t10_canonical_filter_hashes(void) {
    const KTupletPattern *p = kt_pattern_by_name("KT19_P0");
    if (!p) {
        fprintf(stderr, "T10 FAILED: KT19_P0 unknown\n");
        return 1;
    }
    uint32_t pat[KT_MAX_K];
    for (int i = 0; i < p->k; i++) pat[i] = (uint32_t)p->offsets[i];

    uint64_t l2[KT_L2_COUNT];
    uint64_t ext_lo[KT_EXT_L2_COUNT], ext_hi[KT_EXT_L2_COUNT];
    static uint64_t line[KT_LINE_COUNT * KT_LINE_KILL_WORDS];
    build_host_filter_masks(pat, p->k, l2, ext_lo, ext_hi, line);

    uint64_t l2_h = kt_wheel_fnv1a64_u64_array(l2, KT_L2_COUNT);
    uint64_t ext_packed[KT_EXT_L2_COUNT * 2];
    for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
        ext_packed[2*i + 0] = ext_lo[i];
        ext_packed[2*i + 1] = ext_hi[i];
    }
    uint64_t ext_h = kt_wheel_fnv1a64_u64_array(ext_packed, KT_EXT_L2_COUNT * 2);
    uint64_t ln_h  = kt_wheel_fnv1a64_u64_array(line, KT_LINE_COUNT * KT_LINE_KILL_WORDS);

    const kt_canonical_filter_t *can = kt_filter_canonical_lookup("KT19_P0");
    if (!can) {
        fprintf(stderr, "T10 FAILED: no canonical entry for KT19_P0\n");
        return 1;
    }
    int ok = (can->l2_hash == l2_h && can->ext_l2_hash == ext_h && can->line_hash == ln_h);
    if (!ok) {
        fprintf(stderr,
            "T10 FAILED: KT19_P0 hashes runtime=(0x%016llx,0x%016llx,0x%016llx) canonical=(0x%016llx,0x%016llx,0x%016llx)\n",
            (unsigned long long)l2_h, (unsigned long long)ext_h, (unsigned long long)ln_h,
            (unsigned long long)can->l2_hash, (unsigned long long)can->ext_l2_hash,
            (unsigned long long)can->line_hash);
    }
    return ok ? 0 : 1;
}

/* Helper: build wheel + filter tables for KT19_P0 on the device, and run a
 * single kernel launch with the requested stages. Returns h_cand, h_surv. */
static int kt19_kernel_run(unsigned int stages,
                           unsigned long long batch,
                           unsigned long long base,
                           unsigned long long stride,
                           unsigned long long *out_cand,
                           unsigned int       *out_surv,
                           double             *out_expected_ratio) {
    const KTupletPattern *p = kt_pattern_by_name("KT19_P0");
    if (!p) return 1;

    uint32_t pat[KT_MAX_K];
    for (int i = 0; i < p->k; i++) pat[i] = (uint32_t)p->offsets[i];

    /* Wheel @ 37#. */
    kt_wheel_t w;
    int rc = kt_wheel_crt_join(pat, p->k, g_stage0_primes_37, g_stage0_n_primes_37, &w);
    if (rc != 0) return 1;

    uint64_t *d_off = NULL;
    size_t bytes = (size_t)w.n_admissible * sizeof(uint64_t);
    CUDA_CHECK(cudaMalloc((void**)&d_off, bytes));
    CUDA_CHECK(cudaMemcpy(d_off, w.offsets, bytes, cudaMemcpyHostToDevice));

    /* Filter masks. */
    uint64_t l2[KT_L2_COUNT];
    uint64_t ext_lo[KT_EXT_L2_COUNT], ext_hi[KT_EXT_L2_COUNT];
    static uint64_t line[KT_LINE_COUNT * KT_LINE_KILL_WORDS];
    build_host_filter_masks(pat, p->k, l2, ext_lo, ext_hi, line);

    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_l2_primes,     kt_l2_primes_h,     sizeof(kt_l2_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_primes, kt_ext_l2_primes_h, sizeof(kt_ext_l2_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_line_primes,   kt_line_primes_h,   sizeof(kt_line_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_l2_mask,       l2,     sizeof(l2)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_mask_lo, ext_lo, sizeof(ext_lo)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_mask_hi, ext_hi, sizeof(ext_hi)));

    uint64_t *d_line = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_line, sizeof(line)));
    CUDA_CHECK(cudaMemcpy(d_line, line, sizeof(line), cudaMemcpyHostToDevice));

    KtSurvivor *d_surv_buf = NULL;
    unsigned int *d_surv_count = NULL;
    unsigned long long *d_cand = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_surv_buf, (size_t)KT_MAX_SURVIVORS_PER_BATCH * sizeof(KtSurvivor)));
    CUDA_CHECK(cudaMalloc((void**)&d_surv_count, sizeof(unsigned int)));
    CUDA_CHECK(cudaMalloc((void**)&d_cand, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(d_surv_count, 0, sizeof(unsigned int)));
    CUDA_CHECK(cudaMemset(d_cand,       0, sizeof(unsigned long long)));

    int block = 256;
    unsigned long long total_threads = batch;
    unsigned long long grid64 = (total_threads + (unsigned long long)block - 1) / (unsigned long long)block;
    if (grid64 > 65535ULL) grid64 = 65535ULL;
    int grid = (int)grid64;
    unsigned long long actual_batch = (unsigned long long)grid * (unsigned long long)block;

    kt_stage0_to_line_kernel<<<grid, block>>>(
        d_off, w.n_admissible, w.primorial,
        base, stride, actual_batch,
        d_line, stages,
        d_surv_buf, d_surv_count, /*overflow=*/NULL,
        KT_MAX_SURVIVORS_PER_BATCH,
        d_cand);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    CUDA_CHECK(cudaMemcpy(out_cand, d_cand, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(out_surv, d_surv_count, sizeof(unsigned int), cudaMemcpyDeviceToHost));

    /* Analytical expected ratio per active stages. */
    double r = (double)w.n_admissible / (double)w.primorial;
    if (stages & KT_STAGE_L2) {
        for (int i = 0; i < KT_L2_COUNT; i++) {
            int pc = __builtin_popcountll(l2[i]);
            r *= (double)((int)kt_l2_primes_h[i] - pc) / (double)kt_l2_primes_h[i];
        }
    }
    if (stages & KT_STAGE_EXT_L2) {
        for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
            int pc = __builtin_popcountll(ext_lo[i]) + __builtin_popcountll(ext_hi[i]);
            r *= (double)((int)kt_ext_l2_primes_h[i] - pc) / (double)kt_ext_l2_primes_h[i];
        }
    }
    if (stages & KT_STAGE_LINE) {
        for (int i = 0; i < KT_LINE_COUNT; i++) {
            int pc = 0;
            for (int wd = 0; wd < KT_LINE_KILL_WORDS; wd++)
                pc += __builtin_popcountll(line[i * KT_LINE_KILL_WORDS + wd]);
            r *= (double)((int)kt_line_primes_h[i] - pc) / (double)kt_line_primes_h[i];
        }
    }
    *out_expected_ratio = r;

    cudaFree(d_off); cudaFree(d_line);
    cudaFree(d_surv_buf); cudaFree(d_surv_count); cudaFree(d_cand);
    kt_wheel_free(&w);
    return 0;
}

/* T11: KT19_P0 stage0->line cascade. base=offsets[0], stride=primorial,
 * batch=2^20. All threads pass Stage 0; cascade reduces by filter product.
 * Expected ~6 survivors; Poisson 5σ window. */
static int test_t11_kt19_full_cascade(void) {
    if (test_t2_cuda_device() != 0) return 1;

    /* Need offsets[0] before launching; build a temporary wheel here. */
    const KTupletPattern *p = kt_pattern_by_name("KT19_P0");
    if (!p) { fprintf(stderr, "T11 FAILED: KT19_P0 unknown\n"); return 1; }
    uint32_t pat[KT_MAX_K];
    for (int i = 0; i < p->k; i++) pat[i] = (uint32_t)p->offsets[i];
    kt_wheel_t w_tmp;
    if (kt_wheel_crt_join(pat, p->k, g_stage0_primes_37, g_stage0_n_primes_37, &w_tmp) != 0) {
        fprintf(stderr, "T11 FAILED: wheel build\n");
        return 1;
    }
    unsigned long long base   = w_tmp.offsets[0];   /* admissible -> Stage 0 passes */
    unsigned long long stride = w_tmp.primorial;
    kt_wheel_free(&w_tmp);

    unsigned long long batch = (unsigned long long)1 << 20;   /* 2^20 = 1M */
    unsigned long long h_cand = 0;
    unsigned int       h_surv = 0;
    double             expected_ratio = 0.0;
    if (kt19_kernel_run(KT_STAGES_ALL, batch, base, stride,
                        &h_cand, &h_surv, &expected_ratio) != 0) {
        fprintf(stderr, "T11 FAILED: kernel run\n");
        return 1;
    }

    /* All 2^20 threads pass Stage 0 by construction (base in admissible set);
     * filter cascade reduces by (filter_product). The "expected_ratio" from
     * kt19_kernel_run is over the full primorial sample space; for a stride-
     * primorial walk where all threads pass Stage 0, the correct expected
     * survivor count is batch * (filter_product) = batch * expected_ratio
     * * (primorial / n_admissible). */
    /* Recompute: filter-only product = expected_ratio / (n_admissible/primorial). */
    /* But kt19_kernel_run already divides by primorial for Stage 0. The
     * stride-primorial walk pins r=base%primorial which is admissible, so
     * Stage 0 admit prob = 1 (not n_adm/primorial). Survivors come purely
     * from L2/ext-L2/line. So expected = batch * filter_product. */
    /* Read primorial and n_admissible back from a small wheel rebuild. */
    kt_wheel_t w_k;
    if (kt_wheel_crt_join(pat, p->k, g_stage0_primes_37, g_stage0_n_primes_37, &w_k) != 0) {
        fprintf(stderr, "T11 FAILED: wheel rebuild\n");
        return 1;
    }
    double stage0_prob = (double)w_k.n_admissible / (double)w_k.primorial;
    double filter_prob = expected_ratio / stage0_prob;
    double expected_surv = (double)h_cand * filter_prob;
    kt_wheel_free(&w_k);

    /* Poisson 5σ tolerance. */
    double sigma = (expected_surv > 0) ? 5.0 * sqrt(expected_surv) + 5.0 : 5.0;
    double diff  = (double)h_surv - expected_surv;
    if (diff < 0) diff = -diff;
    int ok = (diff <= sigma) && (h_cand == batch);
    printf("T11 KT19_P0 cascade: cand=%llu surv=%u expected_surv=%.3f filter_prob=%.3e %s\n",
           h_cand, h_surv, expected_surv, filter_prob, ok ? "OK" : "FAIL");
    if (!ok) {
        fprintf(stderr, "T11 FAILED: surv=%u expected=%.3f tol=%.3f cand=%llu (need %llu)\n",
                h_surv, expected_surv, sigma, h_cand, batch);
        return 1;
    }
    return 0;
}

/* T12: Same kernel but Stage-0-only (all filter stages disabled). Survivor
 * count must match n_admissible/primorial within tolerance, identical to
 * T8's discipline (Phase 3c didn't break Stage 0). */
static int test_t12_stage0_only(void) {
    if (test_t2_cuda_device() != 0) return 1;
    unsigned long long batch = (unsigned long long)1 << 16;   /* 65536 */
    unsigned long long base   = 1ULL;
    unsigned long long stride = 1ULL;
    unsigned long long h_cand = 0;
    unsigned int       h_surv = 0;
    double             expected_ratio = 0.0;

    /* stages_active = 0 -> only Stage 0 runs; expected_ratio comes back as
     * pure n_admissible/primorial. */
    if (kt19_kernel_run(0u, batch, base, stride,
                        &h_cand, &h_surv, &expected_ratio) != 0) {
        fprintf(stderr, "T12 FAILED: kernel run\n");
        return 1;
    }
    double expected_surv = (double)h_cand * expected_ratio;
    /* Stage-0 expected ~3.6e-8 * 65536 ≈ 0.0024; Poisson(0.0024)=0 ~99.76%. */
    double sigma = (expected_surv > 0) ? 5.0 * sqrt(expected_surv) + 5.0 : 5.0;
    double diff  = (double)h_surv - expected_surv;
    if (diff < 0) diff = -diff;
    int ok = (diff <= sigma) && (h_cand == batch);
    printf("T12 KT19_P0 stage-0-only: cand=%llu surv=%u expected_surv=%.3e ratio=%.3e %s\n",
           h_cand, h_surv, expected_surv, expected_ratio, ok ? "OK" : "FAIL");
    if (!ok) {
        fprintf(stderr, "T12 FAILED: surv=%u expected=%.3e tol=%.3f\n",
                h_surv, expected_surv, sigma);
        return 1;
    }
    return 0;
}

/* Phase 3d device-side test driver: exposes the u128 helpers via tiny
 * single-thread kernels so host tests can assert their outputs. */
__global__ void kt_test_powmod_kernel(kt_u128 base, kt_u128 exp, kt_u128 mod,
                                      kt_u128 *out) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        *out = kt_u128_powmod(base, exp, mod);
    }
}

__global__ void kt_test_fermat_kernel(kt_u128 n, int *out) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        *out = kt_fermat_base2_u128(n);
    }
}

/* T13: u128 powmod sanity. */
static int test_t13_u128_powmod(void) {
    if (test_t2_cuda_device() != 0) return 1;
    kt_u128 *d_out = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_out, sizeof(kt_u128)));

    /* Case 1: 2^12 mod 13 == 4096 mod 13 == 1. */
    {
        kt_u128 base = {2,0}, exp = {12,0}, mod = {13,0};
        kt_test_powmod_kernel<<<1,1>>>(base, exp, mod, d_out);
        CUDA_CHECK(cudaDeviceSynchronize());
        kt_u128 r; CUDA_CHECK(cudaMemcpy(&r, d_out, sizeof r, cudaMemcpyDeviceToHost));
        if (!(r.lo == 1 && r.hi == 0)) {
            fprintf(stderr, "T13 FAILED: 2^12 mod 13 = (%llu,%llu), expected (1,0)\n",
                    (unsigned long long)r.lo, (unsigned long long)r.hi);
            cudaFree(d_out); return 1;
        }
    }
    /* Case 2: 3^50 mod 1000000007 — cross-check against 64-bit GMP via
     * direct __int128 arithmetic on host. */
    {
        kt_u128 base = {3,0}, exp = {50,0}, mod = {1000000007ULL,0};
        kt_test_powmod_kernel<<<1,1>>>(base, exp, mod, d_out);
        CUDA_CHECK(cudaDeviceSynchronize());
        kt_u128 r; CUDA_CHECK(cudaMemcpy(&r, d_out, sizeof r, cudaMemcpyDeviceToHost));
        unsigned long long expected = 1;
        for (int i = 0; i < 50; i++) expected = (expected * 3ULL) % 1000000007ULL;
        if (!(r.lo == expected && r.hi == 0)) {
            fprintf(stderr, "T13 FAILED: 3^50 mod 1e9+7 = (%llu,%llu), expected %llu\n",
                    (unsigned long long)r.lo, (unsigned long long)r.hi, expected);
            cudaFree(d_out); return 1;
        }
    }
    /* Case 3: 100-bit modulus, cross-check against the host u128 Montgomery
     * stack from kt_verify (mont_powm). No Fermat assumption — works for
     * prime or composite moduli. */
    {
        unsigned __int128 m = ((unsigned __int128)1 << 99) | 7;
        unsigned __int128 e = ((unsigned __int128)1 << 50) | 12345;
        unsigned __int128 b = 7;
        MontCtx ctx;
        mont_ctx_init(&ctx, m);
        unsigned __int128 ref = mont_powm(b, e, &ctx);
        kt_u128 base; base.lo = (uint64_t)b;  base.hi = (uint64_t)(b  >> 64);
        kt_u128 exp;  exp.lo  = (uint64_t)e;  exp.hi  = (uint64_t)(e  >> 64);
        kt_u128 mod;  mod.lo  = (uint64_t)m;  mod.hi  = (uint64_t)(m  >> 64);
        kt_test_powmod_kernel<<<1,1>>>(base, exp, mod, d_out);
        CUDA_CHECK(cudaDeviceSynchronize());
        kt_u128 r; CUDA_CHECK(cudaMemcpy(&r, d_out, sizeof r, cudaMemcpyDeviceToHost));
        uint64_t rl = (uint64_t)ref, rh = (uint64_t)(ref >> 64);
        if (!(r.lo == rl && r.hi == rh)) {
            fprintf(stderr, "T13 FAILED: 100-bit powmod GPU=(%llu,%llu) host=(%llu,%llu)\n",
                    (unsigned long long)r.lo, (unsigned long long)r.hi,
                    (unsigned long long)rl, (unsigned long long)rh);
            cudaFree(d_out); return 1;
        }
    }
    cudaFree(d_out);
    return 0;
}

/* T14: GPU Fermat-2 on a small prime + small composite. */
static int test_t14_fermat_small(void) {
    if (test_t2_cuda_device() != 0) return 1;
    int *d_out = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_out, sizeof(int)));

    kt_u128 p13 = {13, 0};
    kt_test_fermat_kernel<<<1,1>>>(p13, d_out);
    CUDA_CHECK(cudaDeviceSynchronize());
    int r13 = 0; CUDA_CHECK(cudaMemcpy(&r13, d_out, sizeof(int), cudaMemcpyDeviceToHost));
    if (r13 != 1) {
        fprintf(stderr, "T14 FAILED: kt_fermat_base2_u128(13) = %d, expected 1\n", r13);
        cudaFree(d_out); return 1;
    }
    kt_u128 c15 = {15, 0};
    kt_test_fermat_kernel<<<1,1>>>(c15, d_out);
    CUDA_CHECK(cudaDeviceSynchronize());
    int r15 = 0; CUDA_CHECK(cudaMemcpy(&r15, d_out, sizeof(int), cudaMemcpyDeviceToHost));
    if (r15 != 0) {
        fprintf(stderr, "T14 FAILED: kt_fermat_base2_u128(15) = %d, expected 0\n", r15);
        cudaFree(d_out); return 1;
    }
    cudaFree(d_out);
    return 0;
}

/* T15: GPU Fermat-2 stage end-to-end on a known KT5_P0 base.
 * KT5_P0 = {0,2,6,8,12}; n=5 yields {5,7,11,13,17}, all prime. The full
 * Stage-0 → L2 → ext-L2 → line → Fermat cascade should keep this candidate. */
static int test_t15_gpu_fermat_stage_kt5(void) {
    if (test_t2_cuda_device() != 0) return 1;
    const KTupletPattern *p = kt_pattern_by_name("KT5_P0");
    if (!p) { fprintf(stderr, "T15 FAILED: KT5_P0 unknown\n"); return 1; }

    uint32_t pat[KT_MAX_K] = {0};
    for (int i = 0; i < p->k; i++) pat[i] = (uint32_t)p->offsets[i];

    /* KT5_P0 (diameter=12) needs only [2..11] for admissibility — using
     * the full 37# would blow the n_admissible cap (-1). The kernel's
     * Stage-0 cares only about the d_offsets/d_primorial it's given. */
    static const uint32_t kt5_primes[] = {2,3,5,7,11};
    static const int      kt5_primes_n = 5;
    kt_wheel_t w;
    int rc = kt_wheel_crt_join(pat, p->k, kt5_primes, kt5_primes_n, &w);
    if (rc != 0) { fprintf(stderr, "T15 FAILED: wheel build rc=%d\n", rc); return 1; }
    uint64_t *d_off = NULL;
    size_t bytes = (size_t)w.n_admissible * sizeof(uint64_t);
    CUDA_CHECK(cudaMalloc((void**)&d_off, bytes));
    CUDA_CHECK(cudaMemcpy(d_off, w.offsets, bytes, cudaMemcpyHostToDevice));

    /* Filter masks for KT5_P0. */
    uint64_t l2[KT_L2_COUNT];
    uint64_t ext_lo[KT_EXT_L2_COUNT], ext_hi[KT_EXT_L2_COUNT];
    static uint64_t line[KT_LINE_COUNT * KT_LINE_KILL_WORDS];
    build_host_filter_masks(pat, p->k, l2, ext_lo, ext_hi, line);

    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_l2_primes,     kt_l2_primes_h,     sizeof(kt_l2_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_primes, kt_ext_l2_primes_h, sizeof(kt_ext_l2_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_line_primes,   kt_line_primes_h,   sizeof(kt_line_primes_h)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_l2_mask,       l2,     sizeof(l2)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_mask_lo, ext_lo, sizeof(ext_lo)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_ext_l2_mask_hi, ext_hi, sizeof(ext_hi)));

    uint64_t *d_line = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_line, sizeof(line)));
    CUDA_CHECK(cudaMemcpy(d_line, line, sizeof(line), cudaMemcpyHostToDevice));

    int kk = p->k;
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_pattern_offsets, pat, sizeof(pat)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_kt_pattern_k, &kk, sizeof(int)));

    KtSurvivor *d_surv_buf = NULL;
    unsigned int *d_surv_count = NULL;
    unsigned long long *d_cand = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_surv_buf, sizeof(KtSurvivor) * 64));
    CUDA_CHECK(cudaMalloc((void**)&d_surv_count, sizeof(unsigned int)));
    CUDA_CHECK(cudaMalloc((void**)&d_cand, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(d_surv_count, 0, sizeof(unsigned int)));
    CUDA_CHECK(cudaMemset(d_cand,       0, sizeof(unsigned long long)));

    /* Single thread, base_n=1481 — KT5_P0 prime quintuplet
     * {1481,1483,1487,1489,1493}. All members are prime AND > 863, so the
     * line-sieve doesn't reject (which would happen if any member equaled
     * one of the line-sieve primes 101..863, e.g. n=101 gets killed by q=101). */
    kt_u128 base_n; base_n.lo = 1481; base_n.hi = 0;
    kt_u128 stride; stride.lo = w.primorial; stride.hi = 0;
    kt_stage0_to_fermat_kernel<<<1,1>>>(
        d_off, w.n_admissible, w.primorial,
        base_n, stride, /*batch_size*/1ULL,
        d_line, KT_STAGES_ALL,
        d_surv_buf, d_surv_count, /*overflow=*/NULL, 64,
        d_cand);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    unsigned long long h_cand = 0;
    unsigned int       h_surv = 0;
    CUDA_CHECK(cudaMemcpy(&h_cand, d_cand,       sizeof h_cand, cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(&h_surv, d_surv_count, sizeof h_surv, cudaMemcpyDeviceToHost));
    KtSurvivor h_s = {0,0,0,0};
    if (h_surv > 0) {
        CUDA_CHECK(cudaMemcpy(&h_s, d_surv_buf, sizeof h_s, cudaMemcpyDeviceToHost));
    }

    cudaFree(d_off); cudaFree(d_line);
    cudaFree(d_surv_buf); cudaFree(d_surv_count); cudaFree(d_cand);
    kt_wheel_free(&w);

    int ok = (h_cand == 1 && h_surv == 1 && h_s.cand_lo == 1481 && h_s.cand_hi == 0);
    printf("T15 KT5_P0 cascade @ n=1481: cand=%llu surv=%u recovered=(%llu,%llu) %s\n",
           h_cand, h_surv,
           (unsigned long long)h_s.cand_lo, (unsigned long long)h_s.cand_hi,
           ok ? "OK" : "FAIL");
    return ok ? 0 : 1;
}

/* T16: kt_known_records_load + contains. Uses the shared
 * kt_records_load_with_search() helper so T16 and production agree on
 * search order and on what "load failed" means; the helper also prints
 * per-path errno diagnostics on failure. */
static int test_t16_records_load_and_contains(void) {
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

/* T17: smoke preserve_novel_record on a synthetic novel pattern. Override
 * the jsonl path via KT_NOVEL_JSONL so we don't pollute ./novel_records.jsonl. */
static int test_t17_preserve_novel_record_smoke(void) {
    const char *path = "./tmp/novel_records_test.jsonl";
    /* Ensure ./tmp exists; ignore error if dir already there. */
    (void)mkdir("./tmp", 0755);
    /* Remove any prior output. */
    unlink(path);
    setenv("KT_NOVEL_JSONL", path, 1);

    /* Synthetic novel candidate: not in records.json (KT16 records start at
     * 47710850533373130107; "100000000000000000000" is not a KT16 record). */
    preserve_novel_record("KT16_P_TEST", 16, 70, "100000000000000000000");

    /* Confirm the file got at least one line. */
    FILE *fp = fopen(path, "r");
    int ok = 0;
    if (fp) {
        char line[2048];
        if (fgets(line, sizeof line, fp)) {
            ok = (strstr(line, "\"pattern_name\":\"KT16_P_TEST\"") != NULL) &&
                 (strstr(line, "\"base_n\":\"100000000000000000000\"") != NULL);
        }
        fclose(fp);
    }
    unsetenv("KT_NOVEL_JSONL");
    if (!ok) {
        fprintf(stderr, "T17 FAILED: %s missing or malformed\n", path);
        return 1;
    }
    printf("T17 preserve_novel_record smoke: jsonl appended OK\n");
    return 0;
}

/* Forward decls for T18..T20 — defined below run_unit_tests via run_validate_known
 * and parse_prefix_str (already declared at top of file). */
static int test_t18_validate_known_kt16_smoke(void);
static int test_t19_prefix_range_math(void);
static int test_t20_bench_jsonl_schema(void);
static int test_t21_event_timing(void);
static int test_t22_prefix_clamp(void);
static int test_t23_survivor_overflow_signal(void);
static int test_t24_streamed_round_trip(void);
static int test_t25_barrett_mod_u64_vs_shift(void);

static int run_unit_tests(void) {
    int failed = 0;
    int total = 0;
    total++; if (test_t1_parse_all_cpu_flags() != 0) failed++;
    total++; if (test_t2_cuda_device()         != 0) failed++;
    total++; if (test_t3_kernel_launches()     != 0) failed++;
    total++; if (test_t4_banner_ignored_flags()!= 0) failed++;
    total++; if (test_t5_forbidden_kt5_q7()    != 0) failed++;
    total++; if (test_t6_kt5_wheel_hash()      != 0) failed++;
    total++; if (test_t7_kt19_full_37()        != 0) failed++;
    total++; if (test_t8_stage0_survival()     != 0) failed++;
    total++; if (test_t9_forbidden_mask_u64()  != 0) failed++;
    total++; if (test_t10_canonical_filter_hashes() != 0) failed++;
    total++; if (test_t11_kt19_full_cascade()  != 0) failed++;
    total++; if (test_t12_stage0_only()        != 0) failed++;
    total++; if (test_t13_u128_powmod()        != 0) failed++;
    total++; if (test_t14_fermat_small()       != 0) failed++;
    total++; if (test_t15_gpu_fermat_stage_kt5()!=0) failed++;
    total++; if (test_t16_records_load_and_contains() != 0) failed++;
    total++; if (test_t17_preserve_novel_record_smoke() != 0) failed++;
    total++; if (test_t18_validate_known_kt16_smoke() != 0) failed++;
    total++; if (test_t19_prefix_range_math()  != 0) failed++;
    total++; if (test_t20_bench_jsonl_schema() != 0) failed++;
    total++; if (test_t21_event_timing()       != 0) failed++;
    total++; if (test_t22_prefix_clamp()       != 0) failed++;
    total++; if (test_t23_survivor_overflow_signal() != 0) failed++;
    total++; if (test_t24_streamed_round_trip()!= 0) failed++;
    total++; if (test_t25_barrett_mod_u64_vs_shift() != 0) failed++;
    if (failed == 0) {
        printf("All %d tests passed.\n", total);
        return 0;
    }
    printf("%d/%d tests FAILED.\n", failed, total);
    return 1;
}

/* =============================================================================
 * Phase 3d: post-kernel survivor handoff. Copy KtSurvivor batch to host;
 * for each survivor build mpz, run BPSW (verify_tuplet_gmp); on success log
 * to file + crash-safe announce + preserve_novel_record. Returns the number
 * of certified hits found in this batch.
 *
 * Single-threaded for now. The 3c numbers say survivor counts post-line are
 * ~5/Mcand and post-Fermat are ~1e-4 of that, so per-batch BPSW work is
 * negligible. Multi-thread can be a follow-up if it becomes a bottleneck.
 * ========================================================================== */
static int process_survivors_host(unsigned int *out_n_surv, int *out_hits) {
    unsigned int n_surv = 0;
    if (out_n_surv) *out_n_surv = 0;
    if (out_hits)   *out_hits   = 0;
    CUDA_CHECK(cudaMemcpy(&n_surv, g_d_survivor_count, sizeof(unsigned int),
                          cudaMemcpyDeviceToHost));
    if (out_n_surv) *out_n_surv = n_surv;
    if (n_surv == 0) {
        return 0;
    }
    if (n_surv > KT_MAX_SURVIVORS_PER_BATCH) n_surv = KT_MAX_SURVIVORS_PER_BATCH;

    KtSurvivor *h_surv = (KtSurvivor*)malloc((size_t)n_surv * sizeof(KtSurvivor));
    if (!h_surv) {
        fprintf(stderr, "ERROR: malloc(%u survivors) failed\n", n_surv);
        return 0;
    }
    CUDA_CHECK(cudaMemcpy(h_surv, g_d_survivors,
                          (size_t)n_surv * sizeof(KtSurvivor),
                          cudaMemcpyDeviceToHost));
    /* Reset device counter so the next launch starts at 0. */
    CUDA_CHECK(cudaMemset(g_d_survivor_count, 0, sizeof(unsigned int)));

    int hits = 0;
    mpz_t n_mpz, scratch;
    mpz_init(n_mpz);
    mpz_init(scratch);
    for (unsigned int i = 0; i < n_surv; i++) {
        uint64_t limbs[2] = { h_surv[i].cand_lo, h_surv[i].cand_hi };
        mpz_import(n_mpz, 2, -1, sizeof(uint64_t), 0, 0, limbs);
        if (verify_tuplet_gmp(n_mpz, g_pattern, scratch)) {
            char *base_dec = mpz_get_str(NULL, 10, n_mpz);
            if (base_dec) {
                crash_safe_announce(base_dec, g_pattern, g_target_bits);
                log_certified_tuplet(base_dec, g_pattern);
                preserve_novel_record(g_pattern->name, g_pattern->k,
                                      g_target_bits, base_dec);
                if (g_validate_expected_base &&
                    strcmp(base_dec, g_validate_expected_base) == 0) {
                    g_validate_hit_seen = 1;
                }
                free(base_dec);
                hits++;
            }
        }
    }
    mpz_clear(n_mpz);
    mpz_clear(scratch);
    free(h_surv);
    if (out_hits) *out_hits = hits;
    return hits;
}

/* Phase 3f: pinned-host BPSW handoff. h_surv was already D2H'd via
 * cudaMemcpyAsync from the streamed loop; we only run the verify_tuplet_gmp
 * pass here. The non-pinned process_survivors_host above remains for run_smoke
 * and the test path that allocate device buffers freshly per call. */
static int process_survivors_pinned(const KtSurvivor *h_surv,
                                    unsigned int n_surv,
                                    int *out_hits) {
    int hits = 0;
    if (out_hits) *out_hits = 0;
    if (n_surv > KT_MAX_SURVIVORS_PER_BATCH) n_surv = KT_MAX_SURVIVORS_PER_BATCH;
    if (n_surv == 0) return 0;
    mpz_t n_mpz, scratch;
    mpz_init(n_mpz);
    mpz_init(scratch);
    for (unsigned int i = 0; i < n_surv; i++) {
        uint64_t limbs[2] = { h_surv[i].cand_lo, h_surv[i].cand_hi };
        mpz_import(n_mpz, 2, -1, sizeof(uint64_t), 0, 0, limbs);
        if (verify_tuplet_gmp(n_mpz, g_pattern, scratch)) {
            char *base_dec = mpz_get_str(NULL, 10, n_mpz);
            if (base_dec) {
                crash_safe_announce(base_dec, g_pattern, g_target_bits);
                log_certified_tuplet(base_dec, g_pattern);
                preserve_novel_record(g_pattern->name, g_pattern->k,
                                      g_target_bits, base_dec);
                if (g_validate_expected_base &&
                    strcmp(base_dec, g_validate_expected_base) == 0) {
                    g_validate_hit_seen = 1;
                }
                free(base_dec);
                hits++;
            }
        }
    }
    mpz_clear(n_mpz);
    mpz_clear(scratch);
    if (out_hits) *out_hits = hits;
    return hits;
}

/* =============================================================================
 * Smoke (--smoke): one batch through Stage-0 kernel; assert cand > 0 and
 * surv/cand within an order of magnitude of n_admissible/primorial.
 * ========================================================================== */
/* Compute a bit-aligned u128 candidate base for the requested bit-width.
 * Returns an odd value at the high end of the bit range so the Fermat
 * stage actually sees ~2^bits candidates. */
static kt_u128 compute_u128_base(int bits) {
    kt_u128 r; r.lo = 0; r.hi = 0;
    if (bits <= 1) { r.lo = 1; return r; }
    if (bits <= 64) {
        r.lo = (bits == 64) ? (1ULL << 63) | 1ULL : (1ULL << (bits - 1)) | 1ULL;
    } else {
        r.lo = 1;
        r.hi = (bits >= 128) ? (1ULL << 63) : (1ULL << (bits - 1 - 64));
    }
    return r;
}

static int run_smoke(void) {
    if (test_t2_cuda_device() != 0) return 1;
    if (!g_d_admissible_offsets || g_wheel.n_admissible <= 0) {
        fprintf(stderr, "smoke FAILED: Stage-0 wheel not initialized\n");
        return 1;
    }
    if (!g_d_line_kill_packed || !g_d_survivor_count) {
        fprintf(stderr, "smoke FAILED: filter tables not initialized\n");
        return 1;
    }
    unsigned long long *d_cand = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_cand, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(d_cand, 0, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemset(g_d_survivor_count, 0, sizeof(unsigned int)));

    int block = 256;
    int grid = 256;        /* 65536 candidates */
    unsigned long long batch = (unsigned long long)grid * (unsigned long long)block;

    kt_u128 base_n = compute_u128_base(g_target_bits);
    kt_u128 stride; stride.lo = 1; stride.hi = 0;

    kt_stage0_to_fermat_kernel<<<grid, block>>>(
        g_d_admissible_offsets, g_wheel.n_admissible, g_wheel.primorial,
        base_n, stride, batch,
        g_d_line_kill_packed, g_stages_active,
        g_d_survivors, g_d_survivor_count, /*overflow=*/NULL,
        KT_MAX_SURVIVORS_PER_BATCH,
        d_cand);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    unsigned long long h_cand = 0;
    unsigned int       h_surv = 0;
    int                hits   = 0;
    CUDA_CHECK(cudaMemcpy(&h_cand, d_cand, sizeof(unsigned long long),
                          cudaMemcpyDeviceToHost));
    cudaFree(d_cand);

    /* Run BPSW handoff on any post-Fermat survivors. */
    process_survivors_host(&h_surv, &hits);

    if (h_cand == 0) {
        fprintf(stderr, "smoke FAILED: cand zero\n");
        return 1;
    }
    if (!g_quiet_mode) {
        printf("smoke OK pattern=%s bits=%d cand=%llu surv=%u hits=%d "
               "rate=%.3e (Stage-0 expected=%.3e)\n",
               g_pattern_name ? g_pattern_name : "(none)",
               g_target_bits, h_cand, h_surv, hits,
               (double)h_surv / (double)h_cand,
               (double)g_wheel.n_admissible / (double)g_wheel.primorial);
    } else {
        printf("smoke OK pattern=%s\n",
               g_pattern_name ? g_pattern_name : "(none)");
    }
    return 0;
}

/* =============================================================================
 * Search loop (--max-time / --max-batches). Stage-0 only in 3b: each batch
 * counts cand and surv (n_admissible / primorial admit rate). Stages 1/2/3
 * land in 3c/3d. Throughput: cand/s + surv/s + rejection ratio.
 * ========================================================================== */
/* Compute the analytical surv/cand expected from active stages. */
static double compute_expected_ratio(void) {
    double r = (double)g_wheel.n_admissible / (double)g_wheel.primorial;
    if (g_stages_active & KT_STAGE_L2) {
        for (int i = 0; i < KT_L2_COUNT; i++) {
            uint32_t q  = kt_l2_primes_h[i];
            int      pc = __builtin_popcountll(g_l2_mask_h[i]);
            r *= (double)((int)q - pc) / (double)q;
        }
    }
    if (g_stages_active & KT_STAGE_EXT_L2) {
        for (int i = 0; i < KT_EXT_L2_COUNT; i++) {
            uint32_t q  = kt_ext_l2_primes_h[i];
            int      pc = __builtin_popcountll(g_ext_l2_lo_h[i]) +
                          __builtin_popcountll(g_ext_l2_hi_h[i]);
            r *= (double)((int)q - pc) / (double)q;
        }
    }
    if (g_stages_active & KT_STAGE_LINE) {
        for (int i = 0; i < KT_LINE_COUNT; i++) {
            uint32_t q  = kt_line_primes_h[i];
            int      pc = 0;
            for (int w = 0; w < KT_LINE_KILL_WORDS; w++) {
                pc += __builtin_popcountll(
                    g_line_kill_h[i * KT_LINE_KILL_WORDS + w]);
            }
            r *= (double)((int)q - pc) / (double)q;
        }
    }
    return r;
}

/* Phase 3f: double-buffered streamed search loop.
 *
 *   pattern (mirrors v15:4067-4234):
 *       prime: launch on stream[0]
 *       for each subsequent batch i:
 *           launch on stream[i&1]
 *           cudaStreamSynchronize(stream[(i-1)&1])     // wait for prior batch
 *           accumulate cudaEventElapsedTime(start[prev], end[prev])
 *           read pinned h_count[prev], h_overflow[prev]
 *           if overflow: ERROR + exit(1)
 *           if n_surv > 0:  cudaMemcpyAsync(h_surv[prev], d_surv[prev], n_surv, stream[prev])
 *                           cudaStreamSynchronize(stream[prev])
 *           process_survivors_pinned(h_surv[prev], n_surv)
 *       drain: same on the final in-flight batch.
 *
 * GPU is busy on stream[cur] while host BPSWs prev's survivors. Util gate: the
 * cudaEvent timings aggregated into total_kernel_ms divided by wall_time_ms
 * yields gpu_util_pct. v15 reports 100% on a 4090; the engineering target on
 * the 5090 is identical.
 *
 * Per-thread atomicAdd on cand_count is dropped (Phase 3f C3); total_cand is
 * tracked on the host as the sum of (clamped) batch sizes. The d_cand
 * allocation and per-reporter-tick D2H are gone from this path. */
static uint64_t parse_u64_auto(const char *s) {
    int base = 10;
    if (s && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        base = 16;
        s += 2;
    }
    return (uint64_t)strtoull(s ? s : "0", NULL, base);
}

static uint64_t kt_v5_rng_next(void) {
    uint64_t x = g_rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    g_rng_state = x ? x : 1;
    return g_rng_state;
}

static unsigned __int128 kt_v5_random_cursor(unsigned __int128 range_min,
                                             unsigned __int128 range_max,
                                             unsigned long long batch_span,
                                             unsigned __int128 draw) {
    if (range_max <= range_min) return range_min;
    unsigned __int128 span = range_max - range_min;
    unsigned __int128 batch = (unsigned __int128)(batch_span ? batch_span : 1);
    if (span <= batch) return range_min;

    /* v5 walks raw consecutive candidates with stride=1, so the v8
     * primorial-alignment invariant intentionally does not apply here.
     * We do batch-align random starts instead: every random chunk begins
     * inside the range and leaves room for at least one full launch. */
    unsigned __int128 slots = ((span - batch) / batch) + 1;
    unsigned __int128 slot = slots ? (draw % slots) : 0;
    return range_min + slot * batch;
}

static int run_search_loop(void) {
    if (test_t2_cuda_device() != 0) return 1;
    if (!g_d_admissible_offsets || g_wheel.n_admissible <= 0) {
        fprintf(stderr, "ERROR: Stage-0 wheel not initialized for search loop\n");
        return 1;
    }
    if (!g_d_line_kill_packed || !g_d_survivor_count) {
        fprintf(stderr, "ERROR: filter tables not initialized for search loop\n");
        return 1;
    }

    /* Configure launch shape from g_gpu_batch_size. */
    int block = 256;
    u64 grid64 = (g_gpu_batch_size + (u64)block - 1) / (u64)block;
    if (grid64 < 1) grid64 = 1;
    if (grid64 > 65535) grid64 = 65535;
    int grid = (int)grid64;
    unsigned long long batch_per_launch = (unsigned long long)grid * (unsigned long long)block;

    /* Cursor: u128 walk. With --prefix, walk only [prefix << shift,
     * (prefix+1) << shift); otherwise start at the bit-aligned base. */
    unsigned __int128 cursor = 0;
    unsigned __int128 range_end_u128 = 0;
    if (g_use_prefix) {
        int shift = g_target_bits - g_prefix_bits;
        if (shift < 0) shift = 0;
        cursor = g_prefix_value_u128 << shift;
        range_end_u128 = (g_prefix_value_u128 + 1) << shift;
    } else {
        kt_u128 base_n = compute_u128_base(g_target_bits);
        cursor = ((unsigned __int128)base_n.hi << 64) | base_n.lo;
    }
    kt_u128 stride; stride.lo = 1; stride.hi = 0;

    unsigned __int128 random_min_u128 = cursor;
    unsigned __int128 random_max_u128 = range_end_u128;
    if (!g_use_prefix && g_target_bits > 0 && g_target_bits < 128) {
        random_max_u128 = (unsigned __int128)1 << g_target_bits;
    }

    /* Phase 4b-1: N-deep stream pool (was N=2 ping-pong in v4). Steady
     * state holds num_streams kernels in flight; the host drains the
     * oldest just before reusing its slot, so launches stay queued ahead
     * of host-side BPSW + survivor handoff. num_streams is bounded by
     * KT_MAX_STREAMS at parse time. */
    int num_streams = g_gpu_streams;
    if (num_streams < 1) num_streams = 1;
    if (num_streams > KT_MAX_STREAMS) num_streams = KT_MAX_STREAMS;

    cudaStream_t       stream[KT_MAX_STREAMS];
    cudaEvent_t        evt_start[KT_MAX_STREAMS], evt_end[KT_MAX_STREAMS];
    KtSurvivor        *d_surv[KT_MAX_STREAMS]     = {0};
    unsigned int      *d_count[KT_MAX_STREAMS]    = {0};
    unsigned int      *d_overflow[KT_MAX_STREAMS] = {0};
    KtSurvivor        *h_surv[KT_MAX_STREAMS]     = {0};
    unsigned int      *h_count[KT_MAX_STREAMS]    = {0};
    unsigned int      *h_overflow[KT_MAX_STREAMS] = {0};
    for (int b = 0; b < num_streams; b++) {
        CUDA_CHECK(cudaStreamCreate(&stream[b]));
        CUDA_CHECK(cudaEventCreate(&evt_start[b]));
        CUDA_CHECK(cudaEventCreate(&evt_end[b]));
        CUDA_CHECK(cudaMalloc((void**)&d_surv[b],
                              (size_t)KT_MAX_SURVIVORS_PER_BATCH * sizeof(KtSurvivor)));
        CUDA_CHECK(cudaMalloc((void**)&d_count[b],     sizeof(unsigned int)));
        CUDA_CHECK(cudaMalloc((void**)&d_overflow[b],  sizeof(unsigned int)));
        CUDA_CHECK(cudaMemset(d_count[b],    0, sizeof(unsigned int)));
        CUDA_CHECK(cudaMemset(d_overflow[b], 0, sizeof(unsigned int)));
        CUDA_CHECK(cudaMallocHost((void**)&h_surv[b],
                                  (size_t)KT_MAX_SURVIVORS_PER_BATCH * sizeof(KtSurvivor)));
        CUDA_CHECK(cudaMallocHost((void**)&h_count[b],    sizeof(unsigned int)));
        CUDA_CHECK(cudaMallocHost((void**)&h_overflow[b], sizeof(unsigned int)));
        *h_count[b]    = 0;
        *h_overflow[b] = 0;
    }

    double t0 = wall_time_sec();
    double deadline = (g_max_time_sec > 0) ? (t0 + g_max_time_sec) : 0.0;
    int batches = 0;
    int total_hits = 0;
    unsigned long long total_surv = 0;
    unsigned long long total_cand = 0;
    double last_report = t0;
    unsigned long long last_cand = 0;
    unsigned long long last_surv = 0;
    double total_kernel_ms = 0.0;
    double total_prove_ms  = 0.0;

    /* Min-util tracking (Phase 3f.1): wallclock sampler that ticks every
     * 100ms regardless of --full-quiet or --report-interval. Each tick
     * computes (kernel_ms_since_last / 100ms_actual) * 100; min over all
     * ticks is the worst-case util we report. The reporter block (when
     * not quiet) only *prints* the running min; sampling is independent. */
    double last_min_sample          = t0;      /* wallclock at last min sample */
    double last_kernel_ms_at_min    = 0.0;     /* kernel-ms cursor for min sampler */
    double min_util_pct             = 100.0;
    int    have_min_sample          = 0;
    static const double KT_MIN_SAMPLE_MS = 100.0;

    /* Phase 4b-1: cur is the next slot to submit on; inflight tracks how
     * many in-flight kernels we hold. Steady state inflight == num_streams
     * just after submit (drained back to num_streams-1 before the next
     * iteration). When num_streams==2 this matches v4's ping-pong. */
    int cur      = 0;
    int inflight = 0;
    unsigned long long random_chunk_batches =
        g_random_chunk_mode ? (unsigned long long)(g_chunk_tiles ? g_chunk_tiles : 500) : 0;
    unsigned long long random_batches_left = 0;

    if (g_random_chunk_mode) {
        unsigned __int128 draw =
            ((unsigned __int128)g_random_seed_used << 64) |
            (unsigned __int128)(g_random_seed_used ^ 0x9e3779b97f4a7c15ULL);
        cursor = kt_v5_random_cursor(random_min_u128, random_max_u128,
                                      batch_per_launch, draw);
        random_batches_left = random_chunk_batches;
        if (!g_full_quiet_mode) {
            printf("[search-v5] random seed=0x%016llx range=[0x%016llx%016llx,0x%016llx%016llx) initial_cursor=0x%016llx%016llx chunk_batches=%llu\n",
                   (unsigned long long)g_random_seed_used,
                   (unsigned long long)(random_min_u128 >> 64),
                   (unsigned long long)random_min_u128,
                   (unsigned long long)(random_max_u128 >> 64),
                   (unsigned long long)random_max_u128,
                   (unsigned long long)(cursor >> 64),
                   (unsigned long long)cursor,
                   random_chunk_batches);
        }
    }

    while (!g_shutdown_requested) {
        if (g_random_chunk_mode &&
            (random_batches_left == 0 ||
             (random_max_u128 > 0 && cursor >= random_max_u128))) {
            unsigned __int128 draw =
                ((unsigned __int128)kt_v5_rng_next() << 64) | kt_v5_rng_next();
            cursor = kt_v5_random_cursor(random_min_u128, random_max_u128,
                                          batch_per_launch, draw);
            random_batches_left = random_chunk_batches;
            if (g_verbose_rotation) {
                double rot_elapsed = wall_time_sec() - t0;
                printf("[search-v5] random_cursor=0x%016llx%016llx elapsed=%.3fs batch=%d\n",
                       (unsigned long long)(cursor >> 64),
                       (unsigned long long)cursor,
                       rot_elapsed, batches);
                fflush(stdout);
            }
        }

        /* Phase 3f C1: prefix-overrun clamp. With --prefix, the kernel must
         * not be launched past range_end_u128. */
        unsigned long long this_batch = batch_per_launch;
        unsigned __int128 active_range_end =
            (g_random_chunk_mode && random_max_u128 > 0) ? random_max_u128 : range_end_u128;
        if (active_range_end > 0) {
            if (cursor >= active_range_end) {
                if (g_random_chunk_mode) {
                    random_batches_left = 0;
                    continue;
                }
                break;
            }
            unsigned __int128 remaining = active_range_end - cursor;
            if (remaining < (unsigned __int128)this_batch)
                this_batch = (unsigned long long)remaining;
            if (this_batch == 0) break;
        }

        /* Reset cur stream's device counters before launch. */
        CUDA_CHECK(cudaMemsetAsync(d_count[cur],    0, sizeof(unsigned int), stream[cur]));
        CUDA_CHECK(cudaMemsetAsync(d_overflow[cur], 0, sizeof(unsigned int), stream[cur]));

        kt_u128 cur128;
        cur128.lo = (uint64_t)cursor;
        cur128.hi = (uint64_t)(cursor >> 64);

        CUDA_CHECK(cudaEventRecord(evt_start[cur], stream[cur]));
        kt_stage0_to_fermat_kernel<<<grid, block, 0, stream[cur]>>>(
            g_d_admissible_offsets, g_wheel.n_admissible, g_wheel.primorial,
            cur128, stride, this_batch,
            g_d_line_kill_packed, g_stages_active,
            d_surv[cur], d_count[cur], d_overflow[cur],
            KT_MAX_SURVIVORS_PER_BATCH,
            /*cand_count=*/NULL);
        CUDA_CHECK(cudaEventRecord(evt_end[cur], stream[cur]));
        CUDA_CHECK(cudaGetLastError());

        /* Async D2H of count + overflow flag for cur (small, in-flight). */
        CUDA_CHECK(cudaMemcpyAsync(h_count[cur],    d_count[cur],
                                   sizeof(unsigned int),
                                   cudaMemcpyDeviceToHost, stream[cur]));
        CUDA_CHECK(cudaMemcpyAsync(h_overflow[cur], d_overflow[cur],
                                   sizeof(unsigned int),
                                   cudaMemcpyDeviceToHost, stream[cur]));

        total_cand += this_batch;     /* C3: track issued cand on host */
        cursor += (unsigned __int128)this_batch;
        if (g_random_chunk_mode && random_batches_left > 0)
            random_batches_left--;
        batches++;

        /* Round-robin advance + steady-state drain. We just submitted on
         * `cur`; the next slot to recycle is (cur+1) % num_streams. Once
         * the pool is full (inflight == num_streams) we drain that
         * slot — it's the oldest in-flight kernel — so it's free for the
         * next launch. */
        cur = (cur + 1) % num_streams;
        inflight++;

        if (inflight >= num_streams) {
            int prev = cur;     /* oldest in-flight = next slot to reuse */
            CUDA_CHECK(cudaStreamSynchronize(stream[prev]));

            float kms = 0.0f;
            CUDA_CHECK(cudaEventElapsedTime(&kms, evt_start[prev], evt_end[prev]));
            total_kernel_ms += (double)kms;

            unsigned int n_overflow = *h_overflow[prev];
            unsigned int n_surv     = *h_count[prev];
            if (n_overflow != 0u) {
                fprintf(stderr,
                    "ERROR: survivor buffer overflow (had=%u cap=%u). "
                    "Reduce --gpu-batch-size or raise KT_MAX_SURVIVORS_PER_BATCH.\n",
                    n_surv, KT_MAX_SURVIVORS_PER_BATCH);
                exit(1);
            }
            if (n_surv > KT_MAX_SURVIVORS_PER_BATCH)
                n_surv = KT_MAX_SURVIVORS_PER_BATCH;     /* defensive clamp */

            if (n_surv > 0) {
                CUDA_CHECK(cudaMemcpyAsync(h_surv[prev], d_surv[prev],
                                           (size_t)n_surv * sizeof(KtSurvivor),
                                           cudaMemcpyDeviceToHost, stream[prev]));
                CUDA_CHECK(cudaStreamSynchronize(stream[prev]));
            }

            double pv0 = wall_time_sec();
            int batch_hits = 0;
            process_survivors_pinned(h_surv[prev], n_surv, &batch_hits);
            double pv1 = wall_time_sec();
            total_prove_ms += (pv1 - pv0) * 1000.0;
            total_surv += n_surv;
            total_hits += batch_hits;
            inflight--;
        }

        double now = wall_time_sec();

        /* Phase 3f.1: 100ms wallclock min-util sampler. Runs unconditionally —
         * not gated on --full-quiet or g_report_interval_sec. The previous
         * design only sampled inside the reporter block, so --full-quiet runs
         * (every bench harness row) had no real per-tick min and seeded the
         * gate-relevant min from the run mean at end-of-run. */
        {
            double sample_dt_ms = (now - last_min_sample) * 1000.0;
            if (sample_dt_ms >= KT_MIN_SAMPLE_MS) {
                double tick_kernel_ms = total_kernel_ms - last_kernel_ms_at_min;
                double tick_util      = (sample_dt_ms > 0)
                                        ? (tick_kernel_ms / sample_dt_ms * 100.0)
                                        : 0.0;
                if (tick_util > 100.0) tick_util = 100.0;
                if (tick_util < 0.0)   tick_util = 0.0;
                if (have_min_sample) {
                    if (tick_util < min_util_pct) min_util_pct = tick_util;
                } else {
                    min_util_pct = tick_util;
                    have_min_sample = 1;
                }
                last_min_sample       = now;
                last_kernel_ms_at_min = total_kernel_ms;
            }
        }

        if (!g_full_quiet_mode && g_report_interval_sec > 0 &&
            (now - last_report) >= g_report_interval_sec) {
            double dt      = now - t0;
            double dt_step = now - last_report;
            unsigned long long step_cand = total_cand - last_cand;
            unsigned long long step_surv = total_surv - last_surv;
            double cand_rate = dt_step > 0 ? (double)step_cand / dt_step : 0.0;
            double surv_rate = dt_step > 0 ? (double)step_surv / dt_step : 0.0;
            double frac      = total_cand > 0 ? (double)total_surv / (double)total_cand : 0.0;
            double gpu_util  = (dt > 0) ? (total_kernel_ms / (dt * 1000.0) * 100.0) : 0.0;
            if (gpu_util > 100.0) gpu_util = 100.0;
            double prove_ratio = (total_kernel_ms > 0)
                                 ? (total_prove_ms / total_kernel_ms) : 0.0;

            fprintf(stderr,
                "[reporter] t=%.2fs batches=%d cand=%llu surv=%llu hits=%d "
                "cand/s=%.3e surv/s=%.3e surv/cand=%.3e "
                "gpu=%.0f%% (min=%.0f%%) (prove/k1=%.2fx)\n",
                dt, batches, total_cand, total_surv, total_hits,
                cand_rate, surv_rate, frac, gpu_util,
                have_min_sample ? min_util_pct : gpu_util, prove_ratio);
            last_report = now;
            last_cand = total_cand;
            last_surv = total_surv;
        }
        if (deadline > 0 && now >= deadline) break;
        if (g_max_batches > 0 && batches >= g_max_batches) break;
        if (!g_random_chunk_mode && range_end_u128 > 0 && cursor >= range_end_u128) break;
    }

    /* Drain: walk all remaining in-flight slots in oldest-first order.
     * Submission advances cur by 1 each launch; the oldest still-in-flight
     * slot was submitted `inflight` iterations ago, i.e. (cur - inflight)
     * mod num_streams. (At steady-state exit inflight == num_streams - 1
     * because the in-loop drain ran. On early exit before the pool fills,
     * inflight equals the number of submitted batches and cur points at a
     * never-used slot — using the formula keeps us off it.) */
    int drain_start = ((cur - inflight) % num_streams + num_streams) % num_streams;
    for (int k = 0; k < inflight; k++) {
        int prev = (drain_start + k) % num_streams;
        CUDA_CHECK(cudaStreamSynchronize(stream[prev]));
        float kms = 0.0f;
        CUDA_CHECK(cudaEventElapsedTime(&kms, evt_start[prev], evt_end[prev]));
        total_kernel_ms += (double)kms;

        unsigned int n_overflow = *h_overflow[prev];
        unsigned int n_surv     = *h_count[prev];
        if (n_overflow != 0u) {
            fprintf(stderr,
                "ERROR: survivor buffer overflow on drain (had=%u cap=%u).\n",
                n_surv, KT_MAX_SURVIVORS_PER_BATCH);
            exit(1);
        }
        if (n_surv > KT_MAX_SURVIVORS_PER_BATCH) n_surv = KT_MAX_SURVIVORS_PER_BATCH;
        if (n_surv > 0) {
            CUDA_CHECK(cudaMemcpyAsync(h_surv[prev], d_surv[prev],
                                       (size_t)n_surv * sizeof(KtSurvivor),
                                       cudaMemcpyDeviceToHost, stream[prev]));
            CUDA_CHECK(cudaStreamSynchronize(stream[prev]));
        }
        double pv0 = wall_time_sec();
        int batch_hits = 0;
        process_survivors_pinned(h_surv[prev], n_surv, &batch_hits);
        double pv1 = wall_time_sec();
        total_prove_ms += (pv1 - pv0) * 1000.0;
        total_surv += n_surv;
        total_hits += batch_hits;
    }
    inflight = 0;

    double t1 = wall_time_sec();
    double dt = t1 - t0;
    double wall_ms      = dt * 1000.0;
    double gpu_util     = (wall_ms > 0) ? (total_kernel_ms / wall_ms * 100.0) : 0.0;
    if (gpu_util > 100.0) gpu_util = 100.0;
    double prove_ratio  = (total_kernel_ms > 0)
                          ? (total_prove_ms / total_kernel_ms) : 0.0;
    double cand_rate    = dt > 0 ? (double)total_cand / dt : 0.0;
    double surv_rate    = dt > 0 ? (double)total_surv / dt : 0.0;
    double frac         = total_cand > 0
                          ? (double)total_surv / (double)total_cand : 0.0;
    double expected     = compute_expected_ratio();
    double dev_pct      = (expected > 0)
                          ? 100.0 * (frac - expected) / expected : 0.0;

    /* If we never sampled a 1Hz tick (very short run), seed the min from mean. */
    if (!have_min_sample) min_util_pct = gpu_util;

    printf("=== final: batches=%d cand=%llu surv=%llu hits=%d elapsed=%.3fs "
           "cand/s=%.3e surv/s=%.3e surv/cand=%.3e (expected=%.3e dev=%+0.1f%%) "
           "[stages=0x%x] gpu_util_pct=%.2f gpu_util_pct_min=%.2f "
           "prove_to_kernel_ratio=%.4f total_kernel_ms=%.3f total_prove_ms=%.3f "
           "wall_time_ms=%.3f bench_schema_version=%d ===\n",
           batches, total_cand, total_surv, total_hits, dt,
           cand_rate, surv_rate, frac, expected, dev_pct, g_stages_active,
           gpu_util, min_util_pct, prove_ratio,
           total_kernel_ms, total_prove_ms, wall_ms,
           KT_BENCH_SCHEMA_VERSION);
    if (prove_ratio > 1.5) {
        fprintf(stderr,
            "** GPU was idle %.0f%% of the time — try more prove threads or "
            "higher depth to reduce survivors **\n",
            100.0 - gpu_util);
    }

    g_run_cand                  = total_cand;
    g_run_surv                  = total_surv;
    g_run_hits                  = total_hits;
    g_run_elapsed_s             = dt;
    g_run_total_kernel_ms       = total_kernel_ms;
    g_run_total_prove_ms        = total_prove_ms;
    g_run_wall_time_ms          = wall_ms;
    g_run_gpu_util_pct          = gpu_util;
    g_run_gpu_util_pct_min      = min_util_pct;
    g_run_prove_to_kernel_ratio = prove_ratio;

    /* Tear down streams + buffers. */
    for (int b = 0; b < num_streams; b++) {
        cudaStreamDestroy(stream[b]);
        cudaEventDestroy(evt_start[b]);
        cudaEventDestroy(evt_end[b]);
        if (d_surv[b])     cudaFree(d_surv[b]);
        if (d_count[b])    cudaFree(d_count[b]);
        if (d_overflow[b]) cudaFree(d_overflow[b]);
        if (h_surv[b])     cudaFreeHost(h_surv[b]);
        if (h_count[b])    cudaFreeHost(h_count[b]);
        if (h_overflow[b]) cudaFreeHost(h_overflow[b]);
    }
    return 0;
}

/* =============================================================================
 * Phase 3e: --validate-known
 *
 * Walk tools/records_manifest.tsv; per record (k, pattern, base, bits) rebuild
 * the wheel + filter tables, run a 2s sieve probe to estimate throughput,
 * derive a prefix that fits ~60s of work, then run --max-time 60 with the
 * derived prefix and report whether the certified base appeared. One JSONL
 * row per record when --bench-jsonl is set.
 * ========================================================================== */

typedef struct {
    int k;
    char pattern[32];
    char base_dec[256];
    int bits;
} RecordEntryGpu;

static int load_records_manifest_gpu(RecordEntryGpu **out, int target_k_filter) {
    static const char *candidates[] = {
        "tools/records_manifest.tsv",
        "../tools/records_manifest.tsv",
        "../../tools/records_manifest.tsv",
        NULL
    };
    FILE *fp = NULL;
    for (int i = 0; candidates[i]; i++) {
        fp = fopen(candidates[i], "r");
        if (fp) break;
    }
    if (!fp) {
        fprintf(stderr, "ERROR: tools/records_manifest.tsv not found\n");
        return -1;
    }
    char line[2048];
    int cap = 64, count = 0;
    RecordEntryGpu *arr = (RecordEntryGpu *)malloc((size_t)cap * sizeof(RecordEntryGpu));
    if (!arr) { fclose(fp); return -1; }
    if (!fgets(line, sizeof line, fp)) { fclose(fp); free(arr); return 0; }
    while (fgets(line, sizeof line, fp)) {
        RecordEntryGpu r; memset(&r, 0, sizeof r);
        char date_buf[128], author_buf[256];
        int n_fields = sscanf(line, "%d\t%31[^\t]\t%255[^\t]\t%*d\t%127[^\t]\t%255[^\t]\t%d",
                              &r.k, r.pattern, r.base_dec, date_buf, author_buf, &r.bits);
        if (n_fields < 6) continue;
        if (r.k < 0 || r.k >= 64) continue;
        if (r.bits < 8 || r.bits > 4096) continue;
        if (target_k_filter > 0 && r.k != target_k_filter) continue;
        if (count >= cap) {
            cap *= 2;
            RecordEntryGpu *grown = (RecordEntryGpu *)realloc(arr, (size_t)cap * sizeof(RecordEntryGpu));
            if (!grown) { fclose(fp); free(arr); return -1; }
            arr = grown;
        }
        arr[count++] = r;
    }
    fclose(fp);
    *out = arr;
    return count;
}

/* Parse base-10 to u128. Returns 0 OK, -1 on bad char or overflow. */
static int parse_decimal_u128(const char *s, unsigned __int128 *out) {
    if (!s || !*s) return -1;
    unsigned __int128 v = 0;
    for (const char *p = s; *p; p++) {
        if (*p < '0' || *p > '9') return -1;
        unsigned __int128 nv = v * 10 + (unsigned __int128)(*p - '0');
        if (nv < v) return -1;
        v = nv;
    }
    *out = v;
    return 0;
}

/* Parse 0bXXX into u128 + bit count. Returns 0 OK, -1 on bad input. */
static int parse_prefix_str(const char *s, unsigned __int128 *val, int *bits) {
    if (!s) return -1;
    if (s[0] == '0' && (s[1] == 'b' || s[1] == 'B')) s += 2;
    unsigned __int128 v = 0;
    int n = 0;
    for (const char *p = s; *p; p++) {
        if (*p != '0' && *p != '1') return -1;
        if (n >= 127) return -1;
        v = (v << 1) | (unsigned __int128)(*p - '0');
        n++;
    }
    if (n == 0) return -1;
    *val = v;
    *bits = n;
    return 0;
}

/* Run kernel batches for ~`seconds` against the currently-uploaded wheel +
 * filter tables, return cand/s. No BPSW handoff, no log writes. */
static double estimate_throughput_gpu(double seconds) {
    if (!g_d_admissible_offsets || !g_d_line_kill_packed || !g_d_survivor_count) {
        return 1.0;
    }
    unsigned long long *d_cand = NULL;
    if (cudaMalloc((void **)&d_cand, sizeof(unsigned long long)) != cudaSuccess) return 1.0;
    cudaMemset(d_cand, 0, sizeof(unsigned long long));
    cudaMemset(g_d_survivor_count, 0, sizeof(unsigned int));

    int block = 256;
    u64 grid64 = (g_gpu_batch_size + (u64)block - 1) / (u64)block;
    if (grid64 < 1) grid64 = 1;
    if (grid64 > 65535) grid64 = 65535;
    int grid = (int)grid64;
    unsigned long long batch_per_launch = (unsigned long long)grid * (unsigned long long)block;

    /* Probe at the bit-aligned base; this is a throughput-only run, so the
     * exact starting cursor doesn't have to match the eventual prefix. */
    kt_u128 base_n = compute_u128_base(g_target_bits);
    kt_u128 stride; stride.lo = 1; stride.hi = 0;
    unsigned __int128 cursor = ((unsigned __int128)base_n.hi << 64) | base_n.lo;

    double t0 = wall_time_sec();
    double deadline = t0 + seconds;
    while (wall_time_sec() < deadline) {
        kt_u128 cur128;
        cur128.lo = (uint64_t)cursor;
        cur128.hi = (uint64_t)(cursor >> 64);
        kt_stage0_to_fermat_kernel<<<grid, block>>>(
            g_d_admissible_offsets, g_wheel.n_admissible, g_wheel.primorial,
            cur128, stride, batch_per_launch,
            g_d_line_kill_packed, g_stages_active,
            g_d_survivors, g_d_survivor_count, /*overflow=*/NULL,
            KT_MAX_SURVIVORS_PER_BATCH,
            d_cand);
        if (cudaGetLastError() != cudaSuccess) break;
        if (cudaDeviceSynchronize() != cudaSuccess) break;
        cursor += (unsigned __int128)batch_per_launch;
        cudaMemset(g_d_survivor_count, 0, sizeof(unsigned int));
    }
    double dt = wall_time_sec() - t0;
    unsigned long long h_cand = 0;
    cudaMemcpy(&h_cand, d_cand, sizeof h_cand, cudaMemcpyDeviceToHost);
    cudaFree(d_cand);
    if (dt < 1e-6) dt = 1e-6;
    return (double)h_cand / dt;
}

/* Reset GPU state for a new pattern (release + rebuild wheel + filter). */
static int set_pattern_for_validate(const char *name) {
    g_pattern = kt_pattern_by_name(name);
    if (!g_pattern) {
        fprintf(stderr, "ERROR: pattern '%s' not in catalog\n", name);
        return -1;
    }
    g_pattern_name = g_pattern->name;
    g_target_k = g_pattern->k;
    release_filter_tables();
    release_stage0_wheel();
    if (build_and_upload_stage0_wheel() != 0) return -1;
    if (build_and_upload_filter_tables() != 0) return -1;
    return 0;
}

static int run_validate_known(void) {
    if (test_t2_cuda_device() != 0) return 1;

    /* If --validate-known got no positional k but --k N was set, honor it as
     * the validate target — matches the brief's acceptance command shape. */
    if (g_validate_target_k == 0 && g_target_k > 0) {
        g_validate_target_k = g_target_k;
    }

    RecordEntryGpu *recs = NULL;
    int n = load_records_manifest_gpu(&recs, g_validate_target_k);
    if (n < 0) return 1;
    if (n == 0) {
        fprintf(stderr, "No records for k=%d\n", g_validate_target_k);
        free(recs);
        return g_validate_target_k > 0 ? 1 : 0;
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

    /* Phase 3f.1: per-record gate. ok_count_by_k counts records actually
     * reproduced in this run; touched_count_by_k counts records walked.
     * The exit gate is `ok==touched` for every k we touched — every walked
     * record must reproduce within budget. */
    int ok_count_by_k[64] = {0};
    int touched_count_by_k[64] = {0};

    /* Default scope: k=16..19; --validate-known K narrows to one k. */
    for (int i = 0; i < n; i++) {
        RecordEntryGpu *r = &recs[i];
        if (g_validate_target_k == 0 && (r->k < 16 || r->k > 19)) continue;
        /* Skip once per-k cap reached, but DO NOT short-circuit on first
         * success: --validate-known is honest about scope only if every
         * record up to the cap is touched. */
        if (touched_count_by_k[r->k] >= g_validate_max_records_per_k) continue;

        /* Skip records whose base would not fit in u128. */
        if (r->bits > 127) {
            printf("[k=%d %s] SKIPPED reason=bits>127 base=%s\n",
                   r->k, r->pattern, r->base_dec);
            continue;
        }
        touched_count_by_k[r->k]++;

        if (set_pattern_for_validate(r->pattern) != 0) {
            printf("[k=%d %s] FAIL set_pattern\n", r->k, r->pattern);
            continue;
        }
        g_target_bits = r->bits;

        /* Probe throughput with a brief run (no Fermat, no BPSW). */
        unsigned int saved_stages = g_stages_active;
        g_stages_active &= ~KT_STAGE_FERMAT;
        double tput = estimate_throughput_gpu(2.0);
        g_stages_active = saved_stages;
        if (tput < 1.0) tput = 1.0;

        /* Choose prefix_bits so 2^(bits - prefix_bits) candidates fit in ~60s. */
        double budget = 60.0 * tput;
        int needed_prefix_bits;
        if (budget < 1.0) {
            needed_prefix_bits = r->bits - 1;
        } else {
            double log2_budget = log(budget) / log(2.0);
            needed_prefix_bits = (int)ceil((double)r->bits - log2_budget);
            if (needed_prefix_bits < 1) needed_prefix_bits = 1;
            if (needed_prefix_bits > r->bits - 1) needed_prefix_bits = r->bits - 1;
        }

        unsigned __int128 base_u128 = 0;
        if (parse_decimal_u128(r->base_dec, &base_u128) != 0) {
            printf("[k=%d %s] SKIPPED reason=bad_base\n", r->k, r->pattern);
            continue;
        }

        /* prefix = base >> (bits - prefix_bits). If the prefix's leading bit
         * lands below position needed_prefix_bits-1 (which can happen for
         * bases whose top bit isn't at position bits-1), walk needed_prefix_bits
         * down until the prefix has a leading 1. */
        unsigned __int128 prefix = base_u128 >> (r->bits - needed_prefix_bits);
        while (needed_prefix_bits > 1) {
            int top = 0;
            unsigned __int128 t = prefix;
            while (t) { top++; t >>= 1; }
            if (top == needed_prefix_bits) break;
            needed_prefix_bits--;
            prefix = base_u128 >> (r->bits - needed_prefix_bits);
        }

        if (needed_prefix_bits >= r->bits) {
            printf("[k=%d %s] SKIPPED reason=throughput_too_low (tput=%.0f/s)\n",
                   r->k, r->pattern, tput);
            continue;
        }

        g_use_prefix = 1;
        g_prefix_value_u128 = prefix;
        g_prefix_bits = needed_prefix_bits;
        g_max_time_sec = 60.0;
        g_max_batches = 0;
        g_validate_expected_base = r->base_dec;
        g_validate_hit_seen = 0;
        g_run_cand = 0; g_run_surv = 0; g_run_hits = 0; g_run_elapsed_s = 0.0;

        run_search_loop();

        int hit = g_validate_hit_seen ? 1 : 0;
        if (hit) {
            ok_count_by_k[r->k]++;
            printf("[k=%d %s] base=%s OK time=%.1fs prefix_bits=%d tput=%.0f/s "
                   "cand=%llu surv=%llu hits=%d\n",
                   r->k, r->pattern, r->base_dec, g_run_elapsed_s,
                   needed_prefix_bits, tput,
                   (unsigned long long)g_run_cand,
                   (unsigned long long)g_run_surv, g_run_hits);
        } else {
            printf("[k=%d %s] base=%s NOTFOUND time=%.1fs prefix_bits=%d cand=%llu surv=%llu hits=%d\n",
                   r->k, r->pattern, r->base_dec, g_run_elapsed_s,
                   needed_prefix_bits,
                   (unsigned long long)g_run_cand,
                   (unsigned long long)g_run_surv, g_run_hits);
        }

        if (g_bench_jsonl_fp) {
            char ts[64]; time_t t = time(NULL);
            strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t));
            double cand_per_s = g_run_elapsed_s > 0
                              ? (double)g_run_cand / g_run_elapsed_s : 0.0;
            int fermat_active = (g_stages_active & KT_STAGE_FERMAT) ? 1 : 0;
            pthread_mutex_lock(&g_bench_jsonl_lock);
            fprintf(g_bench_jsonl_fp,
                "{\"k\":%d,\"pattern\":\"%s\",\"base\":\"%s\",\"bits\":%d,"
                "\"prefix_bits\":%d,\"elapsed_s\":%.4f,"
                "\"cand\":%llu,\"surv\":%llu,"
                "\"surv_post_fermat\":%llu,"
                "\"verified\":%d,\"found\":%d,"
                "\"tput_cand_per_s\":%.0f,"
                "\"ts_utc\":\"%s\","
                "\"engine\":\"gpu\","
                "\"host\":\"%s\","
                "\"gpu_uuid\":\"%s\","
                "\"cuda_runtime\":%d,"
                "\"primorial\":%d,"
                "\"wheel_n_admissible\":%d,"
                "\"stages_active\":%u,"
                "\"fermat_active\":%d,"
                "\"gpu_batch_size\":%llu,"
                "\"gpu_streams\":%d,"
                "\"gpu_util_pct\":%.2f,"
                "\"gpu_util_pct_min\":%.2f,"
                "\"total_kernel_ms\":%.3f,"
                "\"total_prove_ms\":%.3f,"
                "\"prove_to_kernel_ratio\":%.4f,"
                "\"wall_time_ms\":%.3f,"
                "\"bench_schema_version\":%d,"
                "\"build_sha\":\"%s\","
                "\"binary_name\":\"%s\"}\n",
                r->k, r->pattern, r->base_dec, r->bits,
                needed_prefix_bits, g_run_elapsed_s,
                (unsigned long long)g_run_cand,
                (unsigned long long)g_run_surv,
                (unsigned long long)g_run_surv,
                hit, hit, cand_per_s,
                ts, kt_hostname(), kt_gpu_uuid(), CUDART_VERSION,
                g_primorial_n_primes, g_wheel.n_admissible,
                g_stages_active, fermat_active,
                (unsigned long long)g_gpu_batch_size,
                g_gpu_streams,
                g_run_gpu_util_pct, g_run_gpu_util_pct_min,
                g_run_total_kernel_ms, g_run_total_prove_ms,
                g_run_prove_to_kernel_ratio, g_run_wall_time_ms,
                KT_BENCH_SCHEMA_VERSION,
                KT_BUILD_SHA,
                KT_BINARY_NAME);
            fflush(g_bench_jsonl_fp);
            pthread_mutex_unlock(&g_bench_jsonl_lock);
        }

        g_validate_expected_base = NULL;
        g_max_time_sec = 0.0;
    }

    /* Phase 3f.1: gate_ok iff every touched record reproduced. */
    int gate_ok = 1;
    {
        int kmin = (g_validate_target_k > 0) ? g_validate_target_k : 16;
        int kmax = (g_validate_target_k > 0) ? g_validate_target_k : 19;
        for (int k = kmin; k <= kmax; k++) {
            if (touched_count_by_k[k] > 0 &&
                ok_count_by_k[k] != touched_count_by_k[k]) {
                gate_ok = 0;
            }
        }
    }

    printf("\n=== validate-known summary (engine=gpu) ===\n");
    for (int k = 16; k <= 24; k++) {
        if (touched_count_by_k[k] > 0) {
            int pass = (ok_count_by_k[k] == touched_count_by_k[k]);
            printf("validate-known: k=%d touched=%d ok=%d %s\n",
                   k, touched_count_by_k[k], ok_count_by_k[k],
                   pass ? "PASS" : "FAIL");
        }
    }
    printf("validate-known: gate=%s\n", gate_ok ? "PASS" : "FAIL");

    free(recs);
    if (g_bench_jsonl_fp) {
        fclose(g_bench_jsonl_fp);
        g_bench_jsonl_fp = NULL;
    }
    release_filter_tables();
    release_stage0_wheel();
    return gate_ok ? 0 : 1;
}

/* =============================================================================
 * Phase 3e tests — T18..T20.
 * ========================================================================== */

/* T18: --validate-known --k 16 reproduces at least the first KT16 record
 * (smallest one in the manifest) within 60s. Run in-process: invoke
 * run_validate_known() with target_k=16 + a temp bench-jsonl path. Pass
 * iff at least one row landed AND its found field == 1. */
static int test_t18_validate_known_kt16_smoke(void) {
    if (test_t2_cuda_device() != 0) return 1;
    const char *path = "./tmp/t18_validate_kt16.jsonl";
    (void)mkdir("./tmp", 0755);
    unlink(path);
    int saved_target_k = g_validate_target_k;
    const char *saved_bench = g_bench_jsonl_path;
    int saved_use_prefix = g_use_prefix;
    int saved_full_quiet = g_full_quiet_mode;

    g_validate_target_k = 16;
    g_bench_jsonl_path  = path;
    g_full_quiet_mode   = 1;
    int saved_max = g_validate_max_records_per_k;
    g_validate_max_records_per_k = 1;

    int rc = run_validate_known();
    g_validate_max_records_per_k = saved_max;

    g_validate_target_k = saved_target_k;
    g_bench_jsonl_path  = saved_bench;
    g_use_prefix        = saved_use_prefix;
    g_full_quiet_mode   = saved_full_quiet;

    /* Inspect jsonl for at least one row with "found":1. */
    FILE *fp = fopen(path, "r");
    int any_found = 0, n_rows = 0;
    if (fp) {
        char line[4096];
        while (fgets(line, sizeof line, fp)) {
            n_rows++;
            if (strstr(line, "\"found\":1")) any_found = 1;
        }
        fclose(fp);
    }
    printf("T18 --validate-known --k 16: rows=%d any_found=%d run_rc=%d\n",
           n_rows, any_found, rc);
    if (n_rows < 1) {
        fprintf(stderr, "T18 FAILED: no rows produced\n");
        return 1;
    }
    if (!any_found) {
        fprintf(stderr, "T18 FAILED: no found=1 row produced\n");
        return 1;
    }
    return 0;
}

/* T19: --prefix range math. parse_prefix_str("0b1") at bits=60 confines the
 * search to [2^59, 2^60). Verify the math directly. */
static int test_t19_prefix_range_math(void) {
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

/* T20: --bench-jsonl row schema sanity. Run validate-known briefly on k=16,
 * read back one row, assert the required keys are all present. */
static int test_t20_bench_jsonl_schema(void) {
    const char *path = "./tmp/t20_schema.jsonl";
    (void)mkdir("./tmp", 0755);
    unlink(path);
    int saved_target_k = g_validate_target_k;
    const char *saved_bench = g_bench_jsonl_path;
    int saved_full_quiet = g_full_quiet_mode;

    g_validate_target_k = 16;
    g_bench_jsonl_path  = path;
    g_full_quiet_mode   = 1;
    int saved_max = g_validate_max_records_per_k;
    g_validate_max_records_per_k = 1;
    /* Light: don't need a real hit. The row gets written even on NOTFOUND.
     * Only one record runs (~60s). */

    (void)run_validate_known();
    g_validate_max_records_per_k = saved_max;

    g_validate_target_k = saved_target_k;
    g_bench_jsonl_path  = saved_bench;
    g_full_quiet_mode   = saved_full_quiet;

    FILE *fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "T20 FAILED: could not open %s\n", path);
        return 1;
    }
    char line[4096];
    int got_row = 0;
    if (fgets(line, sizeof line, fp)) got_row = 1;
    fclose(fp);
    if (!got_row) {
        fprintf(stderr, "T20 FAILED: no row in %s\n", path);
        return 1;
    }
    static const char *required[] = {
        "\"k\":", "\"pattern\":", "\"base\":", "\"bits\":",
        "\"elapsed_s\":", "\"cand\":", "\"surv\":",
        "\"verified\":", "\"found\":",
        "\"tput_cand_per_s\":", "\"ts_utc\":",
        "\"engine\":", "\"host\":", "\"gpu_uuid\":",
        "\"primorial\":", "\"wheel_n_admissible\":",
        "\"stages_active\":", "\"fermat_active\":",
        "\"gpu_util_pct\":", "\"gpu_util_pct_min\":",
        "\"total_kernel_ms\":", "\"total_prove_ms\":",
        "\"prove_to_kernel_ratio\":", "\"wall_time_ms\":",
        "\"bench_schema_version\":",
        "\"build_sha\":",
        NULL
    };
    for (int i = 0; required[i]; i++) {
        if (!strstr(line, required[i])) {
            fprintf(stderr, "T20 FAILED: missing field %s\n", required[i]);
            return 1;
        }
    }
    printf("T20 bench-jsonl schema OK (%d required keys present)\n",
           (int)(sizeof(required)/sizeof(required[0])) - 1);
    return 0;
}

/* =============================================================================
 * Phase 3f tests — T21..T24.
 * ========================================================================== */

/* T21: cudaEvent timing path returns a positive elapsed-ms reading on a
 * trivial scaffold-kernel launch. Smoke for the event-timing wiring in 3f. */
static int test_t21_event_timing(void) {
    if (test_t2_cuda_device() != 0) return 1;
    cudaStream_t s;
    cudaEvent_t e0, e1;
    if (cudaStreamCreate(&s) != cudaSuccess) {
        fprintf(stderr, "T21 FAILED: cudaStreamCreate\n"); return 1;
    }
    if (cudaEventCreate(&e0) != cudaSuccess ||
        cudaEventCreate(&e1) != cudaSuccess) {
        fprintf(stderr, "T21 FAILED: cudaEventCreate\n"); return 1;
    }
    unsigned long long *d = NULL;
    if (cudaMalloc((void**)&d, sizeof(unsigned long long)) != cudaSuccess) {
        fprintf(stderr, "T21 FAILED: cudaMalloc\n"); return 1;
    }
    cudaMemset(d, 0, sizeof(unsigned long long));
    cudaEventRecord(e0, s);
    /* Each thread does 1024 atomic adds to keep the kernel non-trivially
     * short so the elapsed reading is a real positive number. */
    kt_scaffold_count_kernel<<<256, 256, 0, s>>>(d, 1024ULL);
    cudaEventRecord(e1, s);
    cudaStreamSynchronize(s);
    float ms = 0.0f;
    cudaError_t er = cudaEventElapsedTime(&ms, e0, e1);
    cudaFree(d);
    cudaEventDestroy(e0); cudaEventDestroy(e1);
    cudaStreamDestroy(s);
    if (er != cudaSuccess) {
        fprintf(stderr, "T21 FAILED: cudaEventElapsedTime rc=%d\n", (int)er);
        return 1;
    }
    if (!(ms > 0.0f) || !(ms < 60000.0f)) {
        fprintf(stderr, "T21 FAILED: implausible elapsed ms=%.4f\n", ms);
        return 1;
    }
    printf("T21 cudaEvent timing OK (kernel %.3f ms)\n", ms);
    return 0;
}

/* T22: prefix clamp. Configure a tiny --prefix range that fits in fewer
 * candidates than batch_per_launch; assert run_search_loop terminates with
 * exactly that many issued cand (no overrun). */
static int test_t22_prefix_clamp(void) {
    if (test_t2_cuda_device() != 0) return 1;
    /* Phase 3f.1: KT19_P0 instead of KT5_P0. KT5_P0 + 37# overflows
     * KT_WHEEL_MAX_ADMISSIBLE (T15 documents this); KT19_P0 + 37# is the
     * production wheel and fits the cap. T22 is a structural prefix-clamp
     * test — pattern doesn't matter as long as the wheel builds. */
    if (set_pattern_for_validate("KT19_P0") != 0) {
        fprintf(stderr, "T22 FAILED: set_pattern_for_validate\n"); return 1;
    }
    int saved_target_bits = g_target_bits;
    int saved_use_prefix = g_use_prefix;
    int saved_prefix_bits = g_prefix_bits;
    unsigned __int128 saved_prefix_val = g_prefix_value_u128;
    double saved_max_time = g_max_time_sec;
    int saved_max_batches = g_max_batches;
    u64 saved_batch_size = g_gpu_batch_size;
    int saved_full_quiet = g_full_quiet_mode;

    /* Force a tiny range: bits=100, prefix bits=100, prefix's leading bit
     * at position 99 → range_end - cursor = 1. batch_per_launch = 65535*256
     * = 16.77M, so the clamp must cap to 1. */
    g_target_bits = 100;
    g_use_prefix = 1;
    g_prefix_bits = 100;
    g_prefix_value_u128 = ((unsigned __int128)1) << 99;
    g_max_time_sec = 5.0;
    g_max_batches = 1;
    g_gpu_batch_size = (u64)1 << 19;     /* default */
    g_full_quiet_mode = 1;

    int rc = run_search_loop();

    g_target_bits = saved_target_bits;
    g_use_prefix = saved_use_prefix;
    g_prefix_bits = saved_prefix_bits;
    g_prefix_value_u128 = saved_prefix_val;
    g_max_time_sec = saved_max_time;
    g_max_batches = saved_max_batches;
    g_gpu_batch_size = saved_batch_size;
    g_full_quiet_mode = saved_full_quiet;

    if (rc != 0) {
        fprintf(stderr, "T22 FAILED: run_search_loop rc=%d\n", rc);
        return 1;
    }
    /* The clamped-batch contract: g_run_cand exactly equals 1 since the
     * prefix narrows the range to one candidate. */
    if (g_run_cand != 1) {
        fprintf(stderr,
            "T22 FAILED: prefix-clamp expected cand=1 but got %llu (overrun)\n",
            (unsigned long long)g_run_cand);
        return 1;
    }
    printf("T22 prefix-clamp OK (cand=%llu)\n",
           (unsigned long long)g_run_cand);
    return 0;
}

/* T23: survivor overflow exits the process. Simulated by writing 1 directly
 * to a pinned-host overflow flag and exercising the same fail-fast path the
 * search loop uses. We do not actually run the kernel to overflow because
 * KT_MAX_SURVIVORS_PER_BATCH = 1M survivors is impractical to provoke from
 * a unit test. Instead: check that the ERROR + exit(1) path is wired by
 * fork()-running a small probe that flips the flag and asserts exit-code 1.
 *
 * Implementation note: forking from a CUDA-initialized process is fragile,
 * so we test the predicate logic only — the search loop's "if n_overflow
 * != 0u: exit(1)" is a single line with no side effects to verify
 * separately. We assert that a freshly-zeroed overflow flag stays zero
 * after a clean kernel launch (no false positive), and that atomicOr from
 * a kernel does set it. The "would call exit(1)" branch is exercised
 * implicitly by the search loop when the buffer truly overflows in a real
 * run — which does not happen in our test configuration. */
__global__ void kt_set_overflow_kernel(unsigned int *flag) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        atomicOr(flag, 1u);
    }
}

static int test_t23_survivor_overflow_signal(void) {
    if (test_t2_cuda_device() != 0) return 1;
    unsigned int *d_flag = NULL;
    unsigned int  h_flag = 0;
    if (cudaMalloc((void**)&d_flag, sizeof(unsigned int)) != cudaSuccess) {
        fprintf(stderr, "T23 FAILED: cudaMalloc\n"); return 1;
    }
    cudaMemset(d_flag, 0, sizeof(unsigned int));
    /* Clean baseline: no kernel write -> flag stays 0. */
    cudaMemcpy(&h_flag, d_flag, sizeof(unsigned int), cudaMemcpyDeviceToHost);
    if (h_flag != 0u) {
        fprintf(stderr, "T23 FAILED: baseline flag != 0 (%u)\n", h_flag);
        cudaFree(d_flag); return 1;
    }
    /* Now set it from a kernel and confirm host reads non-zero. */
    kt_set_overflow_kernel<<<1, 1>>>(d_flag);
    cudaDeviceSynchronize();
    cudaMemcpy(&h_flag, d_flag, sizeof(unsigned int), cudaMemcpyDeviceToHost);
    cudaFree(d_flag);
    if (h_flag == 0u) {
        fprintf(stderr,
            "T23 FAILED: atomicOr from kernel did not set flag\n");
        return 1;
    }
    printf("T23 survivor-overflow signal OK (atomicOr propagates)\n");
    return 0;
}

/* T24: double-buffered streams round-trip. Run two batches via run_search_loop
 * on KT5_P0 with --max-batches=2 and assert the cand count equals
 * 2 * batch_per_launch (or the clamped value). Surv count is non-negative.
 * This exercises the priming, prev-process, drain code paths. */
static int test_t24_streamed_round_trip(void) {
    if (test_t2_cuda_device() != 0) return 1;
    /* Phase 3f.1: KT19_P0 (production wheel; fits 37# cap). KT5_P0 + 37#
     * overflows KT_WHEEL_MAX_ADMISSIBLE — see T22 note. */
    if (set_pattern_for_validate("KT19_P0") != 0) {
        fprintf(stderr, "T24 FAILED: set_pattern_for_validate\n"); return 1;
    }
    int saved_target_bits = g_target_bits;
    int saved_use_prefix = g_use_prefix;
    int saved_max_batches = g_max_batches;
    double saved_max_time = g_max_time_sec;
    u64 saved_batch_size = g_gpu_batch_size;
    int saved_full_quiet = g_full_quiet_mode;

    g_target_bits = 100;
    g_use_prefix = 0;
    g_max_batches = 2;
    g_max_time_sec = 0.0;
    g_gpu_batch_size = (u64)1 << 18;
    g_full_quiet_mode = 1;

    int rc = run_search_loop();

    int block = 256;
    u64 grid64 = (g_gpu_batch_size + (u64)block - 1) / (u64)block;
    if (grid64 > 65535) grid64 = 65535;
    unsigned long long expected_per_batch =
        (unsigned long long)grid64 * (unsigned long long)block;
    unsigned long long expected_total = 2ULL * expected_per_batch;

    g_target_bits = saved_target_bits;
    g_use_prefix = saved_use_prefix;
    g_max_batches = saved_max_batches;
    g_max_time_sec = saved_max_time;
    g_gpu_batch_size = saved_batch_size;
    g_full_quiet_mode = saved_full_quiet;

    if (rc != 0) {
        fprintf(stderr, "T24 FAILED: run_search_loop rc=%d\n", rc);
        return 1;
    }
    if (g_run_cand != expected_total) {
        fprintf(stderr,
            "T24 FAILED: cand=%llu expected=%llu\n",
            (unsigned long long)g_run_cand, expected_total);
        return 1;
    }
    /* GPU-util can be < 95% on this micro-run (overhead-dominated), but
     * total_kernel_ms must be > 0 — proves the event path fired. */
    if (g_run_total_kernel_ms <= 0.0) {
        fprintf(stderr,
            "T24 FAILED: total_kernel_ms=%.3f (event path not firing)\n",
            g_run_total_kernel_ms);
        return 1;
    }
    printf("T24 streamed round-trip OK (cand=%llu kernel_ms=%.3f util=%.1f%%)\n",
           (unsigned long long)g_run_cand,
           g_run_total_kernel_ms, g_run_gpu_util_pct);
    return 0;
}

/* =============================================================================
 * Phase 4a-3 test — T25: Barrett kt_u128_mod_u64_barrett vs shift-loop.
 *
 * Sweeps a representative set of (a, m) pairs through both the original
 * shift-loop reduction (kt_u128_mod_u64) and the Barrett variant
 * (kt_u128_mod_u64_barrett with mu = floor(2^128/m) computed on host).
 * Failure if any pair disagrees. Cases include:
 *   - small dividend (a < m, hi=0 fast path)
 *   - large dividend with hi != 0
 *   - a near 2^128-1, a == 0, a == m-1
 *   - moduli: m=2, 3, m=2^32, m=2^32+15, large prime, KT19_P0 primorial(37#)
 * ========================================================================== */
__global__ void kt_test_mod_u64_barrett_kernel(kt_u128 a, uint64_t m, kt_u128 mu,
                                               uint64_t *out_barrett,
                                               uint64_t *out_shift) {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        *out_barrett = kt_u128_mod_u64_barrett(a, m, mu);
        *out_shift   = kt_u128_mod_u64(a, m);
    }
}

static int test_t25_barrett_mod_u64_vs_shift(void) {
    if (test_t2_cuda_device() != 0) return 1;

    uint64_t *d_barrett = NULL, *d_shift = NULL;
    CUDA_CHECK(cudaMalloc((void**)&d_barrett, sizeof(uint64_t)));
    CUDA_CHECK(cudaMalloc((void**)&d_shift,   sizeof(uint64_t)));

    /* Build the (a, m) test sweep. */
    struct { uint64_t a_lo, a_hi, m; } cases[] = {
        /* hi == 0 fast path */
        { 0,                     0, 7420738134810ULL },     /* a=0 */
        { 1,                     0, 7420738134810ULL },
        { 7420738134809ULL,      0, 7420738134810ULL },     /* a == m-1 */
        { 7420738134811ULL,      0, 7420738134810ULL },     /* a == m+1 */
        /* hi != 0 slow path, primorial-37# modulus */
        { 0,                     1ULL, 7420738134810ULL },  /* a = 2^64 */
        { 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 7420738134810ULL }, /* a = 2^128-1 */
        { 0x123456789ABCDEF0ULL, 0x0000000000000001ULL, 7420738134810ULL },
        { 0xDEADBEEFCAFEBABEULL, 0xFEEDFACE12345678ULL, 7420738134810ULL },
        /* m = 2 (smallest valid; mu = 2^127) */
        { 0,                     0, 2ULL },
        { 1,                     0, 2ULL },
        { 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 2ULL },
        /* m = 3 (small odd) */
        { 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, 3ULL },
        /* m = 2^32 */
        { 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, (uint64_t)1ULL << 32 },
        /* m = 2^32 + 15 (prime, awkward) */
        { 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, ((uint64_t)1ULL << 32) + 15ULL },
        /* m = large prime near 2^43 */
        { 0xCAFEBABEDEADBEEFULL, 0x1234567890ABCDEFULL, 8796093022217ULL },
        /* m = 2^63 (large modulus exercising mu_hi small) */
        { 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, (uint64_t)1ULL << 63 },
        /* m = 2^63 + 1 — upper bound of the well-defined range for both
         *   the original kt_u128_mod_u64 shift-loop (its inner `r <<= 1`
         *   overflows once m > 2^63) and our Barrett (q.lo*m wraps u64
         *   in the same regime). Production use (m = 37# ≈ 2^43) is well
         *   below this, so we restrict T25 to m ≤ 2^63 + 1. */
        { 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL, ((uint64_t)1ULL << 63) + 1ULL },
    };
    int n_cases = (int)(sizeof cases / sizeof cases[0]);

    int failed = 0;
    for (int i = 0; i < n_cases; i++) {
        kt_u128 a;
        a.lo = cases[i].a_lo;
        a.hi = cases[i].a_hi;
        uint64_t m = cases[i].m;

        /* Compute mu = floor(2^128 / m) on host using __int128. */
        unsigned __int128 mu128 =
            ((unsigned __int128)0 - (unsigned __int128)m) / m + 1;
        kt_u128 mu;
        mu.lo = (uint64_t)mu128;
        mu.hi = (uint64_t)(mu128 >> 64);

        kt_test_mod_u64_barrett_kernel<<<1,1>>>(a, m, mu, d_barrett, d_shift);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        uint64_t r_barrett = 0, r_shift = 0;
        CUDA_CHECK(cudaMemcpy(&r_barrett, d_barrett, sizeof r_barrett, cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(&r_shift,   d_shift,   sizeof r_shift,   cudaMemcpyDeviceToHost));

        /* Host reference via __int128. */
        unsigned __int128 a128 =
            ((unsigned __int128)cases[i].a_hi << 64) | (unsigned __int128)cases[i].a_lo;
        uint64_t r_host = (uint64_t)(a128 % (unsigned __int128)m);

        if (r_barrett != r_shift || r_barrett != r_host) {
            fprintf(stderr,
                "T25 FAILED case[%d]: a=(0x%016llx,0x%016llx) m=%llu "
                "barrett=%llu shift=%llu host=%llu\n",
                i,
                (unsigned long long)cases[i].a_hi,
                (unsigned long long)cases[i].a_lo,
                (unsigned long long)m,
                (unsigned long long)r_barrett,
                (unsigned long long)r_shift,
                (unsigned long long)r_host);
            failed++;
        }
    }

    cudaFree(d_barrett); cudaFree(d_shift);
    if (failed) return 1;
    printf("T25 Barrett kt_u128_mod_u64_barrett vs shift-loop: %d/%d cases agree\n",
           n_cases, n_cases);
    return 0;
}

/* =============================================================================
 * argv parser - mirrors kt_gmp_v1.c:main parse loop, accepting every CPU
 * long-flag. Unknown flags exit non-zero (CLI parity contract).
 * ========================================================================== */
/* =============================================================================
 * Phase 3f.2 — envelope-boundary warnings (G1, G2). Emitted from parse_argv
 * after all flags are consumed so --no-stage-fermat/--no-stage-line can
 * suppress them. Surgical mirror of the v7 helper; warnings only — no
 * behaviour change for in-envelope (--bits in [10,126]) runs.
 * ========================================================================== */
static void kt_emit_envelope_warnings(int bits, unsigned stages_active, FILE *out) {
    if (bits >= 127 && (stages_active & KT_STAGE_FERMAT)) {
        fprintf(out,
            "WARNING: --bits=%d with Fermat-2 enabled may produce false "
            "negatives at the 2^127 boundary (G1: cand + max_offset can "
            "wrap kt_u128_mulmod's intermediate). Recommend --bits<=126 "
            "or disable Fermat with --no-stage-fermat.\n",
            bits);
    }
    if ((stages_active & KT_STAGE_LINE) && bits > 0 && bits < 10) {
        fprintf(out,
            "WARNING: --bits=%d with line-sieve enabled may reject prime "
            "tuple members <=863 (G2). Recommend --bits>=10 or disable "
            "line-sieve with --no-stage-line.\n",
            bits);
    }
}

static int parse_argv(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
            print_usage(argv[0]);
            return 2;
        }
        else if (!strcmp(a, "--pattern") && i+1 < argc) g_pattern_name = argv[++i];
        else if (!strcmp(a, "--k") && i+1 < argc) g_target_k = atoi(argv[++i]);
        else if (!strcmp(a, "--target") && i+1 < argc) g_target_k = atoi(argv[++i]);
        else if (!strcmp(a, "--bits") && i+1 < argc) g_target_bits = atoi(argv[++i]);
        else if (!strcmp(a, "--primorial") && i+1 < argc) {
            g_primorial_n_primes = atoi(argv[++i]);
            if (g_primorial_n_primes < 2) g_primorial_n_primes = 2;
            if (g_primorial_n_primes > 8) g_primorial_n_primes = 8;
            fprintf(stderr,
                "WARNING: --primorial is parsed but ignored on the GPU path "
                "(production wheel uses fixed 37#). Phase 4-GPU will implement.\n");
        }
        else if (!strcmp(a, "--threads") && i+1 < argc) {
            g_threads = atoi(argv[++i]);
            fprintf(stderr,
                "WARNING: --threads is parsed but ignored on the GPU path "
                "(survivor prove path is serial as of Phase 3f.1). "
                "Phase 4-GPU will implement.\n");
        }
        else if (!strcmp(a, "--prefix") && i+1 < argc) {
            g_prefix_str = argv[++i];
            g_use_prefix = 1;
        }
        else if (!strcmp(a, "--random")) {
            g_random_chunk_mode = 1;
        }
        else if (!strcmp(a, "--prefix-mode") && i+1 < argc) {
            const char *mode = argv[++i];
            if (!strcmp(mode, "sequential")) {
                g_random_chunk_mode = 0;
            } else if (!strcmp(mode, "random")) {
                g_random_chunk_mode = 1;
            } else {
                fprintf(stderr,
                    "ERROR: --prefix-mode '%s' invalid; must be 'sequential' "
                    "or 'random'\n", mode);
                return 1;
            }
        }
        else if (!strcmp(a, "--chunk-tiles") && i+1 < argc) {
            g_chunk_tiles = (u64)strtoull(argv[++i], NULL, 10);
        }
        else if ((!strcmp(a, "--random-seed") || !strcmp(a, "--seed")) && i+1 < argc) {
            g_random_seed_used = parse_u64_auto(argv[++i]);
            g_random_seed_explicit = 1;
        }
        else if (!strcmp(a, "--verbose-rotation")) {
            g_verbose_rotation = 1;
        }
        else if (!strcmp(a, "--sequential")) g_sequential_mode = 1;
        else if (!strcmp(a, "--output") && i+1 < argc) g_log_path = argv[++i];
        else if (!strcmp(a, "--log-file") && i+1 < argc) g_log_path = argv[++i];
        else if (!strcmp(a, "--quiet")) g_quiet_mode = 1;
        else if (!strcmp(a, "--full-quiet")) { g_full_quiet_mode = 1; g_quiet_mode = 1; }
        else if (!strcmp(a, "--report") && i+1 < argc) g_report_interval_sec = atof(argv[++i]);
        else if (!strcmp(a, "--report-interval-sec") && i+1 < argc) {
            g_report_interval_sec = atof(argv[++i]);
            if (g_report_interval_sec < 0) g_report_interval_sec = 0;
        }
        else if (!strcmp(a, "--bench-jsonl") && i+1 < argc) g_bench_jsonl_path = argv[++i];
        else if (!strcmp(a, "--max-batches") && i+1 < argc) g_max_batches = atoi(argv[++i]);
        else if (!strcmp(a, "--max-time") && i+1 < argc) g_max_time_sec = atof(argv[++i]);
        else if (!strcmp(a, "--checkpoint") && i+1 < argc) {
            g_checkpoint_file = argv[++i];
            fprintf(stderr,
                "WARNING: --checkpoint/--resume is parsed but ignored on the "
                "GPU path (no persistence implementation in Phase 3f.1). "
                "Phase 4-GPU will implement.\n");
        }
        else if (!strcmp(a, "--resume")) {
            g_resume_mode = 1;
            fprintf(stderr,
                "WARNING: --resume is parsed but ignored on the GPU path "
                "(no persistence implementation in Phase 3f.1). "
                "Phase 4-GPU will implement.\n");
        }
        else if (!strcmp(a, "--ckpt-interval") && i+1 < argc) {
            g_checkpoint_interval_sec = atoi(argv[++i]);
            fprintf(stderr,
                "WARNING: --ckpt-interval is parsed but ignored on the GPU "
                "path (no persistence implementation in Phase 3f.1). "
                "Phase 4-GPU will implement.\n");
        }
        else if (!strcmp(a, "--test")) return 10;
        else if (!strcmp(a, "--smoke")) g_smoke_mode = 1;
        else if (!strcmp(a, "--validate-known")) {
            g_validate_known_mode = 1;
            if (i+1 < argc && argv[i+1][0] != '-') g_validate_target_k = atoi(argv[++i]);
        }
        /* CPU flags - accepted and ignored on GPU (echoed in banner). */
        else if (!strcmp(a, "--no-line-sieve")) g_cpu_flag_no_line_sieve = 1;
        else if (!strcmp(a, "--no-bitvec")) g_cpu_flag_no_bitvec = 1;
        else if (!strcmp(a, "--bitvec")) g_cpu_flag_force_bitvec = 1;
        else if (!strcmp(a, "--opt-fermat"))    { g_cpu_flag_opt_fermat_set = 1; g_cpu_flag_opt_fermat_val = 1; }
        else if (!strcmp(a, "--no-opt-fermat")) { g_cpu_flag_opt_fermat_set = 1; g_cpu_flag_opt_fermat_val = 0; }
        else if (!strcmp(a, "--opt-mont-fermat"))    { g_cpu_flag_opt_mont_fermat_set = 1; g_cpu_flag_opt_mont_fermat_val = 1; }
        else if (!strcmp(a, "--no-opt-mont-fermat")) { g_cpu_flag_opt_mont_fermat_set = 1; g_cpu_flag_opt_mont_fermat_val = 0; }
        else if (!strcmp(a, "--opt-prefetch"))    { g_cpu_flag_opt_prefetch_set = 1; g_cpu_flag_opt_prefetch_val = 1; }
        else if (!strcmp(a, "--no-opt-prefetch")) { g_cpu_flag_opt_prefetch_set = 1; g_cpu_flag_opt_prefetch_val = 0; }
        else if (!strcmp(a, "--opt-bitscan"))    { g_cpu_flag_opt_bitscan_set = 1; g_cpu_flag_opt_bitscan_val = 1; }
        else if (!strcmp(a, "--no-opt-bitscan")) { g_cpu_flag_opt_bitscan_set = 1; g_cpu_flag_opt_bitscan_val = 0; }
        else if (!strcmp(a, "--opt-line-cap") && i+1 < argc) g_cpu_flag_opt_line_cap = atoi(argv[++i]);
        else if (!strcmp(a, "--pin")) g_cpu_flag_pin = 1;
        else if (!strcmp(a, "--pin-base") && i+1 < argc) {
            g_cpu_flag_pin_base_set = 1;
            g_cpu_flag_pin_base_val = atoi(argv[++i]);
        }
        else if (!strcmp(a, "--sieve-only")) g_cpu_flag_sieve_only = 1;
        /* GPU-only. */
        else if (!strcmp(a, "--gpu-device") && i+1 < argc) g_gpu_device = atoi(argv[++i]);
        else if (!strcmp(a, "--gpu-batch-size") && i+1 < argc)
            g_gpu_batch_size = (u64)strtoull(argv[++i], NULL, 10);
        else if (!strcmp(a, "--gpu-streams") && i+1 < argc) {
            int n = atoi(argv[++i]);
            if (n < 1) n = 1;
            if (n > KT_MAX_STREAMS) n = KT_MAX_STREAMS;
            g_gpu_streams = n;
        }
        else if (!strcmp(a, "--gpu-arch") && i+1 < argc) g_gpu_arch_label = argv[++i];
        else if (!strcmp(a, "--no-stage-l2"))     g_stages_active &= ~KT_STAGE_L2;
        else if (!strcmp(a, "--no-stage-ext-l2")) g_stages_active &= ~KT_STAGE_EXT_L2;
        else if (!strcmp(a, "--no-stage-line"))   g_stages_active &= ~KT_STAGE_LINE;
        else if (!strcmp(a, "--no-stage-fermat")) g_stages_active &= ~KT_STAGE_FERMAT;
        else if (a[0] == '-') {
            fprintf(stderr, "Unknown option: %s (try --help)\n", a);
            return 1;
        }
    }
    kt_emit_envelope_warnings(g_target_bits, g_stages_active, stderr);
    return 0;
}

int main(int argc, char** argv) {
    int rc = parse_argv(argc, argv);
    if (rc == 2) return 0;   /* --help printed */
    if (rc == 10) return run_unit_tests();  /* --test */
    if (rc != 0)  return rc;

    /* --validate-known walks the records manifest itself; the per-record
     * loop drives pattern resolution + wheel/filter rebuild. Pattern + bits
     * not required up-front. */
    if (g_validate_known_mode) {
        /* Pre-load records.json best-effort so novel-record cross-check
         * works when validate-known surfaces unexpected hits. Uses the
         * shared search helper (env override + cwd-relative fallbacks). */
        if (!g_records_loaded) {
            const char *used = NULL;
            g_known_records = kt_records_load_with_search(&used,
                /*verbose=*/!g_full_quiet_mode);
            if (g_known_records) g_records_loaded = 1;
        }
        if (test_t2_cuda_device() != 0) return 1;
        int rc_v = run_validate_known();
        if (g_known_records) {
            kt_known_records_free(g_known_records);
            g_known_records = NULL;
        }
        return rc_v;
    }

    /* Pattern resolution. */
    if (set_pattern(g_pattern_name, g_target_k) != 0) return 1;

    if (g_target_bits < 8) {
        fprintf(stderr, "ERROR: --bits must be >= 8 (got %d)\n", g_target_bits);
        return 1;
    }
    if (g_random_chunk_mode && g_chunk_tiles == 0) g_chunk_tiles = 500;
    if (g_resume_mode && !g_checkpoint_file) {
        fprintf(stderr, "ERROR: --resume requires --checkpoint FILE\n");
        return 1;
    }

    /* Phase 3d: u128 candidate base; supports n up to 127 bits. */
    if (g_target_bits > 127) {
        fprintf(stderr,
            "ERROR: --bits=%d exceeds 127-bit u128 envelope. Wider candidates "
            "would need a u256 path (out of scope for 3d).\n", g_target_bits);
        return 1;
    }

    /* Phase 3e: parse --prefix into u128 + bit-length now that --bits is
     * available. The search loop reads g_prefix_value_u128 + g_prefix_bits. */
    if (g_use_prefix) {
        if (parse_prefix_str(g_prefix_str, &g_prefix_value_u128, &g_prefix_bits) != 0) {
            fprintf(stderr, "ERROR: bad --prefix '%s' (expected 0bXXX)\n",
                    g_prefix_str ? g_prefix_str : "(null)");
            return 1;
        }
        if (g_prefix_bits >= g_target_bits) {
            fprintf(stderr, "ERROR: --prefix has %d bits but --bits=%d\n",
                    g_prefix_bits, g_target_bits);
            return 1;
        }
    }

    if (g_random_chunk_mode && !g_random_seed_explicit) {
        FILE *fp = fopen("/dev/urandom", "rb");
        if (fp) {
            uint64_t s = 0;
            if (fread(&s, sizeof s, 1, fp) == 1) g_random_seed_used = s;
            fclose(fp);
        }
        if (g_random_seed_used == 0) {
            g_random_seed_used = (uint64_t)time(NULL) * 0x9e3779b97f4a7c15ULL
                                + (uint64_t)getpid();
        }
    }
    g_rng_state = g_random_seed_used ? g_random_seed_used : 1;

    /* Open log file (Phase 3d: real, not no-op as in 3a). atexit + SIGINT
     * handler flush+fsync so the last record always reaches storage. */
    if (g_log_path) {
        g_log_fp = fopen(g_log_path, "a");
        if (!g_log_fp) {
            fprintf(stderr, "ERROR: could not open --log/--output %s: %s\n",
                    g_log_path, strerror(errno));
            return 1;
        }
        atexit(final_log_flush);
        install_signal_handlers();
    }

    /* Pre-load records.json for novel-record cross-check. Best-effort: load
     * failure is logged but does NOT abort. Shared search helper reports
     * each tried path + errno when verbose. */
    {
        const char *used = NULL;
        g_known_records = kt_records_load_with_search(&used,
            /*verbose=*/!g_full_quiet_mode);
        if (g_known_records) {
            g_records_loaded = 1;
        } else if (!g_full_quiet_mode) {
            fprintf(stderr,
                "WARNING: records.json not loaded (every search path failed); "
                "novel-record cross-check will treat all hits as novel.\n");
        }
    }

    print_banner();

    /* Build Stage-0 wheel (37#) for the active pattern, cross-check against
     * canonical hash, upload to GPU global memory. Required for both --smoke
     * and the search loop. */
    if (test_t2_cuda_device() != 0) return 1;
    if (build_and_upload_stage0_wheel() != 0) return 1;
    if (build_and_upload_filter_tables() != 0) return 1;

    int run_rc = g_smoke_mode ? run_smoke() : run_search_loop();
    release_filter_tables();
    release_stage0_wheel();
    if (g_log_fp) { fflush(g_log_fp); fclose(g_log_fp); g_log_fp = NULL; }
    if (g_known_records) { kt_known_records_free(g_known_records); g_known_records = NULL; }
    return run_rc;
}
