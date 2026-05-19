/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * pattern_enum.c — fast C enumerator for admissible prime k-tuplet patterns.
 *
 * Equivalent to tools/enumerate_patterns.py but ~50-100× faster via:
 *   - Bit-vector forbidden-set state per prime (uint64_t when q <= 64,
 *     uint8_t[16] aka 128-bit mask for q in (64, 128), arrays for larger)
 *   - __builtin_popcountll for admissibility check
 *   - OpenMP parallelism at top-level (b_1, b_2) prefix split
 *   - Pure C with no dependencies beyond libc + libgomp
 *
 * Input: --k K --diameter D
 * Output: stdout JSON array of canonical patterns (or all-patterns with --no-canonical)
 *
 * Build: gcc -O3 -fopenmp -o pattern_enum pattern_enum.c
 *
 * Cross-validate: tools/test_pattern_tools.py + reference Python implementation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include <getopt.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define MAX_K 64
#define MAX_DIAMETER 512
#define MAX_PRIMES 100   /* primes up to ~500 sufficient */

/* ---------------- Prime utilities ---------------- */

static int g_primes[MAX_PRIMES];
static int g_n_primes;

static void compute_primes_up_to(int n) {
    g_n_primes = 0;
    if (n < 2) return;
    char *sieve = calloc(n + 1, 1);
    for (int i = 2; i <= n; ++i) sieve[i] = 1;
    for (int i = 2; (long)i * i <= n; ++i) {
        if (sieve[i]) {
            for (long j = (long)i * i; j <= n; j += i) sieve[j] = 0;
        }
    }
    for (int i = 2; i <= n; ++i) {
        if (sieve[i]) {
            if (g_n_primes >= MAX_PRIMES) {
                fprintf(stderr, "ERROR: more than MAX_PRIMES=%d primes\n", MAX_PRIMES);
                exit(1);
            }
            g_primes[g_n_primes++] = i;
        }
    }
    free(sieve);
}

/* ---------------- Forbidden-set state ----------------
 *
 * For each prime q in g_primes, track bit-vector of occupied residues.
 * For q <= 64: a single uint64_t.
 * For q in (64, 128]: two uint64_t (low + high).
 * For q > 128: not needed at our k/diameter ranges (q > diameter not checked).
 *
 * For simplicity we use uint64_t pair (lo, hi) for all primes; for q <= 64
 * the hi component is always 0.
 */

typedef struct {
    uint64_t lo;
    uint64_t hi;
} bv_t;

static inline bv_t bv_set(bv_t bv, int bit) {
    if (bit < 64) bv.lo |= ((uint64_t)1) << bit;
    else bv.hi |= ((uint64_t)1) << (bit - 64);
    return bv;
}

static inline int bv_test(bv_t bv, int bit) {
    if (bit < 64) return (bv.lo >> bit) & 1;
    return (bv.hi >> (bit - 64)) & 1;
}

static inline int bv_popcount(bv_t bv) {
    return __builtin_popcountll(bv.lo) + __builtin_popcountll(bv.hi);
}

/* ---------------- Pattern utilities ---------------- */

/* Compute reflection of pattern in-place. Caller provides output buffer. */
static void reflect_pattern(const int *p, int k, int diameter, int *out) {
    for (int i = 0; i < k; ++i) {
        out[i] = diameter - p[k - 1 - i];
    }
}

static int compare_pattern(const int *a, const int *b, int k) {
    for (int i = 0; i < k; ++i) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return 0;
}

/* Canonical: lex-min of pattern and its reflection. */
static bool is_canonical(const int *p, int k, int diameter) {
    int refl[MAX_K];
    reflect_pattern(p, k, diameter, refl);
    return compare_pattern(p, refl, k) <= 0;
}

/* ---------------- Output buffer ---------------- */

typedef struct {
    int *data;          /* flat array of patterns: pat 0 is data[0..k-1], pat 1 is data[k..2k-1], ... */
    size_t count;
    size_t capacity;
    int k;
} pattern_buffer_t;

static void pb_init(pattern_buffer_t *pb, int k) {
    pb->data = NULL;
    pb->count = 0;
    pb->capacity = 0;
    pb->k = k;
}

static void pb_append(pattern_buffer_t *pb, const int *pattern) {
    if (pb->count == pb->capacity) {
        size_t new_cap = pb->capacity ? pb->capacity * 2 : 64;
        pb->data = realloc(pb->data, new_cap * pb->k * sizeof(int));
        if (!pb->data) {
            fprintf(stderr, "ERROR: out of memory growing pattern buffer\n");
            exit(1);
        }
        pb->capacity = new_cap;
    }
    memcpy(&pb->data[pb->count * pb->k], pattern, pb->k * sizeof(int));
    pb->count++;
}

