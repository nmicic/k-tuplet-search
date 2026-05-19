/* Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
 * SPDX-License-Identifier: Apache-2.0 */
/*
 * ktuplet_pattern.h — k-tuplet admissible-pattern definitions.
 *
 * Generated: 2026-05-10
 * Total patterns: 97 across k = 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28
 *
 *   k= 3  diameter=  6  patterns=2
 *   k= 4  diameter=  8  patterns=1
 *   k= 5  diameter= 12  patterns=2
 *   k= 6  diameter= 16  patterns=1
 *   k= 7  diameter= 20  patterns=2
 *   k= 8  diameter= 26  patterns=3
 *   k= 9  diameter= 30  patterns=4
 *   k=10  diameter= 32  patterns=2
 *   k=11  diameter= 36  patterns=2
 *   k=12  diameter= 42  patterns=2
 *   k=13  diameter= 48  patterns=6
 *   k=14  diameter= 50  patterns=2
 *   k=15  diameter= 56  patterns=4
 *   k=16  diameter= 60  patterns=2
 *   k=17  diameter= 66  patterns=4
 *   k=18  diameter= 70  patterns=2
 *   k=19  diameter= 76  patterns=4
 *   k=20  diameter= 80  patterns=2
 *   k=21  diameter= 84  patterns=2
 *   k=22  diameter= 90  patterns=4
 *   k=23  diameter= 94  patterns=2
 *   k=24  diameter=100  patterns=4
 *   k=25  diameter=110  patterns=18
 *   k=26  diameter=114  patterns=2
 *   k=27  diameter=120  patterns=8
 *   k=28  diameter=126  patterns=10
 *
 * Catalog source of truth: tools/patterns/catalog/k{NN}_d{DDD}.json
 * Catalog generator:       tools/patterns/pattern_enum (C/OpenMP)
 * Header generator:        tools/gen_pattern_header.py
 *
 * Authoritative reference for prime k-tuplet patterns and Hardy-Littlewood
 * constants:  https://pzktupel.de/ktpatt_hl.php   (Norman Luhn)
 *
 * The tools in this repo (pattern_enum, gen_pattern_header.py) are a
 * convenience: they emit the same admissible patterns in machine-readable
 * JSON for engine consumption. They are NOT peer-reviewed; if there is any
 * discrepancy between this generated catalog and pzktupel.de, the canonical
 * pzktupel.de listing is correct and our tools have a bug. Cross-check
 * before publishing or relying on any pattern.
 *
 * Do not edit by hand. Run: python3 tools/gen_pattern_header.py
 */

#ifndef KTUPLET_PATTERN_H
#define KTUPLET_PATTERN_H

#include <stdint.h>

#define KT_MAX_K 28

typedef struct {
    int k;                  /* tuple length */
    int diameter;           /* offsets[k-1] (offsets[0] is always 0) */
    int offsets[KT_MAX_K];  /* offsets[0..k-1], strictly increasing, offsets[0]=0 */
    const char* name;       /* e.g., "KT19_P0" */
} KTupletPattern;

/* Built-in patterns table — see provenance block at top of this file. */
extern const KTupletPattern KT_PATTERNS[];
extern const int KT_PATTERNS_COUNT;

/* Admissibility check: returns 1 if admissible at all primes <= q_max, 0 otherwise.
 * If not admissible, *bad_q is set to the witness prime (or untouched if NULL).
 * Caller must pass q_max >= pat->diameter for the result to be a complete
 * admissibility proof; for q > diameter the test is automatic because
 * |forbidden_set| <= k < q holds trivially. */
int kt_pattern_is_admissible(const KTupletPattern* pat, int q_max, int* bad_q);

/* Forbidden-residue computation for prime q against pattern.
 * Writes deduplicated forbidden residues to out[]. Returns count.
 * out[] must have capacity >= k. */
int kt_pattern_forbidden_residues(const KTupletPattern* pat, uint32_t q, uint32_t* out);

/* Lookup by name; returns NULL if not found. */
const KTupletPattern* kt_pattern_by_name(const char* name);

/* Lookup by (k, offset_array). Order-sensitive; offsets must be sorted. Returns NULL if no exact match. */
const KTupletPattern* kt_pattern_match(int k, const int* offsets);

#endif /* KTUPLET_PATTERN_H */
