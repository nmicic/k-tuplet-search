/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0
 *
 * kt_records.c — records.json + records_manifest.tsv loaders.  Bodies moved
 * verbatim from kt_filter_v8.cu in W20-DEC Phase 2 Step 4.  Pure file I/O;
 * no CUDA / engine-global coupling.
 */
#include "kt_records.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* The opaque kt_known_records handle and the loader/lookup it returns to
 * live in the shared json-min library (src/common/kt_json_min.{c,h}). */
#include "kt_json_min.h"

struct kt_known_records *
kt_records_load(const char **out_used_path, int verbose) {
    const char *env_path = getenv("KT_RECORDS_JSON");
    /* Build candidate list dynamically: env override (if set) goes first,
     * followed by cwd-relative fallbacks. A NULL env_path must NOT
     * short-circuit the loop, which is why we don't put it directly in a
     * sentinel-NULL-terminated array. */
    const char *fallbacks[] = {
        "known/records.json",
        "../known/records.json",
        "../../known/records.json",
        "./records.json",
        NULL
    };
    const char *first_path = env_path;
    int started_fallbacks = (first_path == NULL);
    int fb_i = 0;
    for (;;) {
        const char *cur_path = NULL;
        if (!started_fallbacks) {
            cur_path = first_path;
            started_fallbacks = 1;
        } else {
            cur_path = fallbacks[fb_i++];
        }
        if (!cur_path) break;
        FILE *probe = fopen(cur_path, "rb");
        if (!probe) {
            if (verbose) {
                fprintf(stderr,
                    "records.json: tried '%s' open() failed errno=%d (%s)\n",
                    cur_path, errno, strerror(errno));
            }
            continue;
        }
        fclose(probe);
        struct kt_known_records *kr = kt_known_records_load(cur_path);
        if (!kr) {
            if (verbose) {
                fprintf(stderr,
                    "records.json: '%s' opened but parse failed (NULL records)\n",
                    cur_path);
            }
            continue;
        }
        if (out_used_path) *out_used_path = cur_path;
        return kr;
    }
    return NULL;
}

int kt_records_manifest_load(kt_record_entry_t **out, int target_k_filter) {
    if (!out) return -1;
    *out = NULL;
    /* Sobs-C §2.3: honor $KT_RECORDS_MANIFEST first; otherwise probe a list
     * of cwd-relative candidates.  On miss, log every path we tried so the
     * operator can see exactly where the harness looked. */
    const char *env_path = getenv("KT_RECORDS_MANIFEST");
    static const char *fallback_candidates[] = {
        "tools/records_manifest.tsv",
        "../tools/records_manifest.tsv",
        "../../tools/records_manifest.tsv",
        NULL
    };
    FILE *fp = NULL;
    const char *used = NULL;
    if (env_path && *env_path) {
        fp = fopen(env_path, "r");
        if (fp) used = env_path;
    }
    if (!fp) {
        for (int i = 0; fallback_candidates[i]; i++) {
            fp = fopen(fallback_candidates[i], "r");
            if (fp) { used = fallback_candidates[i]; break; }
        }
    }
    if (!fp) {
        fprintf(stderr, "ERROR: tools/records_manifest.tsv not found.  Tried:\n");
        if (env_path && *env_path) {
            fprintf(stderr, "  $KT_RECORDS_MANIFEST=%s\n", env_path);
        } else {
            fprintf(stderr, "  (no $KT_RECORDS_MANIFEST set)\n");
        }
        for (int i = 0; fallback_candidates[i]; i++) {
            fprintf(stderr, "  %s\n", fallback_candidates[i]);
        }
        fprintf(stderr,
            "  (set KT_RECORDS_MANIFEST=/abs/path/records_manifest.tsv to override)\n");
        return -1;
    }
    (void)used;
    char line[2048];
    int cap = 64, count = 0;
    kt_record_entry_t *arr = (kt_record_entry_t *)malloc((size_t)cap * sizeof(kt_record_entry_t));
    if (!arr) { fclose(fp); return -1; }
    if (!fgets(line, sizeof line, fp)) { fclose(fp); free(arr); return 0; }
    while (fgets(line, sizeof line, fp)) {
        kt_record_entry_t r; memset(&r, 0, sizeof r);
        char date_buf[128], author_buf[256];
        int n_fields = sscanf(line, "%d\t%31[^\t]\t%255[^\t]\t%*d\t%127[^\t]\t%255[^\t]\t%d",
                              &r.k, r.pattern, r.base_dec, date_buf, author_buf, &r.bits);
        if (n_fields < 6) continue;
        if (r.k < 0 || r.k >= 64) continue;
        if (r.bits < 8 || r.bits > 4096) continue;
        if (target_k_filter > 0 && r.k != target_k_filter) continue;
        if (count >= cap) {
            cap *= 2;
            kt_record_entry_t *grown = (kt_record_entry_t *)realloc(arr, (size_t)cap * sizeof(kt_record_entry_t));
            if (!grown) { fclose(fp); free(arr); return -1; }
            arr = grown;
        }
        arr[count++] = r;
    }
    fclose(fp);
    *out = arr;
    return count;
}
