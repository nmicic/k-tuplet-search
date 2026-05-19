/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_lanes.h — pure-math helpers for per-lane bound computation and
 * seed-anchor rotation.  Extracted from kt_filter_v8.cu in W20-DEC Phase 1
 * Step 1.  No GPU dependency; safe to include in host-only TUs.
 *
 * Three functions:
 *
 *   kt_seed_anchor_offset(seed, target_bits, primorial)
 *     Deterministic per-restart offset, primorial-aligned (W18-A).
 *
 *   kt_compute_lane_bounds(cursor, range_end, lanes, lane_id, primorial,
 *                          *out_min, *out_max, *out_start)
 *     Per-lane shard bounds in --prefix-lanes mode.  Earlier lanes round
 *     lane_max DOWN to primorial (W19-A-2); the final lane absorbs the
 *     unrounded remainder so the union covers the full [cursor, range_end).
 *
 *   kt_compute_lane_start_no_lanes(cursor, primorial)
 *     Single-lane (no --prefix-lanes) lane_start = round_down(cursor, primorial).
 *
 * All inputs/outputs are unsigned __int128; gcc and clang both support
 * the type natively.  No CUDA headers transitively pulled in.
 */
#ifndef KT_LANES_H
#define KT_LANES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

unsigned __int128 kt_seed_anchor_offset(uint64_t seed, int target_bits,
                                        unsigned __int128 primorial);

void kt_compute_lane_bounds(unsigned __int128 cursor_in,
                            unsigned __int128 range_end_in,
                            int lanes, int lane_id,
                            unsigned __int128 primorial,
                            unsigned __int128 *out_lane_min,
                            unsigned __int128 *out_lane_max,
                            unsigned __int128 *out_lane_start);

unsigned __int128 kt_compute_lane_start_no_lanes(unsigned __int128 cursor_in,
                                                 unsigned __int128 primorial);

#ifdef __cplusplus
}
#endif

#endif /* KT_LANES_H */