static void pb_free(pattern_buffer_t *pb) {
    free(pb->data);
    pb->data = NULL;
    pb->count = 0;
    pb->capacity = 0;
}

/* Output format selection. */
typedef enum {
    FMT_JSON = 0,    /* default */
    FMT_TSV,
    FMT_TXT,
    FMT_GP,
    FMT_HEADER,      /* C struct-init form for KT_PATTERNS[] */
} output_format_t;

/* KT_MAX_K from src/common/ktuplet_pattern.h — must match for --format header */
#define KT_MAX_K_STRUCT 32

/* Sort patterns lexicographically. */
static int g_sort_k = 0;
static int pattern_compare_qsort(const void *a, const void *b) {
    return compare_pattern((const int *)a, (const int *)b, g_sort_k);
}

static void pb_sort(pattern_buffer_t *pb) {
    g_sort_k = pb->k;
    qsort(pb->data, pb->count, pb->k * sizeof(int), pattern_compare_qsort);
}

/* Dedup adjacent duplicates after sort (in-place). */
static void pb_dedup_sorted(pattern_buffer_t *pb) {
    if (pb->count < 2) return;
    size_t out = 1;
    for (size_t i = 1; i < pb->count; ++i) {
        const int *prev = &pb->data[(out - 1) * pb->k];
        const int *cur = &pb->data[i * pb->k];
        if (compare_pattern(prev, cur, pb->k) != 0) {
            if (out != i) {
                memcpy(&pb->data[out * pb->k], cur, pb->k * sizeof(int));
            }
            out++;
        }
    }
    pb->count = out;
}

/* ---------------- DFS enumeration ---------------- */

typedef struct {
    int k;
    int diameter;
    bool canonical_only;
    pattern_buffer_t *out;
    int prefix[MAX_K];
    int prefix_len;
    /* forbidden_masks[i] = bitvector of occupied residues mod g_primes[i] */
    bv_t forbidden_masks[MAX_PRIMES];
    /* full_masks[i] = (1 << q_i) - 1 (precomputed) */
    bv_t full_masks[MAX_PRIMES];
} enum_state_t;

/* Initialize state with prefix [0]. */
static void init_state(enum_state_t *st, int k, int diameter, bool canon_only,
                        pattern_buffer_t *out) {
    st->k = k;
    st->diameter = diameter;
    st->canonical_only = canon_only;
    st->out = out;
    st->prefix[0] = 0;
    st->prefix_len = 1;
    /* Initial: only offset 0; forbidden_masks have bit 0 set per prime */
    for (int i = 0; i < g_n_primes; ++i) {
        st->forbidden_masks[i].lo = 1;  /* bit 0 set; 0 % q = 0 for any q */
        st->forbidden_masks[i].hi = 0;
        int q = g_primes[i];
        if (q <= 64) {
            st->full_masks[i].lo = (q == 64) ? UINT64_MAX : ((((uint64_t)1) << q) - 1);
            st->full_masks[i].hi = 0;
        } else if (q <= 128) {
            st->full_masks[i].lo = UINT64_MAX;
            st->full_masks[i].hi = (((uint64_t)1) << (q - 64)) - 1;
        } else {
            /* q > 128: not handled; should not occur for k <= 40 narrow */
            st->full_masks[i].lo = UINT64_MAX;
            st->full_masks[i].hi = UINT64_MAX;
        }
    }
}

/* Try to add next_off to the prefix. Returns true if admissible (caller must
 * pop on backtrack via undo_step). */
static inline bool try_step(enum_state_t *st, int next_off) {
    /* Save state for undo */
    /* Apply: for each prime, OR in bit (next_off mod q); if mask == full, fail */
    bv_t saved[MAX_PRIMES];
    for (int i = 0; i < g_n_primes; ++i) saved[i] = st->forbidden_masks[i];

    bool ok = true;
    for (int i = 0; i < g_n_primes; ++i) {
        int q = g_primes[i];
        int r = next_off % q;
        bv_t bv = st->forbidden_masks[i];
        if (!bv_test(bv, r)) {
            bv = bv_set(bv, r);
            /* Check if filled */
            if (bv.lo == st->full_masks[i].lo && bv.hi == st->full_masks[i].hi) {
                ok = false;
                break;
            }
        }
        st->forbidden_masks[i] = bv;
    }
    if (!ok) {
        /* Restore */
        for (int i = 0; i < g_n_primes; ++i) st->forbidden_masks[i] = saved[i];
        return false;
    }
    st->prefix[st->prefix_len++] = next_off;
    return true;
}

