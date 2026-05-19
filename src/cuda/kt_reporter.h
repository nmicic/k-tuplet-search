/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_reporter.h — periodic-tick reporter state machine, extracted from
 * kt_filter_v8.cu in W20-DEC Phase 3 Step 7.
 *
 * Per the brief's preferred alternative: this module owns the HOST-SIDE
 * reporter state machine (min-util sampler, [reporter] line emission,
 * kills delta, W19-A-5 trip-wire baseline + check).  CUDA symbol reads
 * for W18-K counters stay in core (kt_filter_v8.cu's run_search_loop
 * fetches them via cudaMemcpyFromSymbolAsync against the s_w19b counter
 * stream, then passes the snapshot to kt_reporter_emit).
 *
 * Function partition:
 *   - kt_reporter_init        — zero state, seed last_report = t0
 *   - kt_reporter_min_util    — 100ms wallclock min-util sampler; runs
 *                               every loop iteration unconditionally
 *   - kt_reporter_should_emit — predicate: time-to-emit? caller checks
 *                               this BEFORE the CUDA W18-K reads so
 *                               --full-quiet runs skip them
 *   - kt_reporter_emit        — print [reporter] line + kills line, run
 *                               W19-A trip-wire; calls kt_fatal_cleanup
 *                               directly on trip-wire fire
 *
 * Tuning constants previously local to run_search_loop now exposed so
 * tests can lower thresholds for synthetic-regression validation (brief
 * Step 7 verification: "synthetic regression — threshold lowered to
 * 0.001% — still FATALs within 1 tick").  Override via KT_W19A_TRIPWIRE_REL
 * at build time or by patching kt_reporter_set_tripwire_rel() pre-init.
 */
#ifndef KT_REPORTER_H
#define KT_REPORTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Min-util sampler cadence (wallclock ms). 100ms matches Phase 3f.1. */
#ifndef KT_MIN_SAMPLE_MS
#define KT_MIN_SAMPLE_MS 100.0
#endif

/* W19-A-5 trip-wire: relative L2_pass_rate divergence that FATALs.
 * Default 10% (0.10); tests can patch via kt_reporter_set_tripwire_rel(). */
#ifndef KT_W19A_TRIPWIRE_REL_DEFAULT
#define KT_W19A_TRIPWIRE_REL_DEFAULT 0.10
#endif

/* Skip ticks whose admit_delta is below this — statistically meaningless
 * pass-rate.  Matches the inline value in run_search_loop pre-extract. */
#ifndef KT_W19A_TRIPWIRE_MIN_ADMIT
#define KT_W19A_TRIPWIRE_MIN_ADMIT 1000ULL
#endif

/* Persistent reporter state, threaded through the search loop. */
typedef struct kt_reporter_state {
    /* Main reporter cadence. */
    double             last_report;
    unsigned __int128  last_cand;
    unsigned long long last_surv;

    /* 100ms wallclock min-util sampler (Phase 3f.1; runs unconditionally
     * so --full-quiet rows carry a real min, not a degenerate end-of-run
     * mean). */
    double last_min_sample;
    double last_kernel_ms_at_min;
    double min_util_pct;
    int    have_min_sample;

    /* W18-K kill-counter snapshot from the prior reporter tick. */
    unsigned long long last_w18k_admit;
    unsigned long long last_w18k_pass_l2;
    unsigned long long last_w18k_pass_ext_l2;
    unsigned long long last_w18k_pass_line;
    unsigned long long last_w18k_pass_fermat;

    /* W19-A-5 trip-wire state. Tick 3 captures the baseline; from tick 4
     * onward, any |L2_pass_rate - baseline| / baseline > tripwire_rel
     * (default 10%) trips kt_fatal_cleanup. */
    double w19a_baseline_L2_rate;
    int    w19a_tick_count;
    double w19a_tripwire_rel;
} kt_reporter_state_t;

/* Per-tick inputs assembled by run_search_loop and consumed by
 * kt_reporter_emit.  Bundled to avoid a 15-arg function signature. */
typedef struct kt_reporter_inputs {
    /* Timing. */
    double now;
    double t0;
    int    batches;
    int    total_hits;
    unsigned __int128 total_cand;
    unsigned long long total_surv;
    double total_kernel_ms;
    double total_prove_ms;
    /* Run identity. */
    unsigned __int128 saved_initial_anchor;
    uint64_t primorial;
    uint64_t n_admissible;
    unsigned long long anchors_visited;
    unsigned long long unique_tiles_visited;
    /* W18-K snapshot (host-side counters; caller has just synchronized
     * the s_w19b counter stream and read all five symbols).  If
     * valid_w18k == 0 (e.g. stream-wait or memcpy soft-failed), the
     * kills line + trip-wire are skipped this tick, but last_report /
     * last_cand / last_surv still advance so the next tick's main-line
     * deltas remain accurate. */
    int                valid_w18k;
    unsigned long long w18k_admit;
    unsigned long long w18k_pass_l2;
    unsigned long long w18k_pass_ext_l2;
    unsigned long long w18k_pass_line;
    unsigned long long w18k_pass_fermat;
} kt_reporter_inputs_t;

/* Initialize state at search-loop entry.  t0 seeds last_report so the
 * first emit fires after g_report_interval_sec has elapsed. */
void kt_reporter_init(kt_reporter_state_t *s, double t0);

/* Tests may patch the trip-wire threshold (e.g. 0.00001 for synthetic
 * regression).  Must be called BEFORE the third tick (i.e. before the
 * baseline is captured), or it's a no-op. */
void kt_reporter_set_tripwire_rel(kt_reporter_state_t *s, double rel);

/* 100ms wallclock min-util sampler. Caller invokes once per outer loop
 * iteration (unconditionally — independent of g_full_quiet_mode). */
void kt_reporter_min_util(kt_reporter_state_t *s,
                          double now, double total_kernel_ms);

/* Predicate: should we fetch W18-K counters and call kt_reporter_emit
 * this iteration?  Implements:
 *     !g_full_quiet_mode && g_report_interval_sec > 0 &&
 *     (now - state.last_report) >= g_report_interval_sec
 * but reads g_* via extern.  Caller uses the answer to gate the
 * expensive cudaMemcpyFromSymbolAsync block. */
int kt_reporter_should_emit(const kt_reporter_state_t *s, double now);

/* Emit the [reporter] line, kills line, and run the W19-A trip-wire.
 * Updates state.last_*.  May call kt_fatal_cleanup(2, msg) on trip-wire
 * fire — that path does cudaDeviceReset() + _exit(2) and does not
 * return. */
void kt_reporter_emit(kt_reporter_state_t *s,
                      const kt_reporter_inputs_t *in);

#ifdef __cplusplus
}
#endif

#endif /* KT_REPORTER_H */
