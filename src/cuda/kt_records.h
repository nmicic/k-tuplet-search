/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_records.h — records.json loader (env-aware, cwd-fallback list) and the
 * records_manifest.tsv loader.  Extracted from kt_filter_v8.cu in W20-DEC
 * Phase 2 Step 4.
 *
 * Both helpers are pure file I/O / parsing.  No CUDA dependency.  The
 * records.json loader returns a struct kt_known_records produced by the
 * shared kt_verify.h library, so callers continue to use
 * kt_known_records_contains / kt_known_records_count_for_k against the
 * returned handle.
 *
 * The validate-known driver itself (per-record loop with prefix derivation,
 * GPU sieve probe, throughput estimator, --validate-known-require-coverage
 * gate decision) stays in core because it is tightly coupled to GPU launch
 * state and would require exposing a wider engine API to extract cleanly.
 * Loader-only extraction is the conservative first step; further moves
 * deferred.
 */
#ifndef KT_RECORDS_H
#define KT_RECORDS_H

#ifdef __cplusplus
extern "C" {
#endif

struct kt_known_records;        /* opaque; defined in kt_verify.h */

/* Load records.json from KT_RECORDS_JSON env (if set) or fall back to
 * a small list of cwd-relative candidates.  Returns NULL only if every
 * candidate failed to open or to parse.
 *
 * out_used_path (optional): pointer-to-pointer that receives the path
 * the loader succeeded against; usable for log lines like "T16 records
 * (/path/to/records.json): total=N ...".
 *
 * verbose != 0: stderr-logs every open attempt that failed (errno
 * + reason), so silent NULL returns are not a black box. */
struct kt_known_records *
kt_records_load(const char **out_used_path, int verbose);

/* records_manifest.tsv loader.  Schema: one header line, then per row
 *   k <tab> pattern <tab> base_dec <tab> *ignored* <tab> date <tab> author <tab> bits
 *
 * Honors KT_RECORDS_MANIFEST first, then tries
 *   tools/records_manifest.tsv
 *   ../tools/records_manifest.tsv
 *   ../../tools/records_manifest.tsv
 *
 * On miss the loader stderr-logs every path it tried.  Returns count of
 * loaded rows in *out_n (0 if file empty post-header), -1 on hard
 * failure (no file found / OOM).  *out is malloc'd; caller free()s. */
typedef struct {
    int  k;
    char pattern[32];
    char base_dec[256];
    int  bits;
} kt_record_entry_t;

int kt_records_manifest_load(kt_record_entry_t **out, int target_k_filter);

#ifdef __cplusplus
}
#endif

#endif /* KT_RECORDS_H */