static void undo_step(enum_state_t *st, const bv_t *saved) {
    st->prefix_len--;
    for (int i = 0; i < g_n_primes; ++i) st->forbidden_masks[i] = saved[i];
}

/* Recursive DFS. Pure DFS, no parallelism here. */
static void dfs(enum_state_t *st) {
    int n_more = st->k - st->prefix_len;
    int max_off = st->prefix[st->prefix_len - 1];

    if (n_more == 0) {
        if (max_off == st->diameter) {
            if (!st->canonical_only ||
                is_canonical(st->prefix, st->k, st->diameter)) {
                pb_append(st->out, st->prefix);
            }
        }
        return;
    }

    int lo = max_off + 1;
    int hi = st->diameter - (n_more - 1);
    if (n_more == 1) lo = hi = st->diameter;

    bv_t saved[MAX_PRIMES];
    for (int next_off = lo; next_off <= hi; ++next_off) {
        for (int i = 0; i < g_n_primes; ++i) saved[i] = st->forbidden_masks[i];
        if (try_step(st, next_off)) {
            dfs(st);
            undo_step(st, saved);
        }
    }
}

/* ---------------- Top-level fan-out for parallelism ---------------- */

typedef struct {
    int b1;
    int b2;
} prefix_seed_t;

static prefix_seed_t *gen_prefix_seeds(int k, int diameter, int *out_count) {
    /* Generate (b_1, b_2) prefixes that are admissible at primes 2 and 3
     * (cheap pre-check). Each becomes an independent task. */
    prefix_seed_t *seeds = malloc(sizeof(prefix_seed_t) * diameter * diameter);
    int count = 0;

    int hi_b1 = diameter - (k - 2);
    for (int b1 = 1; b1 <= hi_b1; ++b1) {
        /* b_1 mod 2 must not equal -0 mod 2 = 0... actually b_1 mod 2 is fine
         * as long as residues don't fill mod 2. Since 0 is in pattern, mod 2
         * we have {0, b_1 mod 2}. Filling mod 2 would require {0,1} both
         * present, i.e. b_1 odd. So if b_1 odd, fails admissibility at q=2. */
        if (b1 % 2 != 0) continue;  /* admissibility at q=2 requires all even */

        int hi_b2 = diameter - (k - 3);
        for (int b2 = b1 + 1; b2 <= hi_b2; ++b2) {
            if (b2 % 2 != 0) continue;
            /* mod 3 admissibility: residues so far are {0 % 3, b1 % 3, b2 % 3}.
             * If these fill {0, 1, 2}, fails. */
            int r0 = 0, r1 = b1 % 3, r2 = b2 % 3;
            if (r0 != r1 && r0 != r2 && r1 != r2) continue; /* fills mod 3 */
            seeds[count].b1 = b1;
            seeds[count].b2 = b2;
            count++;
        }
    }
    *out_count = count;
    return seeds;
}

/* Run DFS from a specific (b1, b2) seed. No need to undo at this level —
 * each seed gets its own state. */
static void dfs_from_seed(int k, int diameter, bool canon_only,
                          int b1, int b2, pattern_buffer_t *local_out) {
    enum_state_t st;
    init_state(&st, k, diameter, canon_only, local_out);
    if (!try_step(&st, b1)) return;
    if (!try_step(&st, b2)) return;
    dfs(&st);
}

/* ---------------- Main ---------------- */

static void print_usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s --k K --diameter D [options]\n"
        "       %s --self-test\n"
        "\n"
        "Options:\n"
        "  --k K                  k-tuplet size\n"
        "  --diameter D           diameter (last offset)\n"
        "  --no-canonical         emit non-canonical patterns too (keeps reflections)\n"
        "  --threads N            OpenMP worker threads (default: all cores)\n"
        "  --quiet                suppress progress to stderr\n"
        "  --format FMT           output format: json (default), tsv, txt, gp, header\n"
        "  --with-reflections     for --format header: also emit reflection pattern rows\n"
        "  --self-test            run built-in tests (k=5..25)\n"
        "\n"
        "Output formats:\n"
        "  json   structured with metadata (default)\n"
        "  tsv    tab-separated for spreadsheet import\n"
        "  txt    one-pattern-per-line, plain text\n"
        "  gp     GP/PARI vector input\n"
        "  header C struct-init rows for src/common/ktuplet_pattern.c KT_PATTERNS[]\n"
        "\n"
        "Equivalent reference impl: tools/enumerate_patterns.py.\n"
        "Build: make -C tools  (or gcc -O3 -fopenmp -o pattern_enum pattern_enum.c)\n",
        prog, prog);
}

