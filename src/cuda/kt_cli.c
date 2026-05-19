/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_cli.c — argv parser + --help text.  Bodies moved verbatim from
 * kt_filter_v8.cu in W20-DEC Phase 2 Step 5.
 *
 * Approach 1 (brief): the 67 flag globals stay DEFINED in core, where the
 * engine paths that read them live.  This TU only WRITES to them via the
 * extern declarations in kt_cli.h.  Same memory, same linker symbol —
 * just the parse loop moves out so the engine TU drops ~340 LOC of help
 * text and dispatch logic.
 *
 * KT_BUILD_SHA is plumbed in from the Makefile via -D on this TU's compile
 * line (mirroring how nvcc passes it to kt_filter_v8.cu).  --version is the
 * only consumer in this file.
 */
#include "kt_cli.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifndef KT_BUILD_SHA
#define KT_BUILD_SHA "unknown"
#endif

/* kt_first_primes is declared extern in kt_cli.h (shared with the wheel-build
 * path in core); --primorial clamp warnings here name the actual prime at
 * the clamp boundary. */

void print_usage(const char* prog) {
    printf("Usage: %s [options]\n\n", prog);
    printf("k-tuplet GPU filter (Phase 3a scaffold; B1 port path)\n\n");
    printf("Search options:\n");
    printf("  --pattern NAME        Pattern name from catalog (e.g. KT19_P0).  See --list-patterns for available names.\n");
    printf("  --list-patterns       Print catalog of admissible patterns and exit\n");
    printf("  --k N                 Tuple length (alias --target N)\n");
    printf("  --target N            Tuple length (alias --k N)\n");
    printf("  --bits N              Bit-size of candidate base (required)\n");
    printf("  --primorial N         Wheel upper-prime index (zero-indexed): N=11 -> 37# (default), N=12 -> 41#, N=13 -> 43#, N=14 -> 47#\n");
    printf("  --wheel-expr X#[/Y...]  Structural wheel expression, e.g. 47#, 47#/31, 47#/17/31. Overrides --primorial.\n");
    printf("  --threads N           Host prove threads after GPU survivors arrive (default 1)\n");
    printf("  --prefix 0bXXX        Binary prefix to confine search\n");
    printf("  --random              Random-chunk search (alias for --prefix-mode random)\n");
    printf("  --prefix-mode {sequential|random}   Phase-9: canonical prefix walk mode (CC parity)\n");
    printf("  --prefix-lanes N      Phase-9: shard a single prefix across N GPUs (CC parity)\n");
    printf("  --prefix-lane-id ID   Phase-9: this binary's lane (0..N-1)\n");
    printf("  --exhaustive          Phase-9: sequential prefix sweep; emits PREFIX EXHAUSTED on completion\n");
    printf("  --chunk-tiles N       Tiles per random anchor interval/chunk (default: 500 in --random mode)\n");
    printf("  --random-seed HEX     Sobs-B: explicit u64 seed for --random determinism (default: /dev/urandom)\n");
    printf("  --verbose-rotation    Emit per-batch [search] anchor= line in --random mode (default: off; high-volume diagnostic)\n");
    printf("  --inject-cursor-offset HEX  W18-F DEBUG: add this u128 to cursor after init (misalignment-injection regression test; default 0)\n");
    printf("  --seed HEX            Phase-9: alias for --random-seed (CC parity)\n");
    printf("  --version, -V         Print binary name + build_sha + compile date, then exit\n");
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
    printf("  --validate-per-record-budget <sec>   override default 60s per-record budget in --validate-known mode (also via env KT_VALIDATE_PER_RECORD_BUDGET_SEC)\n");
    printf("  --kpi-target-base DEC  KPI mode: stop on emitting matching record (mutually exclusive with --validate-known)\n");
    printf("  --checkpoint FILE     Phase-9: atomic checkpoint save every --ckpt-interval s\n");
    printf("  --resume [FILE]       Phase-9: resume cursor + counters from checkpoint\n");
    printf("  --ckpt-interval N     Phase-9: checkpoint interval seconds (default 60)\n\n");
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
    printf("  --no-stage-fermat     Skip Stage-3 Fermat-2 prefilter (Phase 3d)\n");
    printf("  --enable-f18-yield    S2a: per-(line_prime,residue) yield counters -> bench/yield_counters_<bin>_<pid>.jsonl\n");
    printf("  --enable-f22-reservoir S2a: 1000-slot post-Fermat reservoir -> bench/reservoir_<bin>_<pid>.jsonl\n");
    printf("  --enable-f23-texture  S2b-F23: 128-slot texture reservoir -> bench/texture_<bin>_<pid>.jsonl (default OFF)\n");
  printf("  --enable-f24-cascade  S2b-F24: enumerate k-2 sub-tuplets of active pattern, score by L2 kill-rate, print to stderr (default OFF; host-only)\n");
    printf("  --enable-f1-validator S2b-F1: compare KT19_P0/37# baked masks vs runtime, exit 0 on PASS (default OFF; KT19_P0-only; see G22)\n");
    printf("  --enable-f2-rcu       S2b-F2: dual-bank __constant__ filter mirror; host-side only; default OFF; infrastructure for T2.x live wheel-rotation\n\n");
    printf("Modes:\n");
    printf("  --test                Run unit-test suite\n");
    printf("  --smoke               One-batch sieve assertion (returns OK after counter > 0)\n");
    printf("  --validate-known [k]  Reproduce records via prefix sharding (k=16..19 default)\n");
    printf("  --validate-known-require-coverage  W19-A-4 (multi-angle P1-10/P1-5): fail gate if any record SKIPPED (wheel build cap or otherwise); ensures production-primorial sweeps have non-empty validation coverage\n");
    printf("  --help / -h           This help\n");
}

