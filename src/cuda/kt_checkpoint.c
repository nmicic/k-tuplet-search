/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_checkpoint.c — atomic text-format checkpoint serializer / parser.
 * Body moved verbatim (modulo accessor wrapping) from kt_filter_v8.cu in
 * W20-DEC Phase 1 Step 2.  See kt_checkpoint.h for the on-disk schema and
 * the contract; this TU is pure host I/O with no engine-state coupling.
 */
/* _GNU_SOURCE before any libc header so O_DIRECTORY is visible on glibc. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "kt_checkpoint.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

int kt_checkpoint_write(const char *path, const kt_checkpoint_t *ck) {
    if (!path || !*path || !ck) return -1;
    char tmp[512];
    int tmp_n = snprintf(tmp, sizeof tmp, "%s.tmp", path);
    if (tmp_n < 0 || tmp_n >= (int)sizeof tmp) {
        fprintf(stderr, "[CKPT] checkpoint path too long for tmp name: %s\n", path);
        return -1;
    }
    FILE *fp = fopen(tmp, "w");
    if (!fp) {
        fprintf(stderr, "[CKPT] open(%s.tmp) failed: %s\n", path, strerror(errno));
        return -1;
    }
    int ok = 1;
    ok &= (fprintf(fp, "KT_FILTER_v8_CHECKPOINT_v1\n") > 0);
    ok &= (fprintf(fp, "bits=%d\n", ck->bits) > 0);
    ok &= (fprintf(fp, "target_k=%d\n", ck->target_k) > 0);
    ok &= (fprintf(fp, "pattern=%s\n", ck->pattern_name[0] ? ck->pattern_name : "none") > 0);
    ok &= (fprintf(fp, "primorial_n=%d\n", ck->primorial_n) > 0);
    ok &= (fprintf(fp, "wheel_expr=%s\n", ck->wheel_expr[0] ? ck->wheel_expr : "none") > 0);
    ok &= (fprintf(fp, "prefix=%s\n", ck->prefix[0] ? ck->prefix : "none") > 0);
    ok &= (fprintf(fp, "prefix_mode=%s\n", ck->prefix_mode[0] ? ck->prefix_mode : "inherit") > 0);
    ok &= (fprintf(fp, "prefix_lanes=%d\n", ck->prefix_lanes) > 0);
    ok &= (fprintf(fp, "prefix_lane_id=%d\n", ck->prefix_lane_id) > 0);
    ok &= (fprintf(fp, "seed=0x%016llx\n", (unsigned long long)ck->seed) > 0);
    ok &= (fprintf(fp, "cursor_hi=%016llx\n", (unsigned long long)(ck->cursor >> 64)) > 0);
    ok &= (fprintf(fp, "cursor_lo=%016llx\n", (unsigned long long)ck->cursor) > 0);
    ok &= (fprintf(fp, "total_cand_hi=%016llx\n", (unsigned long long)(ck->total_cand >> 64)) > 0);
    ok &= (fprintf(fp, "total_cand_lo=%016llx\n", (unsigned long long)ck->total_cand) > 0);
    ok &= (fprintf(fp, "total_surv=%llu\n", (unsigned long long)ck->total_surv) > 0);
    ok &= (fprintf(fp, "total_hits=%d\n", ck->total_hits) > 0);
    ok &= (fprintf(fp, "batches=%d\n", ck->batches) > 0);
    ok &= (fprintf(fp, "exhausted=%d\n", ck->exhausted ? 1 : 0) > 0);
    if (!ok || ferror(fp) || fflush(fp) != 0) {
        fprintf(stderr, "[CKPT] write(%s.tmp) failed: %s\n", path, strerror(errno));
        fclose(fp);
        unlink(tmp);
        return -1;
    }
#ifdef __linux__
    if (fsync(fileno(fp)) != 0) {
        fprintf(stderr, "[CKPT] fsync(%s.tmp) failed: %s\n", path, strerror(errno));
        fclose(fp);
        unlink(tmp);
        return -1;
    }
#endif
    if (fclose(fp) != 0) {
        fprintf(stderr, "[CKPT] close(%s.tmp) failed: %s\n", path, strerror(errno));
        unlink(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        fprintf(stderr, "[CKPT] rename(%s.tmp -> %s) failed: %s\n",
                path, path, strerror(errno));
        unlink(tmp);
        return -1;
    }
#ifdef __linux__
    {
        char dir[512];
        const char *slash = strrchr(path, '/');
        if (slash) {
            size_t n = (size_t)(slash - path);
            if (n == 0) n = 1;  /* root */
            if (n >= sizeof dir) n = sizeof dir - 1;
            memcpy(dir, path, n);
            dir[n] = '\0';
        } else {
            strcpy(dir, ".");
        }
        int dfd = open(dir, O_RDONLY | O_DIRECTORY);
        if (dfd >= 0) {
            (void)fsync(dfd);
            close(dfd);
        }
    }