static int self_test(void);

int main(int argc, char **argv) {
    int k = -1, diameter = -1;
    bool canonical_only = true;
    int threads = -1;
    bool quiet = false;
    bool do_self_test = false;
    output_format_t format = FMT_JSON;
    bool emit_reflections = false;  /* with --format header, also emit R(P) entries */

    static struct option long_opts[] = {
        {"k", required_argument, 0, 'k'},
        {"diameter", required_argument, 0, 'd'},
        {"no-canonical", no_argument, 0, 'c'},
        {"threads", required_argument, 0, 't'},
        {"quiet", no_argument, 0, 'q'},
        {"self-test", no_argument, 0, 's'},
        {"format", required_argument, 0, 'f'},
        {"with-reflections", no_argument, 0, 'r'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "k:d:ct:qsf:rh", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'k': k = atoi(optarg); break;
            case 'd': diameter = atoi(optarg); break;
            case 'c': canonical_only = false; break;
            case 't': threads = atoi(optarg); break;
            case 'q': quiet = true; break;
            case 's': do_self_test = true; break;
            case 'f':
                if (!strcmp(optarg, "json")) format = FMT_JSON;
                else if (!strcmp(optarg, "tsv")) format = FMT_TSV;
                else if (!strcmp(optarg, "txt")) format = FMT_TXT;
                else if (!strcmp(optarg, "gp")) format = FMT_GP;
                else if (!strcmp(optarg, "header")) format = FMT_HEADER;
                else { fprintf(stderr, "ERROR: unknown format '%s'\n", optarg); return 1; }
                break;
            case 'r': emit_reflections = true; break;
            case 'h': default: print_usage(argv[0]); return 1;
        }
    }

    if (do_self_test) return self_test();

    if (k < 2 || k > MAX_K || diameter < k - 1 || diameter > MAX_DIAMETER) {
        fprintf(stderr, "ERROR: bad --k / --diameter (k=%d, d=%d)\n", k, diameter);
        return 1;
    }

#ifdef _OPENMP
    if (threads > 0) omp_set_num_threads(threads);
    int actual_threads = omp_get_max_threads();
#else
    int actual_threads = 1;
#endif

    /* Compute primes up to max(diameter, k) */
    int prime_bound = (diameter > k) ? diameter : k;
    compute_primes_up_to(prime_bound);

    if (!quiet) {
        fprintf(stderr, "[pattern_enum] k=%d diameter=%d primes=%d threads=%d canonical_only=%d\n",
                k, diameter, g_n_primes, actual_threads, canonical_only);
    }

    int n_seeds;
    prefix_seed_t *seeds = gen_prefix_seeds(k, diameter, &n_seeds);
    if (!quiet) {
        fprintf(stderr, "[pattern_enum] %d top-level (b1,b2) seeds\n", n_seeds);
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* Per-thread output buffers */
#ifdef _OPENMP
    int max_threads = omp_get_max_threads();
#else
    int max_threads = 1;
#endif
    pattern_buffer_t *thread_bufs = malloc(sizeof(pattern_buffer_t) * max_threads);
    for (int i = 0; i < max_threads; ++i) pb_init(&thread_bufs[i], k);

    int n_done = 0;
#ifdef _OPENMP
    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        #pragma omp for schedule(dynamic, 1)
        for (int s = 0; s < n_seeds; ++s) {
            dfs_from_seed(k, diameter, canonical_only,
                          seeds[s].b1, seeds[s].b2, &thread_bufs[tid]);
            #pragma omp atomic
            n_done++;
            if (!quiet && (n_done & 0xFF) == 0) {
                #pragma omp critical
                fprintf(stderr, "[pattern_enum] %d/%d seeds done\n", n_done, n_seeds);
            }
        }
    }
#else
    for (int s = 0; s < n_seeds; ++s) {
        dfs_from_seed(k, diameter, canonical_only,
                      seeds[s].b1, seeds[s].b2, &thread_bufs[0]);
    }
#endif

    /* Merge thread buffers into single output */
    pattern_buffer_t out;
    pb_init(&out, k);
    for (int i = 0; i < max_threads; ++i) {
        for (size_t j = 0; j < thread_bufs[i].count; ++j) {
            pb_append(&out, &thread_bufs[i].data[j * k]);
        }
        pb_free(&thread_bufs[i]);
    }
    free(thread_bufs);
    pb_sort(&out);
    pb_dedup_sorted(&out);

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;

    /* Emit in requested format */
    if (format == FMT_JSON) {
        printf("{\n");
        printf("  \"k\": %d,\n", k);
        printf("  \"diameter\": %d,\n", diameter);
        printf("  \"canonical_only\": %s,\n", canonical_only ? "true" : "false");
        printf("  \"total_count\": %zu,\n", out.count);
        printf("  \"elapsed_s\": %.3f,\n", elapsed);
        printf("  \"threads\": %d,\n", actual_threads);
        printf("  \"tool\": \"pattern_enum.c v1.1\",\n");
        printf("  \"patterns\": [\n");
        for (size_t i = 0; i < out.count; ++i) {
            printf("    {\"offsets\": [");
            for (int j = 0; j < k; ++j) {
                printf("%d%s", out.data[i * k + j], j + 1 < k ? ", " : "");
            }
            printf("], \"name_suggestion\": \"KT%d_P%zu\"}%s\n", k, i,
                   i + 1 < out.count ? "," : "");
        }
        printf("  ]\n");
        printf("}\n");
    } else if (format == FMT_TSV) {
        printf("#k\tdiameter\tpattern_index\toffsets\n");
        for (size_t i = 0; i < out.count; ++i) {
            printf("%d\t%d\t%zu\t", k, diameter, i);
            for (int j = 0; j < k; ++j) {
                printf("%d%s", out.data[i * k + j], j + 1 < k ? "," : "");
            }
            printf("\n");
        }
    } else if (format == FMT_TXT) {
        printf("# k=%d diameter=%d count=%zu elapsed=%.3fs\n", k, diameter, out.count, elapsed);
        printf("# Generated by tools/pattern_enum (canonical_only=%d)\n", canonical_only);
        for (size_t i = 0; i < out.count; ++i) {
            printf("KT%d_P%zu:", k, i);
            for (int j = 0; j < k; ++j) {
                printf("%s%d", j == 0 ? " " : ", ", out.data[i * k + j]);
            }
            printf("\n");
        }
    } else if (format == FMT_GP) {
        printf("\\\\ k=%d diameter=%d count=%zu elapsed=%.3fs\n", k, diameter, out.count, elapsed);
        printf("\\\\ Generated by tools/pattern_enum (canonical_only=%d)\n", canonical_only);
        printf("narrow_patterns_k%d = [\n", k);
        for (size_t i = 0; i < out.count; ++i) {
            printf("  [");
            for (int j = 0; j < k; ++j) {
                printf("%d%s", out.data[i * k + j], j + 1 < k ? ", " : "");
            }
            printf("]%s\n", i + 1 < out.count ? "," : "");
        }
        printf("];\n");
    } else if (format == FMT_HEADER) {
        /* Emit C struct-init form for src/common/ktuplet_pattern.c KT_PATTERNS[].
         * Format matches existing rows exactly:
         *   /\* KT_NAME *\/ { K, DIAM, {b0, b1, ..., b_{k-1}, 0, 0, ..., 0}, "KT_NAME" },
         * Pads offsets to KT_MAX_K_STRUCT entries with trailing zeros.
         * If --with-reflections, emits both canonical and reflection entries.
         * Operator pastes these rows into ktuplet_pattern.c (alphabetically by
         * (k, offsets) per the existing convention).
         */
        printf("/* Auto-generated by tools/pattern_enum (k=%d, d=%d, count=%zu).\n",
               k, diameter, out.count);
        printf(" * Operator: paste these rows into src/common/ktuplet_pattern.c\n");
        printf(" * inside the KT_PATTERNS[] = { ... } array, in (k, offsets)-sorted\n");
        printf(" * position. Update KT_PATTERNS_COUNT below the array if needed.\n");
        printf(" */\n");
        size_t name_idx = 0;
        for (size_t i = 0; i < out.count; ++i) {
            const int *p = &out.data[i * k];
            /* Emit canonical entry */
            printf("    /* KT%d_P%zu */ { %d, %d, {", k, name_idx, k, diameter);
            for (int j = 0; j < KT_MAX_K_STRUCT; ++j) {
                int val = (j < k) ? p[j] : 0;
                printf("%d%s", val, j + 1 < KT_MAX_K_STRUCT ? ", " : "");
            }
            printf("}, \"KT%d_P%zu\" },\n", k, name_idx);
            name_idx++;
            /* Emit reflection entry if requested and pattern is asymmetric */
            if (emit_reflections) {
                int refl[MAX_K];
                reflect_pattern(p, k, diameter, refl);
                if (compare_pattern(p, refl, k) != 0) {
                    /* Asymmetric: emit reflection */
                    printf("    /* KT%d_P%zu */ { %d, %d, {", k, name_idx, k, diameter);
                    for (int j = 0; j < KT_MAX_K_STRUCT; ++j) {
                        int val = (j < k) ? refl[j] : 0;
                        printf("%d%s", val, j + 1 < KT_MAX_K_STRUCT ? ", " : "");
                    }
                    printf("}, \"KT%d_P%zu\" },\n", k, name_idx);
                    name_idx++;
                }
            }
        }
    }

    if (!quiet) {
        fprintf(stderr, "[pattern_enum] %zu patterns in %.3fs (%d threads)\n",
                out.count, elapsed, actual_threads);
    }

    pb_free(&out);
    free(seeds);
    return 0;
}

