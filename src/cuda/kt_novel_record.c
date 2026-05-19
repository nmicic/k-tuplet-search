/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_novel_record.c — atomic flock'd JSONL append for the shared novel-record
 * aggregator file.  Body moved from kt_filter_v8.cu in W20-DEC Phase 1 Step 3.
 * No CUDA API calls; caller threads device-specific strings via
 * kt_novel_record_ctx_t.  Filesystem ordering: flock(LOCK_EX) → fprintf →
 * fflush → fsync → flock(LOCK_UN) → fclose.
 */
/* _POSIX_C_SOURCE / _GNU_SOURCE so gethostname() and fileno() are visible
 * under the -std=c11 host CFLAGS. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "kt_novel_record.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/file.h>          /* flock(2) */

const char *kt_novel_record_hostname(void) {
    static char buf[256];
    static int  done = 0;
    if (done) return buf;
    if (gethostname(buf, sizeof buf - 1) != 0) snprintf(buf, sizeof buf, "unknown");
    buf[sizeof buf - 1] = '\0';
    done = 1;
    return buf;
}

const char *kt_novel_record_jsonl_path(int gpu_device, int gpu_device_explicit) {
    const char *p = getenv("KT_NOVEL_JSONL");
    if (p) return p;
    if (gpu_device_explicit) {
        static char gpu_path[64];
        snprintf(gpu_path, sizeof gpu_path,
                 "novel_records_gpu%d.jsonl", gpu_device);
        return gpu_path;
    }
    return "novel_records.jsonl";
}

int kt_novel_record_append(const char *jsonl_path,
                           const kt_novel_record_ctx_t *ctx,
                           const char *pattern, int k, int bits,
                           const char *base_decimal) {
    if (!jsonl_path || !ctx || !pattern || !base_decimal) return -1;

    FILE *fp = fopen(jsonl_path, "a");
    if (!fp) {
        fprintf(stderr, "WARNING: could not open %s: %s\n",
                jsonl_path, strerror(errno));
        return -1;
    }
    char ts[64]; time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%SZ", gmtime(&t));
    /* W18-J (multi-angle N8): exclusive flock so concurrent engine
     * processes (multi-GPU, multi-prefix-lane on one host) can't interleave
     * partial JSON writes that break downstream parsers.  Buffered fprintf
     * + fflush inside the lock keeps the line atomic on disk.  Use the
     * BSD-style flock(2) — advisory but universally honored when every
     * writer follows the same convention here.  Failure to acquire is treated
     * as a failed durable append; found.txt/stdout still contain the
     * certified hit, but the shared JSONL stays parse-safe. */
    if (flock(fileno(fp), LOCK_EX) != 0) {
        fprintf(stderr,
                "WARNING: flock(%s, LOCK_EX) failed: %s; not appending "
                "shared novel-record JSONL. Candidate: k=%d pattern=%s "
                "bits=%d base=%s\n",
                jsonl_path, strerror(errno), k, pattern, bits, base_decimal);
        fclose(fp);
        return -1;
    }
    int ok = (fprintf(fp,
        "{\"timestamp_utc\":\"%s\",\"pattern_name\":\"%s\",\"k\":%d,\"bits\":%d,"
        "\"base_n\":\"%s\",\"wheel_expr\":\"%s\",\"primorial_n\":%d,"
        "\"commit_sha\":\"%s\",\"host\":\"%s\","
        "\"engine\":\"gpu\",\"gpu_uuid\":\"%s\",\"cuda_version\":%d}\n",
        ts, pattern, k, bits, base_decimal,
        ctx->wheel_expr ? ctx->wheel_expr : "none",
        ctx->primorial_n,
        ctx->build_sha ? ctx->build_sha : "unknown",
        ctx->hostname  ? ctx->hostname  : "unknown",
        ctx->gpu_uuid  ? ctx->gpu_uuid  : "unknown",
        ctx->cuda_version) > 0);
    if (!ok || ferror(fp) || fflush(fp) != 0) {
        int saved_errno = errno;
        if (saved_errno == 0) saved_errno = EIO;
        (void)flock(fileno(fp), LOCK_UN);
        fclose(fp);
        fprintf(stderr,
                "WARNING: could not durably append %s: %s. Candidate: "
                "k=%d pattern=%s bits=%d base=%s\n",
                jsonl_path, strerror(saved_errno), k, pattern, bits, base_decimal);
        return -1;
    }
#ifdef __linux__
    if (fsync(fileno(fp)) != 0) {
        int saved_errno = errno;
        (void)flock(fileno(fp), LOCK_UN);
        fclose(fp);
        fprintf(stderr,
                "WARNING: fsync(%s) failed: %s. Candidate: k=%d "
                "pattern=%s bits=%d base=%s\n",
                jsonl_path, strerror(saved_errno), k, pattern, bits, base_decimal);
        return -1;
    }
#endif
    (void)flock(fileno(fp), LOCK_UN);
    if (fclose(fp) != 0) {
        fprintf(stderr,
                "WARNING: fclose(%s) failed: %s. Candidate: k=%d "
                "pattern=%s bits=%d base=%s\n",
                jsonl_path, strerror(errno), k, pattern, bits, base_decimal);
        return -1;
    }

    /* Stderr crash-safe banner via write(2). */
    char banner[1024];
    int n = snprintf(banner, sizeof banner,
        "*** NOVEL K=%d RECORD CANDIDATE ***\n"
        "pattern=%s base=%s bits=%d\n"
        "Logged to %s. Cross-check against records.json before claiming.\n",
        k, pattern, base_decimal, bits, jsonl_path);
    if (n > 0) {
        ssize_t wr = write(STDERR_FILENO, banner, (size_t)n);
        (void)wr;
    }
    return 0;
}
