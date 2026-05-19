/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_checkpoint.h — checkpoint file format (Phase 9 T1.2 + W18-B drain-boundary
 * invariant + W18-C identity extension + W19-B-2 seed sentinel + W20 fsync
 * durability).  Extracted from kt_filter_v8.cu in W20-DEC Phase 1 Step 2.
 *
 * The module is intentionally pure-I/O: it serializes / deserializes a
 * checkpoint_t struct against a text file on disk (atomic via tmp + rename +
 * directory fsync), and does NOT inspect engine globals or validate identity
 * fields against the running engine.  Identity comparison stays in the caller
 * (run_search_loop in kt_filter_v8.cu) so the engine-state-aware decisions
 * (pattern/primorial/prefix/seed match, random-mode refuse, range check)
 * remain co-located with the rest of the resume sequencing.
 *
 * On-disk schema (single text file, line-oriented):
 *
 *   KT_FILTER_v8_CHECKPOINT_v1
 *   bits=N
 *   target_k=N
 *   pattern=NAME
 *   primorial_n=N
 *   wheel_expr=<X#[/Y...] or none>
 *   prefix=<0bXXX or none>
 *   prefix_mode=<sequential|random|inherit>
 *   prefix_lanes=N
 *   prefix_lane_id=N
 *   seed=0xHEX
 *   cursor_hi=hex16
 *   cursor_lo=hex16
 *   total_cand_hi=hex16
 *   total_cand_lo=hex16
 *   total_surv=N
 *   total_hits=N
 *   batches=N
 *   exhausted=0|1
 *
 * W18-B drain-boundary invariant: `cursor`, `total_cand`, `total_surv`,
 * `total_hits`, and `batches` are all captured at the SAME drain boundary
 * (after all batches whose survivors have been fully processed).  In-flight
 * batches do NOT contribute to the saved totals.  On resume the loop picks
 * up at the saved cursor and re-launches in-flight batches.  This is a
 * caller-side invariant; this module just reads/writes the bytes.
 *
 * Pre-W18-C ckpts omit primorial_n/prefix_mode/seed; the reader signals
 * absence via primorial_n=-1, prefix_mode[0]='\0', seed_present=0.
 */
#ifndef KT_CHECKPOINT_H
#define KT_CHECKPOINT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KT_CHECKPOINT_PATTERN_LEN 64
#define KT_CHECKPOINT_PREFIX_LEN  256
#define KT_CHECKPOINT_MODE_LEN    32
#define KT_CHECKPOINT_WHEEL_EXPR_LEN 128

typedef struct kt_checkpoint_s {
    int                bits;
    int                target_k;
    int                primorial_n;        /* -1 if absent (pre-W18-C ckpt) */
    char               pattern_name[KT_CHECKPOINT_PATTERN_LEN];
    char               wheel_expr[KT_CHECKPOINT_WHEEL_EXPR_LEN]; /* normalized X#/Y or "none"; empty if absent */
    char               prefix[KT_CHECKPOINT_PREFIX_LEN];        /* "0b..." or "none" */
    char               prefix_mode[KT_CHECKPOINT_MODE_LEN];     /* "sequential"/"random"/"inherit" — empty if absent */
    int                prefix_lanes;
    int                prefix_lane_id;
    uint64_t           seed;
    int                seed_present;       /* 0 if no seed= line (pre-W18-C); 1 otherwise */
    unsigned __int128  cursor;
    unsigned __int128  total_cand;
    unsigned long long total_surv;
    int                total_hits;
    int                batches;
    int                exhausted;
} kt_checkpoint_t;

/* Write ck atomically to `path`.  Returns 0 on success, -1 on any I/O
 * failure (errors are logged to stderr by the module).  On Linux the
 * containing directory is fsync'd after the rename so a crash between
 * rename and reboot won't lose the new file. */
int kt_checkpoint_write(const char *path, const kt_checkpoint_t *ck);

/* Read `path` into ck.  Returns:
 *   0  — parsed OK, ck is populated.  Caller MUST validate identity fields.
 *  -1  — hard error (open succeeded but format wrong, or wrong header).
 *   1  — file does not exist; not an error, just "start fresh".
 *
 * Stderr is used for any failure reason (open/parse).  ck is partially
 * filled on error and should not be trusted.  Pre-W18-C field defaults
 * are documented above (-1 / "" / 0). */
int kt_checkpoint_read(const char *path, kt_checkpoint_t *ck);

#ifdef __cplusplus
}
#endif

#endif /* KT_CHECKPOINT_H */