#endif
    return 0;
}

int kt_checkpoint_read(const char *path, kt_checkpoint_t *ck) {
    if (!path || !*path || !ck) return -1;
    /* Defaults: signal "absent" for the W18-C-era extensions. */
    memset(ck, 0, sizeof *ck);
    ck->primorial_n = -1;
    /* prefix_mode and pattern_name etc. left as empty string by memset. */

    FILE *fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "[RESUME] no checkpoint file '%s' — starting fresh\n", path);
        return 1;
    }
    char line[1024];
    if (!fgets(line, sizeof line, fp) ||
        strncmp(line, "KT_FILTER_v8_CHECKPOINT_v1", 26) != 0) {
        fprintf(stderr, "[RESUME] '%s' wrong version/header — starting fresh\n", path);
        fclose(fp);
        return 1;
    }
    int    ck_bits = -1, ck_target_k = -1, ck_primorial_n = -1;
    char   ck_pattern[KT_CHECKPOINT_PATTERN_LEN] = "";
    char   ck_wheel_expr[KT_CHECKPOINT_WHEEL_EXPR_LEN] = "";
    char   ck_prefix[KT_CHECKPOINT_PREFIX_LEN]   = "";
    char   ck_pmstr[KT_CHECKPOINT_MODE_LEN]      = "";
    int    ck_lanes = -1, ck_lane_id = -1;
    unsigned long long ck_seed = 0;
    int    ck_seed_present = 0;
    unsigned long long ck_chi = 0, ck_clo = 0;
    unsigned long long ck_tch = 0, ck_tcl = 0;
    unsigned long long ck_surv = 0;
    int    ck_hits = 0, ck_batches = 0, ck_exh = 0;
    while (fgets(line, sizeof line, fp)) {
        line[strcspn(line, "\n")] = '\0';
        if (sscanf(line, "bits=%d", &ck_bits) == 1) continue;
        if (sscanf(line, "target_k=%d", &ck_target_k) == 1) continue;
        if (sscanf(line, "primorial_n=%d", &ck_primorial_n) == 1) continue;
        if (sscanf(line, "pattern=%63s", ck_pattern) == 1) continue;
        if (sscanf(line, "wheel_expr=%127s", ck_wheel_expr) == 1) continue;
        if (sscanf(line, "prefix=%255s", ck_prefix) == 1) continue;
        if (sscanf(line, "prefix_mode=%31s", ck_pmstr) == 1) continue;
        if (sscanf(line, "prefix_lanes=%d", &ck_lanes) == 1) continue;
        if (sscanf(line, "prefix_lane_id=%d", &ck_lane_id) == 1) continue;
        if (sscanf(line, "seed=0x%llx", &ck_seed) == 1) { ck_seed_present = 1; continue; }
        if (sscanf(line, "cursor_hi=%llx", &ck_chi) == 1) continue;
        if (sscanf(line, "cursor_lo=%llx", &ck_clo) == 1) continue;
        if (sscanf(line, "total_cand_hi=%llx", &ck_tch) == 1) continue;
        if (sscanf(line, "total_cand_lo=%llx", &ck_tcl) == 1) continue;
        if (sscanf(line, "total_surv=%llu", &ck_surv) == 1) continue;
        if (sscanf(line, "total_hits=%d", &ck_hits) == 1) continue;
        if (sscanf(line, "batches=%d", &ck_batches) == 1) continue;
        if (sscanf(line, "exhausted=%d", &ck_exh) == 1) continue;
    }
    fclose(fp);

    ck->bits           = ck_bits;
    ck->target_k       = ck_target_k;
    ck->primorial_n    = ck_primorial_n;
    strncpy(ck->pattern_name, ck_pattern, sizeof ck->pattern_name - 1);
    ck->pattern_name[sizeof ck->pattern_name - 1] = '\0';
    strncpy(ck->wheel_expr, ck_wheel_expr, sizeof ck->wheel_expr - 1);
    ck->wheel_expr[sizeof ck->wheel_expr - 1] = '\0';
    strncpy(ck->prefix, ck_prefix, sizeof ck->prefix - 1);
    ck->prefix[sizeof ck->prefix - 1] = '\0';
    strncpy(ck->prefix_mode, ck_pmstr, sizeof ck->prefix_mode - 1);
    ck->prefix_mode[sizeof ck->prefix_mode - 1] = '\0';
    ck->prefix_lanes   = ck_lanes;
    ck->prefix_lane_id = ck_lane_id;
    ck->seed           = ck_seed;
    ck->seed_present   = ck_seed_present;
    ck->cursor         = ((unsigned __int128)ck_chi << 64) | ck_clo;
    ck->total_cand     = ((unsigned __int128)ck_tch << 64) | ck_tcl;
    ck->total_surv     = ck_surv;
    ck->total_hits     = ck_hits;
    ck->batches        = ck_batches;
    ck->exhausted      = ck_exh;
    return 0;
}