/* ---------------- Self tests ---------------- */

typedef struct { int k; int d; size_t expected_count; const char *name; } self_test_case;

static int self_test(void) {
    /* Compare against known counts from Python tool. */
    self_test_case cases[] = {
        {5, 12, 1, "k=5 d=12"},
        {7, 20, 1, "k=7 d=20"},
        {8, 26, 2, "k=8 d=26"},
        {9, 30, 2, "k=9 d=30"},
        {16, 60, 1, "k=16 d=60"},
        {17, 66, 2, "k=17 d=66"},
        {18, 70, 1, "k=18 d=70"},
        {19, 76, 2, "k=19 d=76"},
        {20, 80, 1, "k=20 d=80"},
        {21, 84, 1, "k=21 d=84"},
        {22, 90, 2, "k=22 d=90"},
        {23, 94, 1, "k=23 d=94"},
        {24, 100, 2, "k=24 d=100"},
        {25, 110, 9, "k=25 d=110"},
    };
    int n_cases = sizeof(cases) / sizeof(cases[0]);
    int n_pass = 0;
    for (int i = 0; i < n_cases; ++i) {
        compute_primes_up_to(cases[i].d > cases[i].k ? cases[i].d : cases[i].k);
        int n_seeds;
        prefix_seed_t *seeds = gen_prefix_seeds(cases[i].k, cases[i].d, &n_seeds);
        pattern_buffer_t out;
        pb_init(&out, cases[i].k);
#ifdef _OPENMP
        int max_t = omp_get_max_threads();
#else
        int max_t = 1;
#endif
        pattern_buffer_t *bufs = malloc(sizeof(pattern_buffer_t) * max_t);
        for (int t = 0; t < max_t; ++t) pb_init(&bufs[t], cases[i].k);

        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
#ifdef _OPENMP
        #pragma omp parallel for schedule(dynamic, 1)
        for (int s = 0; s < n_seeds; ++s) {
            int tid = omp_get_thread_num();
            dfs_from_seed(cases[i].k, cases[i].d, true,
                          seeds[s].b1, seeds[s].b2, &bufs[tid]);
        }
#else
        for (int s = 0; s < n_seeds; ++s) {
            dfs_from_seed(cases[i].k, cases[i].d, true,
                          seeds[s].b1, seeds[s].b2, &bufs[0]);
        }
#endif
        for (int t = 0; t < max_t; ++t) {
            for (size_t j = 0; j < bufs[t].count; ++j) {
                pb_append(&out, &bufs[t].data[j * cases[i].k]);
            }
            pb_free(&bufs[t]);
        }
        free(bufs);
        pb_sort(&out);
        pb_dedup_sorted(&out);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;

        bool pass = (out.count == cases[i].expected_count);
        n_pass += pass ? 1 : 0;
        printf("  [%s] %s -> %zu patterns (expected %zu) in %.3fs\n",
               pass ? "PASS" : "FAIL", cases[i].name, out.count,
               cases[i].expected_count, elapsed);
        pb_free(&out);
        free(seeds);
    }
    printf("\n  %d/%d PASS\n", n_pass, n_cases);
    return n_pass == n_cases ? 0 : 1;
}
