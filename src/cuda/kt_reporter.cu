/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_reporter.cu — host-side periodic-tick reporter state machine,
 * extracted from kt_filter_v8.cu in W20-DEC Phase 3 Step 7.
 *
 * Per the brief's preferred alternative (Step 7: "extract only the
 * host-side reporter state machine while leaving CUDA symbol reads in
 * core"), this TU does NOT call cudaMemcpyFromSymbol.  Core fetches the
 * W18-K counters via the s_w19b_counter_stream (after ordering it
 * against the latest recorded compute-stream end events), then passes
 * the snapshot to kt_reporter_emit().
 *
 * The W19-A-5 trip-wire path still calls kt_fatal_cleanup() on fire —
 * that helper is declared in kt_signal.h and lives in kt_signal.cu, so
 * the reporter's link surface is: kt_signal (kt_fatal_cleanup) +
 * kt_cli.h (g_full_quiet_mode + g_report_interval_sec extern decls).
 *
 * Lives as a .cu (not .c) for build symmetry with kt_signal.cu and so
 * `unsigned __int128` (no <cstdint> mapping) and the u128 string-format
 * helper compile under the same nvcc toolchain as the engine.
 */
#include "kt_reporter.h"
#include "kt_cli.h"        /* g_full_quiet_mode, g_report_interval_sec */
#include "kt_signal.h"     /* kt_fatal_cleanup */

#include <stdio.h>
#include <stdint.h>
#include <math.h>          /* log() for bits_swept_log2 */

/* Host-side u128 helpers — small enough to keep file-scope-static here
 * rather than exposing the corresponding core definitions.  Both match
 * the inline implementations in kt_filter_v8.cu byte-for-byte (lines
 * 493 and 514 pre-extract). */
static void kt_reporter_u128_format_dec(unsigned __int128 v,
                                        char *buf, size_t buflen) {
    if (!buf || buflen == 0) return;
    if (buflen < 2) { buf[0] = '\0'; return; }
    if (v == 0) { buf[0] = '0'; buf[1] = '\0'; return; }
    char tmp[40];
    int  n = 0;
    while (v != 0 && n < (int)sizeof(tmp)) {
        unsigned int d = (unsigned int)(v % 10u);
        tmp[n++] = (char)('0' + d);
        v /= 10u;
    }
    if ((size_t)n + 1 > buflen) {
        buf[0] = '0';
        buf[1] = '\0';
        return;
    }
    for (int i = 0; i < n; i++) buf[i] = tmp[n - 1 - i];
    buf[n] = '\0';
}

static double kt_reporter_u128_to_double(unsigned __int128 v) {
    uint64_t hi = (uint64_t)(v >> 64);
    uint64_t lo = (uint64_t)v;
    return (double)hi * 18446744073709551616.0 + (double)lo;
}

void kt_reporter_init(kt_reporter_state_t *s, double t0) {
    if (!s) return;
    s->last_report           = t0;
    s->last_cand             = 0;
    s->last_surv             = 0;
    s->last_min_sample       = t0;
    s->last_kernel_ms_at_min = 0.0;
    s->min_util_pct          = 100.0;
    s->have_min_sample       = 0;
    s->last_w18k_admit       = 0;
    s->last_w18k_pass_l2     = 0;
    s->last_w18k_pass_ext_l2 = 0;
    s->last_w18k_pass_line   = 0;
    s->last_w18k_pass_fermat = 0;
    s->w19a_baseline_L2_rate = -1.0;
    s->w19a_tick_count       = 0;
    s->w19a_tripwire_rel     = KT_W19A_TRIPWIRE_REL_DEFAULT;
}

void kt_reporter_set_tripwire_rel(kt_reporter_state_t *s, double rel) {
    if (!s) return;
    if (rel <= 0.0) return;
    s->w19a_tripwire_rel = rel;
}

