/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * kt_json_min.c — minimal JSON parser for known/records.json.
 *
 * Single-pass scanner over the in-memory text. Tokenizer recognizes strings
 * (with \" \\ \/ \b \f \n \r \t \uHHHH escapes), numbers, true/false/null,
 * and structural punctuation. Skip-value runs the brace/bracket nesting
 * counter so we can ignore parts of the schema we don't need.
 *
 * SCHEMA WE ASSUME (and only this):
 *   {
 *     "<k_string>": {
 *       "records": [
 *         { "base": "<digits>", ... ignore other fields ...},
 *         ...
 *       ],
 *       ... ignore "admissibility_sets" etc ...
 *     },
 *     ...
 *   }
 *
 * Anything else is parsed permissively but ignored.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>

#include "kt_json_min.h"

#define KT_K_MIN 2
#define KT_K_MAX 32

typedef struct {
    char **bases;       /* base decimal strings, NUL-terminated */
    int    count;
    int    cap;
} per_k_records;

struct kt_known_records {
    per_k_records by_k[KT_K_MAX + 1];   /* indexed by k */
};

/* ------------------------------- tokenizer -------------------------------- */

typedef enum {
    JTOK_EOF, JTOK_LBRACE, JTOK_RBRACE, JTOK_LBRACKET, JTOK_RBRACKET,
    JTOK_COLON, JTOK_COMMA, JTOK_STRING, JTOK_NUMBER, JTOK_TRUE,
    JTOK_FALSE, JTOK_NULL, JTOK_ERROR
} jtok_kind;

typedef struct {
    const char *p;        /* cursor */
    const char *end;
    /* For STRING: dynamically allocated decoded value (NUL terminated). */
    char *str;
    size_t str_len;
} jtok_state;

static void jtok_init(jtok_state *st, const char *buf, size_t len) {
    st->p = buf; st->end = buf + len; st->str = NULL; st->str_len = 0;
}

static void jtok_release_str(jtok_state *st) {
    if (st->str) { free(st->str); st->str = NULL; st->str_len = 0; }
}

static void skip_ws(jtok_state *st) {
    while (st->p < st->end) {
        char c = *st->p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') st->p++;
        else break;
    }
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    return -1;
}

/* Decode a JSON string starting at *st->p == '"'. Allocates st->str. */
static jtok_kind jtok_string(jtok_state *st) {
    jtok_release_str(st);
    if (*st->p != '"') return JTOK_ERROR;
    st->p++;
    /* allocate: worst-case the decoded length is <= source length */
    size_t cap = 64;
    char *out = (char*)malloc(cap);
    if (!out) return JTOK_ERROR;
    size_t n = 0;
    while (st->p < st->end) {
        unsigned char c = (unsigned char)*st->p++;
        if (c == '"') {
            if (n + 1 > cap) { cap = n + 1; char *t = realloc(out, cap); if (!t) { free(out); return JTOK_ERROR; } out = t; }
            out[n] = '\0';
            st->str = out; st->str_len = n;
            return JTOK_STRING;
        }
        if (c == '\\' && st->p < st->end) {
            char e = *st->p++;
            char emit = 0;
            int   skip_emit = 0;
            switch (e) {
                case '"': emit = '"'; break;
                case '\\': emit = '\\'; break;
                case '/': emit = '/'; break;
                case 'b': emit = '\b'; break;
                case 'f': emit = '\f'; break;
                case 'n': emit = '\n'; break;
                case 'r': emit = '\r'; break;
                case 't': emit = '\t'; break;
                case 'u': {
                    if (st->p + 4 > st->end) { free(out); return JTOK_ERROR; }
                    int h0 = hexval(st->p[0]), h1 = hexval(st->p[1]);
                    int h2 = hexval(st->p[2]), h3 = hexval(st->p[3]);
                    if (h0<0||h1<0||h2<0||h3<0) { free(out); return JTOK_ERROR; }
                    st->p += 4;
                    unsigned int cp = (unsigned)((h0<<12)|(h1<<8)|(h2<<4)|h3);
                    /* UTF-8 encode (no surrogate pair handling — records.json
                     * only has ö etc. in author names, which we never
                     * inspect; we just preserve the bytes for completeness). */
                    if (cp < 0x80) {
                        if (n + 1 >= cap) { cap *= 2; char *t = realloc(out, cap); if (!t) { free(out); return JTOK_ERROR; } out = t; }
                        out[n++] = (char)cp;
                    } else if (cp < 0x800) {
                        if (n + 2 >= cap) { cap *= 2; char *t = realloc(out, cap); if (!t) { free(out); return JTOK_ERROR; } out = t; }
                        out[n++] = (char)(0xC0 | (cp >> 6));
                        out[n++] = (char)(0x80 | (cp & 0x3F));
                    } else {
                        if (n + 3 >= cap) { cap *= 2; char *t = realloc(out, cap); if (!t) { free(out); return JTOK_ERROR; } out = t; }
                        out[n++] = (char)(0xE0 | (cp >> 12));
                        out[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        out[n++] = (char)(0x80 | (cp & 0x3F));
                    }
                    skip_emit = 1;
                } break;
                default: free(out); return JTOK_ERROR;
            }
            if (!skip_emit) {
                if (n + 1 >= cap) { cap *= 2; char *t = realloc(out, cap); if (!t) { free(out); return JTOK_ERROR; } out = t; }
                out[n++] = emit;
            }
        } else {
            if (n + 1 >= cap) { cap *= 2; char *t = realloc(out, cap); if (!t) { free(out); return JTOK_ERROR; } out = t; }
            out[n++] = (char)c;
        }
    }
    free(out);
    return JTOK_ERROR;
}

static jtok_kind jtok_next(jtok_state *st) {
    skip_ws(st);
    if (st->p >= st->end) return JTOK_EOF;
    char c = *st->p;
    if (c == '{') { st->p++; return JTOK_LBRACE; }
    if (c == '}') { st->p++; return JTOK_RBRACE; }
    if (c == '[') { st->p++; return JTOK_LBRACKET; }
    if (c == ']') { st->p++; return JTOK_RBRACKET; }
    if (c == ':') { st->p++; return JTOK_COLON; }
    if (c == ',') { st->p++; return JTOK_COMMA; }
    if (c == '"') return jtok_string(st);
    if (c == '-' || (c >= '0' && c <= '9')) {
        /* skip a JSON number; we don't need its value for records.json */
        st->p++;
        while (st->p < st->end) {
            char d = *st->p;
            if ((d >= '0' && d <= '9') || d == '.' || d == 'e' || d == 'E' ||
                d == '+' || d == '-') st->p++;
            else break;
        }
        return JTOK_NUMBER;
    }
    if (st->p + 4 <= st->end && memcmp(st->p, "true", 4) == 0)  { st->p += 4; return JTOK_TRUE; }
    if (st->p + 5 <= st->end && memcmp(st->p, "false", 5) == 0) { st->p += 5; return JTOK_FALSE; }
    if (st->p + 4 <= st->end && memcmp(st->p, "null", 4) == 0)  { st->p += 4; return JTOK_NULL; }
    return JTOK_ERROR;
}

/* Skip a value of any kind starting from the next token. Returns 0 on
 * success, -1 on error. The first token must already have been consumed
 * by the caller; this helper takes the *first* token of the value. */
static int skip_value_starting_with(jtok_state *st, jtok_kind first) {
    int depth = 0;
    jtok_kind t = first;
    for (;;) {
        if (t == JTOK_LBRACE || t == JTOK_LBRACKET) depth++;
        else if (t == JTOK_RBRACE || t == JTOK_RBRACKET) {
            depth--;
            if (depth < 0) return -1;
        }
        if (depth == 0) {
            /* a non-container (string/number/bool/null) ends the value;
             * a container ends when its bracket closes (depth back to 0). */
            if (t == JTOK_STRING || t == JTOK_NUMBER ||
                t == JTOK_TRUE   || t == JTOK_FALSE || t == JTOK_NULL ||
                t == JTOK_RBRACE || t == JTOK_RBRACKET) {
                return 0;
            }
            return -1; /* COLON / COMMA / EOF / ERROR not legal here */
        }
        t = jtok_next(st);
        if (t == JTOK_EOF || t == JTOK_ERROR) return -1;
    }
}

/* ------------------------------- store ----------------------------------- */

static int per_k_push(per_k_records *r, const char *base) {
    if (r->count == r->cap) {
        int new_cap = r->cap ? r->cap * 2 : 16;
        char **nb = (char**)realloc(r->bases, (size_t)new_cap * sizeof(char*));
        if (!nb) return -1;
        r->bases = nb;
        r->cap = new_cap;
    }
    char *dup = strdup(base);
    if (!dup) return -1;
    r->bases[r->count++] = dup;
    return 0;
}

/* ------------------------------- parse ----------------------------------- */

/* Inside a "records" array: read a sequence of objects, extracting "base". */
static int parse_records_array(jtok_state *st, struct kt_known_records *kr, int k) {
    /* Already consumed '['. */
    for (;;) {
        jtok_kind t = jtok_next(st);
        if (t == JTOK_RBRACKET) return 0;
        if (t == JTOK_COMMA) continue;
        if (t != JTOK_LBRACE) {
            jtok_release_str(st);
            return -1;
        }
        /* Inside a record object: scan keys; when we see "base": "<dec>",
         * stash it. Skip everything else. */
        char *base_val = NULL;
        for (;;) {
            jtok_kind kt = jtok_next(st);
            if (kt == JTOK_RBRACE) break;
            if (kt == JTOK_COMMA) continue;
            if (kt != JTOK_STRING) { free(base_val); jtok_release_str(st); return -1; }
            char *key = st->str; st->str = NULL; st->str_len = 0;
            jtok_kind colon = jtok_next(st);
            if (colon != JTOK_COLON) { free(key); free(base_val); return -1; }
            int is_base = strcmp(key, "base") == 0;
            free(key);
            jtok_kind vfirst = jtok_next(st);
            if (is_base) {
                if (vfirst != JTOK_STRING) { free(base_val); jtok_release_str(st); return -1; }
                if (base_val) free(base_val);
                base_val = st->str;
                st->str = NULL; st->str_len = 0;
            } else {
                if (skip_value_starting_with(st, vfirst) != 0) { free(base_val); return -1; }
            }
        }
        if (base_val && k >= KT_K_MIN && k <= KT_K_MAX) {
            if (per_k_push(&kr->by_k[k], base_val) != 0) { free(base_val); return -1; }
        }
        free(base_val);
    }
}

/* Top-level: { "<k>": { "records": [...], ... }, ... }. */
static int parse_top(jtok_state *st, struct kt_known_records *kr) {
    jtok_kind t = jtok_next(st);
    if (t != JTOK_LBRACE) return -1;
    for (;;) {
        jtok_kind kt = jtok_next(st);
        if (kt == JTOK_RBRACE) return 0;
        if (kt == JTOK_COMMA) continue;
        if (kt != JTOK_STRING) return -1;
        int k = atoi(st->str);
        jtok_release_str(st);
        jtok_kind colon = jtok_next(st);
        if (colon != JTOK_COLON) return -1;
        jtok_kind ob = jtok_next(st);
        if (ob != JTOK_LBRACE) return -1;
        /* inside per-k object */
        for (;;) {
            jtok_kind tk = jtok_next(st);
            if (tk == JTOK_RBRACE) break;
            if (tk == JTOK_COMMA) continue;
            if (tk != JTOK_STRING) return -1;
            int is_records = strcmp(st->str, "records") == 0;
            jtok_release_str(st);
            jtok_kind cn = jtok_next(st);
            if (cn != JTOK_COLON) return -1;
            jtok_kind vfirst = jtok_next(st);
            if (is_records) {
                if (vfirst != JTOK_LBRACKET) return -1;
                if (parse_records_array(st, kr, k) != 0) return -1;
            } else {
                if (skip_value_starting_with(st, vfirst) != 0) return -1;
            }
        }
    }
}

/* ------------------------------- public API ------------------------------ */

struct kt_known_records *kt_known_records_load(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    struct stat sb;
    if (fstat(fileno(fp), &sb) != 0) { fclose(fp); return NULL; }
    size_t len = (size_t)sb.st_size;
    char *buf = (char*)malloc(len + 1);
    if (!buf) { fclose(fp); return NULL; }
    size_t got = fread(buf, 1, len, fp);
    fclose(fp);
    if (got != len) { free(buf); return NULL; }
    buf[len] = '\0';

    struct kt_known_records *kr = (struct kt_known_records*)calloc(1, sizeof(*kr));
    if (!kr) { free(buf); return NULL; }
    jtok_state st;
    jtok_init(&st, buf, len);
    int rc = parse_top(&st, kr);
    jtok_release_str(&st);
    free(buf);
    if (rc != 0) {
        kt_known_records_free(kr);
        return NULL;
    }
    return kr;
}

int kt_known_records_contains(const struct kt_known_records *kr,
                              int k, const char *base_decimal) {
    if (!kr || k < KT_K_MIN || k > KT_K_MAX || !base_decimal) return 0;
    const per_k_records *r = &kr->by_k[k];
    for (int i = 0; i < r->count; i++) {
        if (strcmp(r->bases[i], base_decimal) == 0) return 1;
    }
    return 0;
}

int kt_known_records_count_for_k(const struct kt_known_records *kr, int k) {
    if (!kr || k < KT_K_MIN || k > KT_K_MAX) return 0;
    return kr->by_k[k].count;
}

int kt_known_records_total(const struct kt_known_records *kr) {
    if (!kr) return 0;
    int total = 0;
    for (int k = KT_K_MIN; k <= KT_K_MAX; k++) total += kr->by_k[k].count;
    return total;
}

void kt_known_records_free(struct kt_known_records *kr) {
    if (!kr) return;
    for (int k = KT_K_MIN; k <= KT_K_MAX; k++) {
        per_k_records *r = &kr->by_k[k];
        for (int i = 0; i < r->count; i++) free(r->bases[i]);
        free(r->bases);
    }
    free(kr);
}