int parse_argv(int argc, char** argv) {
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
            /* Phase 9 T2.1: --primorial N selects wheel size by upper-prime
             * index (zero-indexed in kt_first_primes[]).  Brief mapping:
             *   N=11 -> 37# (12 primes, production default)
             *   N=12 -> 41# (13 primes; streaming CRT-join lifts from 37#)
             *   N=13 -> 43# (14 primes)
             *   N=14 -> 47# (15 primes; deepest T2.1 lift)
             * Out-of-range values clamp with a stderr warning so old runner
             * scripts that pass --primorial 5 (the legacy default) don't
             * silently drop into a too-small wheel. */
            int n = atoi(argv[++i]);
            if (n < KT_PRIMORIAL_MIN_IDX) {
                fprintf(stderr,
                    "WARNING: --primorial %d below floor; clamped to %d (= %u#)\n",
                    n, KT_PRIMORIAL_MIN_IDX, kt_first_primes[KT_PRIMORIAL_MIN_IDX]);
                n = KT_PRIMORIAL_MIN_IDX;
            }
            if (n > KT_PRIMORIAL_MAX_IDX) {
                fprintf(stderr,
                    "WARNING: --primorial %d above ceiling; clamped to %d (= %u#)\n",
                    n, KT_PRIMORIAL_MAX_IDX, kt_first_primes[KT_PRIMORIAL_MAX_IDX]);
                n = KT_PRIMORIAL_MAX_IDX;
            }
            g_primorial_n_primes = n;
        }
        else if (!strcmp(a, "--wheel-expr") && i+1 < argc) {
            g_wheel_expr = argv[++i];
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
            /* Phase 9 T1.2: --random is now an alias for --prefix-mode random.
             * Sets the canonical g_prefix_mode + retains g_random_chunk_mode
             * for the existing observability scaffold (banner, Bloom).
             * Phase 4-GPU lands mid-run anchor rotation via xorshift64* —
             * cursor is redrawn each batch from [lane_start, range_end). */
            g_random_chunk_mode = 1;
            g_prefix_mode       = KT_PREFIX_MODE_RANDOM;
        }
        else if (!strcmp(a, "--prefix-mode") && i+1 < argc) {
            /* Phase 9 T1.2: CC-parity canonical flag.  "sequential" walks
             * the prefix-restricted tile range deterministically and exits
             * on completion; "random" picks chunk anchors via xorshift64*
             * PRNG, rotating each batch (Phase 4-GPU, live). */
            g_prefix_mode_str = argv[++i];
            if (!strcmp(g_prefix_mode_str, "sequential")) {
                g_prefix_mode       = KT_PREFIX_MODE_SEQ;
                g_random_chunk_mode = 0;
            } else if (!strcmp(g_prefix_mode_str, "random")) {
                g_prefix_mode       = KT_PREFIX_MODE_RANDOM;
                g_random_chunk_mode = 1;
            } else {
                fprintf(stderr,
                    "ERROR: --prefix-mode '%s' invalid; must be 'sequential' "
                    "or 'random'\n", g_prefix_mode_str);
                return 1;
            }
        }
        else if (!strcmp(a, "--prefix-lanes") && i+1 < argc) {
            g_prefix_lanes = atoi(argv[++i]);
            if (g_prefix_lanes < 0) {
                fprintf(stderr, "ERROR: --prefix-lanes must be >= 0 (got %d)\n",
                        g_prefix_lanes);
                return 1;
            }
        }
        else if (!strcmp(a, "--prefix-lane-id") && i+1 < argc) {
            g_prefix_lane_id = atoi(argv[++i]);
            if (g_prefix_lane_id < 0) {
                fprintf(stderr, "ERROR: --prefix-lane-id must be >= 0 (got %d)\n",
                        g_prefix_lane_id);
                return 1;
            }
        }
        else if (!strcmp(a, "--seed") && i+1 < argc) {
            /* Phase 9 T1.2: CC-parity alias for --random-seed. */
            const char *s = argv[++i];
            int base = 10;
            if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
            g_random_seed_used = (uint64_t)strtoull(s, NULL, base);
            g_random_seed_explicit = 1;
        }
        else if (!strcmp(a, "--exhaustive")) {
            /* Phase 9 T1.2: requires --prefix; forces sequential mode and
             * arms the PREFIX EXHAUSTED banner + bench/exhaustive_complete.jsonl
             * row when the lane's tile range is fully swept. */
            g_exhaustive_mode = 1;
            if (g_prefix_mode == KT_PREFIX_MODE_INHERIT) {
                g_prefix_mode = KT_PREFIX_MODE_SEQ;
            }
            g_random_chunk_mode = 0;
        }
        else if (!strcmp(a, "--chunk-tiles") && i+1 < argc) {
            g_chunk_tiles = (u64)strtoull(argv[++i], NULL, 10);
        }
        else if (!strcmp(a, "--verbose-rotation")) {
            g_verbose_rotation = 1;
        }
        else if (!strcmp(a, "--inject-cursor-offset") && i+1 < argc) {
            /* W18-F DEBUG: parse u64 (HEX 0x... or decimal), promote to u128.
             * Added to cursor after all init in run_search_loop; default 0. */
            const char *s = argv[++i];
            int base = 10;
            if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
            g_inject_cursor_offset = (unsigned __int128)strtoull(s, NULL, base);
        }
        else if (!strcmp(a, "--random-seed") && i+1 < argc) {
            /* Sobs-B: explicit seed for deterministic --random replays.
             * Hex (0x...) or decimal accepted. */
            const char *s = argv[++i];
            int base = 10;
            if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
            g_random_seed_used = (uint64_t)strtoull(s, NULL, base);
            g_random_seed_explicit = 1;
        }
        else if (!strcmp(a, "--list-patterns")) {
            /* Phase 9 T1.2 (addendum): print catalog and exit cleanly. */
            kt_print_pattern_catalog();
            return 2;       /* same convention as --help / --version */
        }
        else if (!strcmp(a, "--version") || !strcmp(a, "-V")) {
            /* Sobs-C §2.1: print binary id + build sha + nvcc compile date so
             * env-overridden KT_BUILD_SHA is visible without running the
             * banner.  Returns control to main → return 0 in main below. */
            printf("%s build_sha=%s compiled=%s %s\n",
                   KT_BINARY_NAME, KT_BUILD_SHA, __DATE__, __TIME__);
            return 2;       /* same convention as --help: cause main to exit 0 */
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
        else if (!strcmp(a, "--validate-per-record-budget") && i+1 < argc) {
            /* W3/W6 plumbing fix: previously --max-time was silently overwritten
             * by the hardcoded 60s g_validate_per_record_budget_sec inside
             * run_validate_known(); no caller could elevate the per-record
             * budget. This flag (and KT_VALIDATE_PER_RECORD_BUDGET_SEC env)
             * is the real knob. */
            g_validate_per_record_budget_sec = atof(argv[++i]);
        }
        else if (!strcmp(a, "--checkpoint") && i+1 < argc) {
            /* Phase 9 T1.2: active checkpoint save path.  Atomically writes
             * cursor + counters to FILE every g_checkpoint_interval_sec
             * (default 60 s) and at clean shutdown / exhaustion. */
            g_checkpoint_file = argv[++i];
        }
        else if (!strcmp(a, "--resume")) {
            /* Phase 9 T1.2: now a real flag.  Optional FILE arg; if absent,
             * resume from --checkpoint FILE (legacy v8 form).  The
             * checkpoint must match (bits, target_k, pattern, prefix, lanes,
             * lane_id) — mismatches print a clear stderr line and start fresh. */
            g_resume_mode = 1;
            if (i+1 < argc && argv[i+1][0] != '-') g_resume_file = argv[++i];
        }
        else if (!strcmp(a, "--ckpt-interval") && i+1 < argc) {
            g_checkpoint_interval_sec = atoi(argv[++i]);
            if (g_checkpoint_interval_sec < 1) g_checkpoint_interval_sec = 1;
        }
        else if (!strcmp(a, "--test")) return 10;
        else if (!strcmp(a, "--smoke")) g_smoke_mode = 1;
        else if (!strcmp(a, "--validate-known")) {
            g_validate_known_mode = 1;
            if (i+1 < argc && argv[i+1][0] != '-') g_validate_target_k = atoi(argv[++i]);
        }
        else if (!strcmp(a, "--validate-known-require-coverage")) {
            /* W19-A-4 (multi-angle P1-10/P1-5): fail the validate-known gate
             * if any record is SKIPPED (wheel build cap/failure at primorial
             * > 11).  Default OFF preserves backward-compatible behavior;
             * production-primorial sweeps should pass this flag so the
             * "validate-known PASS" line means something. */
            g_validate_known_require_coverage = 1;
        }
        else if (!strcmp(a, "--kpi-target-base") && i+1 < argc) {
            /* KPI TTR early-exit.  Stored once at parse time; the
             * run_search_loop entry copies into g_validate_expected_base and
             * the loop body trips g_kpi_early_exit on match. */
            g_kpi_target_base = argv[++i];
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
        else if (!strcmp(a, "--gpu-device") && i+1 < argc) {
            g_gpu_device = atoi(argv[++i]);
            g_gpu_device_explicit = 1;
        }
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
        else if (!strcmp(a, "--enable-f18-yield"))    g_f18_yield_enabled = 1;
        else if (!strcmp(a, "--enable-f22-reservoir")) g_f22_enabled = 1;
        else if (!strcmp(a, "--enable-f23-texture"))   g_f23_enabled = 1;
        else if (!strcmp(a, "--enable-f24-cascade"))   g_f24_enabled = 1;
        else if (!strcmp(a, "--enable-f1-validator"))  g_f1_validator_enabled = 1;
        else if (!strcmp(a, "--enable-f2-rcu"))        g_f2_rcu_enabled = 1;
        else if (a[0] == '-') {
            fprintf(stderr, "Unknown option: %s (try --help)\n", a);
            return 1;
        }
    }
    /* --kpi-target-base reuses the validate-known per-record state
     * (g_validate_expected_base / g_validate_hit_seen).  Validate-known assigns
     * those per-record inside run_validate_known(), so the two modes would
     * fight if combined.  Reject up front. */
    if (g_kpi_target_base && g_validate_known_mode) {
        fprintf(stderr,
            "ERROR: --kpi-target-base and --validate-known are mutually "
            "exclusive (both drive g_validate_expected_base).\n");
        return 1;
    }
    kt_emit_envelope_warnings(g_target_bits, g_stages_active, stderr);
    return 0;
}