void kt_reporter_min_util(kt_reporter_state_t *s,
                          double now, double total_kernel_ms) {
    if (!s) return;
    /* Phase 3f.1: 100ms wallclock min-util sampler. Runs unconditionally —
     * not gated on --full-quiet or g_report_interval_sec. The previous
     * design only sampled inside the reporter block, so --full-quiet runs
     * (every bench harness row) had no real per-tick min and seeded the
     * gate-relevant min from the run mean at end-of-run. */
    double sample_dt_ms = (now - s->last_min_sample) * 1000.0;
    if (sample_dt_ms >= KT_MIN_SAMPLE_MS) {
        double tick_kernel_ms = total_kernel_ms - s->last_kernel_ms_at_min;
        double tick_util      = (sample_dt_ms > 0)
                                ? (tick_kernel_ms / sample_dt_ms * 100.0)
                                : 0.0;
        if (tick_util > 100.0) tick_util = 100.0;
        if (tick_util < 0.0)   tick_util = 0.0;
        if (s->have_min_sample) {
            if (tick_util < s->min_util_pct) s->min_util_pct = tick_util;
        } else {
            s->min_util_pct    = tick_util;
            s->have_min_sample = 1;
        }
        s->last_min_sample       = now;
        s->last_kernel_ms_at_min = total_kernel_ms;
    }
}

int kt_reporter_should_emit(const kt_reporter_state_t *s, double now) {
    if (!s) return 0;
    if (g_full_quiet_mode) return 0;
    if (g_report_interval_sec <= 0) return 0;
    return (now - s->last_report) >= g_report_interval_sec;
}

