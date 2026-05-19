#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""W18-F: pick one record per bit-range bucket for misalignment-injection test.

Reads known/records.json and src/common/ktuplet_pattern.c
(for the offsets->pattern_name map), picks the lowest-base record in each bucket
{60-79, 80-99, 100-119} whose offsets are in the engine catalog, and
emits one JSONL row per bucket on stdout with the fields the regression-test
script needs: k, bits, pattern, primorial_n, prefix_bits, prefix_binary, base_str.

SHIFT = 44 is chosen so the engine's batch-0 chunk (~n_tiles_default x primorial
~= 3 * 37# ~= 2.2e13) covers the prefix range (2^44), making batch-0 the
deterministic FOUND window for the test (rotation post-batch-0 is non-deterministic
in pre-fix and irrelevant once batch-0 finds the record).
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECORDS = os.path.join(ROOT, 'known', 'records.json')
PATTERN_C = os.path.join(ROOT, 'src', 'common', 'ktuplet_pattern.c')

SHIFT = 44       # range 2^44 ~= 1.76e13 < batch-0 chunk (~3 x 37# ~= 2.2e13)
PRIM_N = 11      # 37# (engine default)
GPU_BATCH_SIZE = 4194304  # 2^22; forces n_tiles_default >= 3 across selected records

BUCKETS = (('b60-79', 61, 79), ('b80-99', 80, 99), ('b100-119', 100, 119))


def load_pattern_catalog():
    table = {}
    pat = re.compile(r'\{\s*(\d+)\s*,\s*(\d+)\s*,\s*\{([^}]+)\}\s*,\s*"([A-Za-z0-9_]+)"\s*\}')
    with open(PATTERN_C) as f:
        for line in f:
            m = pat.search(line)
            if not m:
                continue
            k = int(m.group(1))
            raw = [int(x) for x in m.group(3).split(',') if x.strip()]
            offs = tuple(raw[:k])
            table[offs] = m.group(4)
    return table


def bucket_of(bits):
    for name, lo, hi in BUCKETS:
        if lo <= bits <= hi:
            return name
    return None


def main():
    with open(RECORDS) as f:
        data = json.load(f)
    catalog = load_pattern_catalog()

    picks = {}
    for k_str, payload in data.items():
        for rec in payload.get('records', []):
            base = int(rec['base'])
            bits = base.bit_length()
            offs = tuple(rec['offsets'])
            pat = catalog.get(offs)
            if pat is None:
                continue
            bkt = bucket_of(bits)
            if bkt is None:
                continue
            cur = picks.get(bkt)
            if cur is None or base < cur['_base']:
                picks[bkt] = {'_base': base, 'k': int(k_str), 'bits': bits,
                              'pattern': pat, 'offsets': list(offs)}

    for name, _, _ in BUCKETS:
        rec = picks.get(name)
        if rec is None:
            print(f"ERROR: no catalog-backed record found for required bucket {name}", file=sys.stderr)
            return 1
        base = rec.pop('_base')
        bits = rec['bits']
        prefix_bits = max(1, bits - SHIFT)
        prefix_val = base >> (bits - prefix_bits)
        rec['bucket'] = name
        rec['primorial_n'] = PRIM_N
        rec['prefix_bits'] = prefix_bits
        rec['prefix_binary'] = '0b' + bin(prefix_val)[2:].zfill(prefix_bits)
        rec['base_str'] = str(base)
        rec['random_seed'] = '0xDEADBEEFCAFEBABE'
        rec['gpu_batch_size'] = GPU_BATCH_SIZE
        print(json.dumps(rec))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
