/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_cli.h — engine flag-state header.  Defines the cross-TU surface for
 * parse_argv + print_usage, extracted from kt_filter_v8.cu in W20-DEC
 * Phase 2 Step 5.
 *
 * Design (brief's "approach 1"): flag globals stay DEFINED in core
 * (kt_filter_v8.cu) where they live next to the engine paths that read
 * them; this header declares them `extern` so kt_cli.c can write them
 * from parse_argv.  Same scheme as run_search_loop's pre-existing
 * implicit "everything is a global" pattern, just with the linkage made
 * explicit at the TU boundary.
 *
 * The KT_* constants for flag values (prefix mode, primorial range,
 * stage bitmask, stream pool) move into this header too — they are
 * referenced from both kt_filter_v8.cu and kt_cli.c, so the single
 * source of truth lives here.
 *
 * Why expose so many externs?  Routine flag-add work then requires:
 *   1. add `int g_x = 0;` near related globals in core
 *   2. add `extern int g_x;` in this header
 *   3. add parse logic + help text in kt_cli.c
 *   4. use g_x in core
 * That is one extra step vs the monolith.  Trade-off is parse-loop
 * navigation: the 270-LOC parse_argv + 70-LOC print_usage live in a
 * dedicated TU rather than buried in the engine.
 */
#ifndef KT_CLI_H
#define KT_CLI_H

#include <stdint.h>
#include <stdio.h>           /* FILE * for kt_emit_envelope_warnings */

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t u64;       /* mirrors the typedef in core; harmless duplicate */

/* Stream pool sizing.  Moved from kt_filter_v8.cu so both TUs see the same
 * literal — parse_argv uses these in --gpu-streams bounds messages, the
 * engine uses them to size the stream array. */
#define KT_MAX_STREAMS         8
#define KT_NUM_STREAMS_DEFAULT 3

/* Primorial wheel index range (zero-indexed in kt_first_primes[]).
 * Used by parse_argv for --primorial clamp and by run_search_loop. */
#define KT_PRIMORIAL_MIN_IDX   4    /* 11# (5 primes) — historical floor */
#define KT_PRIMORIAL_MAX_IDX   14   /* 47# (15 primes) — T2.1 ceiling */
#define KT_PRIMORIAL_DEFAULT   11   /* 37# — production v8 baseline */

/* Phase-9 prefix-walk mode enumeration. */
#define KT_PREFIX_MODE_INHERIT 0
#define KT_PREFIX_MODE_SEQ     1
#define KT_PREFIX_MODE_RANDOM  2

/* Filter cascade stage bitmask (Phase 3c).  Used by parse_argv for the
 * --no-stage-* flags and by the kernel-launch dispatcher. */
#define KT_STAGE_L2     (1u << 0)
#define KT_STAGE_EXT_L2 (1u << 1)
#define KT_STAGE_LINE   (1u << 2)
#define KT_STAGE_FERMAT (1u << 3)

extern const char *KT_BINARY_NAME;

/* Wheel upper-prime catalog.  Defined in kt_filter_v8.cu next to the
 * wheel-build paths that consume it; declared extern here so parse_argv's
 * --primorial clamp warnings can name the actual prime.  In C++ a plain
 * `const T x[]` at namespace scope has internal linkage — this extern decl
 * forces external linkage so kt_cli.c (C) can find the symbol at link time. */
extern const uint32_t kt_first_primes[15];

/* ---- Search options ---- */
extern const char* g_pattern_name;
extern int         g_target_bits;
extern int         g_target_k;
extern int         g_primorial_n_primes;
extern const char* g_wheel_expr;
extern int         g_threads;
extern int         g_random_chunk_mode;
extern int         g_sequential_mode;
extern int         g_smoke_mode;
extern u64         g_chunk_tiles;
extern uint64_t    g_random_seed_used;
extern int         g_random_seed_explicit;
extern int         g_verbose_rotation;
extern unsigned __int128 g_inject_cursor_offset;

/* ---- Prefix sharding ---- */
extern int         g_use_prefix;
extern const char* g_prefix_str;
extern int         g_prefix_mode;
extern const char *g_prefix_mode_str;
extern int         g_prefix_lanes;
extern int         g_prefix_lane_id;
extern int         g_exhaustive_mode;

/* ---- Output / quiet ---- */
extern const char* g_log_path;
extern int         g_quiet_mode;
extern int         g_full_quiet_mode;
extern double      g_report_interval_sec;
extern const char* g_bench_jsonl_path;

/* ---- Run limits ---- */
extern int         g_max_batches;
extern double      g_max_time_sec;
extern unsigned int g_stages_active;

/* ---- KPI / validate-known ---- */
extern const char *g_kpi_target_base;
extern int         g_kpi_early_exit;
extern int         g_validate_known_mode;
extern int         g_validate_known_require_coverage;
extern int         g_validate_target_k;
extern double      g_validate_per_record_budget_sec;
extern const char *g_validate_expected_base;
extern int         g_validate_hit_seen;

/* ---- Checkpoint / resume ---- */
extern const char* g_checkpoint_file;
extern int         g_checkpoint_interval_sec;
extern const char* g_resume_file;
extern int         g_resume_mode;

/* ---- CPU-internal flags (accepted, echoed; ignored on GPU hot path) ---- */
extern int g_cpu_flag_no_line_sieve;
extern int g_cpu_flag_no_bitvec;
extern int g_cpu_flag_force_bitvec;
extern int g_cpu_flag_opt_fermat_set;
extern int g_cpu_flag_opt_fermat_val;
extern int g_cpu_flag_opt_mont_fermat_set;
extern int g_cpu_flag_opt_mont_fermat_val;
extern int g_cpu_flag_opt_prefetch_set;
extern int g_cpu_flag_opt_prefetch_val;
extern int g_cpu_flag_opt_bitscan_set;
extern int g_cpu_flag_opt_bitscan_val;
extern int g_cpu_flag_opt_line_cap;
extern int g_cpu_flag_pin;
extern int g_cpu_flag_pin_base_set;
extern int g_cpu_flag_pin_base_val;
extern int g_cpu_flag_sieve_only;

/* ---- GPU device + arch ---- */
extern int         g_gpu_device;
extern int         g_gpu_device_explicit;
extern u64         g_gpu_batch_size;
extern int         g_gpu_streams;
extern const char* g_gpu_arch_label;

/* ---- F* feature toggles ---- */
extern int g_f1_validator_enabled;
extern int g_f2_rcu_enabled;
extern int g_f18_yield_enabled;
extern int g_f22_enabled;
extern int g_f23_enabled;
extern int g_f24_enabled;

/* ---- Helpers that parse_argv calls; defined in core, exposed for the
 * extracted parse_argv.  parse_argv calls kt_print_pattern_catalog on
 * --list-patterns and kt_emit_envelope_warnings as its final post-parse
 * step (formerly inline). ---- */
int  kt_print_pattern_catalog(void);
void kt_emit_envelope_warnings(int bits, unsigned stages_active, FILE *out);

/* ---- CLI surface ---- */
void print_usage(const char *prog);
int  parse_argv(int argc, char **argv);

#ifdef __cplusplus
}
#endif

#endif /* KT_CLI_H */