void kt_reporter_emit(kt_reporter_state_t *s,
                      const kt_reporter_inputs_t *in) {
    if (!s || !in) return;

    double dt      = in->now - in->t0;
    double dt_step = in->now - s->last_report;
    unsigned __int128 step_cand = in->total_cand - s->last_cand;
    unsigned long long step_surv = in->total_surv - s->last_surv;
    double cand_rate = dt_step > 0
        ? kt_reporter_u128_to_double(step_cand) / dt_step : 0.0;
    double useful_rate_step = (in->primorial > 0)
        ? cand_rate * (double)in->n_admissible / (double)in->primorial : 0.0;
    double surv_rate = dt_step > 0 ? (double)step_surv / dt_step : 0.0;
    double cand_d    = kt_reporter_u128_to_double(in->total_cand);
    double frac      = cand_d > 0 ? (double)in->total_surv / cand_d : 0.0;
    double gpu_util  = (dt > 0)
        ? (in->total_kernel_ms / (dt * 1000.0) * 100.0) : 0.0;
    if (gpu_util > 100.0) gpu_util = 100.0;
    double prove_ratio = (in->total_kernel_ms > 0)
                         ? (in->total_prove_ms / in->total_kernel_ms) : 0.0;

    char cand_buf[40];
    kt_reporter_u128_format_dec(in->total_cand, cand_buf, sizeof cand_buf);
    /* Sobs-B §0.2: tile_window covers tiles touched this run; in
     * sequential/prefix modes [0, T-1] under the initial anchor.
     * bits_swept_log2 = log2(unique_tiles_visited).  At b101 with
     * tile_count ≈ 2^(101 - log2(primorial)) ≈ 2^54, this gives a
     * direct read-out of how much of the bit_range has been swept. */
    double bits_swept_log2 = (in->unique_tiles_visited > 0)
        ? log((double)in->unique_tiles_visited) / log(2.0)
        : 0.0;
    unsigned long long t1_idx = (in->unique_tiles_visited > 0)
        ? in->unique_tiles_visited - 1ULL : 0ULL;
    fprintf(stderr,
        "[reporter] t=%.2fs batches=%d cand=%s surv=%llu hits=%d "
        "cand/s=%.3e useful/s=%.3e surv/s=%.3e surv/cand=%.3e "
        "gpu=%.0f%% (min=%.0f%%) (prove/k1=%.2fx) "
        "anchor=0x%016llx%016llx tile_window=[0,%llu] "
        "anchors_visited=%llu bits_swept_log2=%.2f\n",
        dt, in->batches, cand_buf, in->total_surv, in->total_hits,
        cand_rate, useful_rate_step, surv_rate, frac, gpu_util,
        s->have_min_sample ? s->min_util_pct : gpu_util, prove_ratio,
        (unsigned long long)(in->saved_initial_anchor >> 64),
        (unsigned long long)in->saved_initial_anchor,
        t1_idx,
        in->anchors_visited, bits_swept_log2);

    /* W18-K kills line + W19-A-5 trip-wire.  Counters come from the
     * caller (which read them via cudaMemcpyFromSymbolAsync on the
     * s_w19b_counter_stream and synchronized) — no CUDA calls here.
     * If the caller's read soft-failed (valid_w18k=0), skip the kills
     * line + trip-wire but still advance last_report/last_cand/last_surv
     * at end-of-function so the next tick's main-line deltas stay
     * accurate. */
    if (!in->valid_w18k) goto post_tick;
    {
    unsigned long long d_admit = in->w18k_admit       - s->last_w18k_admit;
    unsigned long long d_pl2   = in->w18k_pass_l2     - s->last_w18k_pass_l2;
    unsigned long long d_pel2  = in->w18k_pass_ext_l2 - s->last_w18k_pass_ext_l2;
    unsigned long long d_pli   = in->w18k_pass_line   - s->last_w18k_pass_line;
    unsigned long long d_pfe   = in->w18k_pass_fermat - s->last_w18k_pass_fermat;
    unsigned long long kL2     = (d_admit > d_pl2)   ? d_admit - d_pl2   : 0;
    unsigned long long kExt    = (d_pl2   > d_pel2)  ? d_pl2   - d_pel2  : 0;
    unsigned long long kLine   = (d_pel2  > d_pli)   ? d_pel2  - d_pli   : 0;
    unsigned long long kFer    = (d_pli   > d_pfe)   ? d_pli   - d_pfe   : 0;
    fprintf(stderr,
        "[reporter] kills: stage0=%llu L2=%llu ext=%llu linesieve=%llu fermat2=%llu\n",
        d_admit, kL2, kExt, kLine, kFer);
    s->last_w18k_admit       = in->w18k_admit;
    s->last_w18k_pass_l2     = in->w18k_pass_l2;
    s->last_w18k_pass_ext_l2 = in->w18k_pass_ext_l2;
    s->last_w18k_pass_line   = in->w18k_pass_line;
    s->last_w18k_pass_fermat = in->w18k_pass_fermat;

    /* W19-A-5 (multi-angle P1-2): automated alignment-regression
     * trip-wire on L2_pass_rate.  Skip ticks where admit_delta is
     * tiny (< 1000) because the per-tick rate is statistically
     * meaningless there — early end-of-prefix ticks, very short
     * runs, etc.  Baseline records on tick 3 to avoid the warmup
     * spike of tick 1 (cold caches) + tick 2 (still spinning up).
     * From tick 4 onward, any >tripwire_rel relative divergence in
     * L2_pass_rate is interpreted as a kernel-side alignment
     * regression and aborts via kt_fatal_cleanup so the surface
     * area is identical to the kernel-launch FATAL trip-wire
     * (CUDA reset + _exit(2), no atexit shenanigans). */
    if (d_admit > KT_W19A_TRIPWIRE_MIN_ADMIT) {
        double L2_pass_rate = (double)d_pl2 / (double)d_admit;
        s->w19a_tick_count++;
        if (s->w19a_tick_count == 3) {
            s->w19a_baseline_L2_rate = L2_pass_rate;
            fprintf(stderr,
                "[W19-A] trip-wire baseline L2_pass_rate=%.4f "
                "(threshold=%.4f%% relative)\n",
                s->w19a_baseline_L2_rate,
                s->w19a_tripwire_rel * 100.0);
        } else if (s->w19a_tick_count > 3 &&
                   s->w19a_baseline_L2_rate > 0.0) {
            double delta = L2_pass_rate - s->w19a_baseline_L2_rate;
            if (delta < 0.0) delta = -delta;
            double rel = delta / s->w19a_baseline_L2_rate;
            if (rel > s->w19a_tripwire_rel) {
                char buf[256];
                snprintf(buf, sizeof buf,
                    "[FATAL] W19-A trip-wire: L2_pass_rate=%.4f "
                    "diverged from baseline=%.4f by %.4f%% > %.4f%% "
                    "(tick %d) — likely cursor-alignment regression\n",
                    L2_pass_rate, s->w19a_baseline_L2_rate,
                    rel * 100.0, s->w19a_tripwire_rel * 100.0,
                    s->w19a_tick_count);
                kt_fatal_cleanup(2, buf);
            }
        }
    }
    } /* close `if (!in->valid_w18k) goto post_tick; {` block */

post_tick:
    s->last_report = in->now;
    s->last_cand   = in->total_cand;
    s->last_surv   = in->total_surv;
}
