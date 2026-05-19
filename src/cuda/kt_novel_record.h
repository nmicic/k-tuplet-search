/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_novel_record.h — write-side helpers for `novel_records*.jsonl` (the
 * shared aggregator of certified k>=16 hits that did NOT match a known
 * record).  Extracted from kt_filter_v8.cu in W20-DEC Phase 1 Step 3.
 *
 * The module is pure host C and does its own filesystem hygiene (flock
 * around the append, fflush+fsync inside the lock, single-line JSON object
 * per record, stderr crash-safe banner via write(2)).  It does NOT call
 * any CUDA API and does NOT consult engine globals; the caller threads
 * the device-specific bits (gpu_uuid string, build_sha, cuda_version)
 * through the kt_novel_record_ctx_t struct.
 *
 * Path resolution priority (novel_jsonl_path):
 *   1. $KT_NOVEL_JSONL env override (tests use this).
 *   2. "novel_records_gpu<N>.jsonl" if gpu_device_explicit != 0 (06934a7 — per-device
 *      sharding so multi-GPU runs don't fight on a shared file).
 *   3. "novel_records.jsonl" default.
 *
 * The hostname helper is a thin gethostname() wrapper with a static cache;
 * exposed because the caller embeds it into the JSON line.
 */
#ifndef KT_NOVEL_RECORD_H
#define KT_NOVEL_RECORD_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kt_novel_record_ctx_s {
    const char *build_sha;       /* baked KT_BUILD_SHA */
    const char *hostname;        /* kt_novel_record_hostname() result */
    const char *gpu_uuid;        /* PCI bus id or "unknown"; caller resolves */
    int         cuda_version;    /* CUDART_VERSION */
    const char *wheel_expr;      /* normalized X#/Y... or "none" */
    int         primorial_n;     /* legacy wheel ceiling index */
} kt_novel_record_ctx_t;

/* Cached gethostname() wrapper.  Returns "unknown" on syscall failure.
 * Pointer is to a static buffer; safe to keep across calls within one
 * process.  Not async-signal-safe (uses snprintf on first call only). */
const char *kt_novel_record_hostname(void);

/* Resolve the JSONL path for the current process.  See header comment for
 * priority order.  Pointer is to a static buffer (per-device path) or to
 * a string literal; safe to keep across calls. */
const char *kt_novel_record_jsonl_path(int gpu_device, int gpu_device_explicit);

/* Append one novel-record JSON line atomically.  Locks the file with
 * flock(LOCK_EX) for the duration of the write so concurrent engines do
 * not interleave bytes.  fflush + fsync inside the lock guarantee
 * durability before unlock.  Failures are logged to stderr (with the
 * record details so the operator can recover by hand) and the function
 * returns without inserting a half-line.  Also emits a crash-safe
 * stderr banner (via write(2)) so SIGPIPE/stdio corruption don't lose
 * the operator-visible NOVEL announcement.
 *
 * `jsonl_path` should come from kt_novel_record_jsonl_path() above.
 * Returns 0 on success, -1 on any failure. */
int kt_novel_record_append(const char *jsonl_path,
                           const kt_novel_record_ctx_t *ctx,
                           const char *pattern, int k, int bits,
                           const char *base_decimal);

#ifdef __cplusplus
}
#endif

#endif /* KT_NOVEL_RECORD_H */
