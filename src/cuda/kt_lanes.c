/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_lanes.c — pure-math helpers for per-lane bound computation and
 * seed-anchor rotation.  Bodies moved verbatim from kt_filter_v8.cu in
 * W20-DEC Phase 1 Step 1 (lifecycle-split, not refactor).  See kt_lanes.h
 * for the per-function contracts; the in-body comments here mirror what
 * the monolith carried.
 */
#include "kt_lanes.h"

/* Sobs-B §0.1: deterministic per-restart anchor offset.  Returns 0 when
 * seed==0 (sequential mode) or when the bit range is too narrow to permit
 * non-overlapping restart positions.  Otherwise returns
 * (seed % n_positions) << workload_log2, ensuring different processes
 * (multi-GPU, multi-prefix-lane) start at distinct sub-ranges within the
 * same target-bits search window.
 *
 * W18-A : the returned offset is rounded DOWN to a multiple of
 * `primorial` so that adding it to a primorial-aligned cursor preserves the
 * "cursor % primorial == 0" invariant the v7 kernel relies on (otherwise
 * `tile_base + d_offsets[i]` never resolves to an admissible cell and the
 * kernel emits 0 survivors for every batch — silently misses records).
 * 2^workload_log2 = 67108864 is much smaller than the production primorials
 * (37# ≈ 7.4e12, 41# ≈ 304e12), so the round-down can erase the entire raw
 * offset when seed*2^26 < primorial.  That's fine for the "fresh region per
 * restart" intent at primorial granularity — restarts still land on distinct
 * primorial tiles whenever the raw offset spans more than one primorial. */
unsigned __int128 kt_seed_anchor_offset(uint64_t seed, int target_bits,
                                        unsigned __int128 primorial) {
    const int workload_log2 = 26;
    int offset_bits = (target_bits - 1) - workload_log2;
    if (offset_bits <= 0 || seed == 0) return (unsigned __int128)0;
    unsigned __int128 n_positions = (offset_bits >= 128)
        ? ~(unsigned __int128)0
        : ((unsigned __int128)1 << offset_bits);
    unsigned __int128 raw = ((unsigned __int128)seed % n_positions) << workload_log2;
    if (primorial == 0) return raw;             /* defensive; production never passes 0 */
    return (raw / primorial) * primorial;       /* W18-A: primorial-aligned */
}

/* W19-A-3 (multi-angle P1-8): pure helper extracted from run_search_loop's
 * --prefix-lanes branch so the lane-bound rounding invariant (W18-A site
 * 2 + W19-A-2 lane_max round) can be unit-tested in T46b without a GPU.
 *
 * Inputs:
 *   cursor_in    — unrounded cursor before lane sharding (= prefix<<shift,
 *                  or the bit-aligned base in the !use_prefix case).
 *   range_end_in — unrounded range_end (= (prefix+1)<<shift).
 *   lanes        — total lanes (g_prefix_lanes, must be >= 1).
 *   lane_id      — this lane (must be 0..lanes-1).
 *   primorial    — wheel primorial (>= 1).
 *
 * Output (lane_min / lane_max / lane_start) is the shard for this lane:
 *   - lane_min      = round_down(unrounded_lane_min, primorial)
 *   - lane_max      = round_down(unrounded_lane_min + lane_size, primorial),
 *                     except the final lane keeps range_end_in unrounded so
 *                     the union of all lanes covers [cursor_in, range_end_in).
 *   - lane_start    = lane_min (always primorial-aligned).
 *
 * Invariant the unit tests assert:
 *   for every non-final lane k: lane_max(k) == lane_min(k+1).
 *   every lane_start_u128 == 0 mod primorial.
 *
 * NB: this helper computes the !final lane_max from the UNROUNDED lane_min
 * (lane_id * lane_size).  That keeps the boundary between lanes (k, k+1)
 * deterministic: both lanes resolve to round_down(cursor_in + (k+1)*lane_size). */
void kt_compute_lane_bounds(unsigned __int128 cursor_in,
                            unsigned __int128 range_end_in,
                            int lanes, int lane_id,
                            unsigned __int128 primorial,
                            unsigned __int128 *out_lane_min,
                            unsigned __int128 *out_lane_max,
                            unsigned __int128 *out_lane_start) {
    unsigned __int128 span      = range_end_in - cursor_in;
    unsigned __int128 lane_size = span / (unsigned __int128)lanes;
    unsigned __int128 lm_raw    = cursor_in + (unsigned __int128)lane_id * lane_size;
    unsigned __int128 lx_raw    = lm_raw + lane_size;
    unsigned __int128 lane_min  = (lm_raw / primorial) * primorial;
    unsigned __int128 lane_max  = (lane_id + 1 == lanes)
        ? range_end_in
        : (lx_raw / primorial) * primorial;
    if (out_lane_min)   *out_lane_min   = lane_min;
    if (out_lane_max)   *out_lane_max   = lane_max;
    if (out_lane_start) *out_lane_start = lane_min;
}

/* W19-A-3 (P1-8): single-lane (no --prefix-lanes) lane_start rounding helper.
 * Same code path as the run_search_loop else-branch at ~line 3996. */
unsigned __int128 kt_compute_lane_start_no_lanes(unsigned __int128 cursor_in,
                                                 unsigned __int128 primorial) {
    return (cursor_in / primorial) * primorial;
}
