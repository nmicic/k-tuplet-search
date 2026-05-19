/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_json_min.h — minimal records.json reader for novel-record cross-check.
 *
 * Schema (rigid):
 *   { "<k_int>": { "records": [ { "base": "<dec>", "offsets":[...], ... }, ... ],
 *                   "admissibility_sets": [...] }, ... }
 *
 * We only extract (k, base_decimal) pairs. Lookup is O(N_k) linear for the
 * given k; with ~230 records total in records.json this is one cache-line of
 * pointer comparisons and is not a hot path (called once per certified hit,
 * which the GPU emits at most ~1/min for k>=16).
 *
 * No dependency on cJSON or any external JSON library — kt_json_min.c is
 * a single-pass scanner targeted only at this exact schema.
 */

#ifndef KT_JSON_MIN_H
#define KT_JSON_MIN_H

#ifdef __cplusplus
extern "C" {
#endif

struct kt_known_records;

/* Load and parse records.json. Returns NULL on error (file missing, parse
 * failure, OOM). Caller frees with kt_known_records_free. */
struct kt_known_records *kt_known_records_load(const char *path);

/* O(N_k) lookup of (k, base_decimal). Exact string match on base. */
int kt_known_records_contains(const struct kt_known_records *kr,
                              int k, const char *base_decimal);

/* Count records loaded for the given k; 0 if k absent. */
int kt_known_records_count_for_k(const struct kt_known_records *kr, int k);

/* Total records loaded across all k. */
int kt_known_records_total(const struct kt_known_records *kr);

void kt_known_records_free(struct kt_known_records *kr);

#ifdef __cplusplus
}
#endif

#endif /* KT_JSON_MIN_H */
