#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
kpi_calibrate.py — calibrate prefix_bits for each record in kpi_suite_v1.tsv

For each record, runs kt_filter_v8 --validate-known with a single-record manifest
to obtain the binary's probe-measured throughput and auto-selected prefix_bits
(calibrated for 60s). Adjusts to target TTR_TARGET_S (45s by default).

Outputs: tools/kpi_suite_v1.calibration.json
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time

BINARY_NAME   = "kt_filter_v8"
SUITE_TSV     = "tools/kpi_suite_v1.tsv"
OUTPUT_JSON   = "tools/kpi_suite_v1.calibration.json"
TTR_TARGET_S  = 45.0   # target sweep time (seconds)

def find_binary():
    for p in [f"src/cuda/{BINARY_NAME}", f"./{BINARY_NAME}"]:
        if os.path.isfile(p):
            return os.path.abspath(p)
    sys.exit(f"ERROR: {BINARY_NAME} not found in src/cuda/ or ./")

def load_suite(path):
    rows = []
    with open(path) as f:
        header = f.readline().strip().split('\t')
        for line in f:
            if not line.strip():
                continue
            fields = line.rstrip('\n').split('\t')
            row = dict(zip(header, fields))
            row['k']    = int(row['k'])
            row['bits'] = int(row['bits'])
            rows.append(row)
    return rows

def write_temp_manifest(record):
    """Write a single-record records_manifest.tsv to a temp directory."""
    tmpdir = tempfile.mkdtemp(prefix="kpi_cal_")
    mpath = os.path.join(tmpdir, "records_manifest.tsv")
    with open(mpath, 'w') as f:
        f.write("k\tpattern\tbase_dec\tdigits\tdate\tauthor\tbits\n")
        f.write(f"{record['k']}\t{record['pattern']}\t{record['base_dec']}"
                f"\t{record['digits']}\t{record['date']}\t{record['author']}"
                f"\t{record['bits']}\n")
    return tmpdir, mpath

def compute_prefix_str(base_dec, bits, prefix_bits):
    """Compute binary prefix string for base >> (bits - prefix_bits)."""
    n = int(base_dec)
    shift = bits - prefix_bits
    prefix_val = n >> shift
    # Format as binary string
    return "0b" + bin(prefix_val)[2:]

def calibrate_record(binary, record, jsonl_path, timeout=180):
    """
    Run --validate-known on a single record, return (prefix_bits, elapsed_s, tput_raw).
    Reads the per-record row from bench JSONL.
    """
    tmpdir, mpath = write_temp_manifest(record)
    env = os.environ.copy()
    env["KT_RECORDS_MANIFEST"] = mpath

    cmd = [
        binary,
        "--validate-known", str(record['k']),
        "--bench-jsonl", jsonl_path,
        "--full-quiet",
    ]

    try:
        t0 = time.monotonic()
        proc = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=timeout, cwd=os.path.dirname(mpath),
            env=env,
        )
        elapsed = time.monotonic() - t0
    except subprocess.TimeoutExpired:
        print(f"  TIMEOUT after {timeout}s", file=sys.stderr)
        return None
    finally:
        # clean up tmpdir
        try:
            os.unlink(mpath)
            os.rmdir(tmpdir)
        except OSError:
            pass

    if proc.returncode not in (0, 1):
        print(f"  binary exit {proc.returncode}", file=sys.stderr)
        print(proc.stderr[-1000:], file=sys.stderr)
        return None

    return elapsed

def parse_jsonl_row(jsonl_path, base_dec):
    """Find the JSONL row matching base_dec, return dict."""
    if not os.path.isfile(jsonl_path):
        return None
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                if row.get("base") == base_dec:
                    return row
            except json.JSONDecodeError:
                continue
    return None

def probe_via_validate_known(binary, record, run_dir):
    """
    Run --validate-known from run_dir (which has the records_manifest.tsv).
    Return JSONL row dict or None.
    """
    jsonl_path = os.path.join(run_dir, f"cal_probe_{record['suite_id']}.jsonl")
    cmd = [
        binary,
        "--validate-known", str(record['k']),
        "--bench-jsonl", jsonl_path,
        "--full-quiet",
    ]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=180, cwd=run_dir,
        )
    except subprocess.TimeoutExpired:
        return None

    row = parse_jsonl_row(jsonl_path, record['base_dec'])
    return row

MAX_PER_K = 5  # binary's --validate-known hard cap per k value

def run_probe_pass(binary, batch_records, pass_label, timeout_per_rec=120):
    """
    Run --validate-known over batch_records (all same k, or mixed k with ≤5 per k).
    Returns dict base_dec -> JSONL row.
    """
    import shutil
    tmpdir    = tempfile.mkdtemp(prefix=f"kpi_cal_{pass_label}_")
    tools_dir = os.path.join(tmpdir, "tools")
    os.makedirs(tools_dir, exist_ok=True)
    bench_dir = os.path.join(tmpdir, "bench")
    os.makedirs(bench_dir, exist_ok=True)

    mpath = os.path.join(tools_dir, "records_manifest.tsv")
    with open(mpath, 'w') as f:
        f.write("k\tpattern\tbase_dec\tdigits\tdate\tauthor\tbits\n")
        for r in batch_records:
            f.write(f"{r['k']}\t{r['pattern']}\t{r['base_dec']}"
                    f"\t{r['digits']}\t{r['date']}\t{r['author']}"
                    f"\t{r['bits']}\n")

    jsonl_path = os.path.join(tmpdir, f"cal_{pass_label}.jsonl")
    cmd = [binary, "--validate-known", "--bench-jsonl", jsonl_path, "--full-quiet"]

    print(f"  pass [{pass_label}]: {len(batch_records)} records  cwd={tmpdir}")
    sys.stdout.flush()
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=len(batch_records) * timeout_per_rec + 60,
            cwd=tmpdir,
        )
    except subprocess.TimeoutExpired:
        print(f"  pass [{pass_label}]: TIMEOUT", file=sys.stderr)
        shutil.rmtree(tmpdir, ignore_errors=True)
        return {}
    wall = time.monotonic() - t0
    print(f"  pass [{pass_label}]: done in {wall:.1f}s (exit={proc.returncode})")

    rows = {}
    if os.path.isfile(jsonl_path):
        with open(jsonl_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                    rows[row["base"]] = row
                except (json.JSONDecodeError, KeyError):
                    continue

    shutil.rmtree(tmpdir, ignore_errors=True)
    return rows

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--suite",   default=SUITE_TSV)
    ap.add_argument("--out",     default=OUTPUT_JSON)
    ap.add_argument("--target",  type=float, default=TTR_TARGET_S,
                    help="Target sweep time in seconds (default 45)")
    ap.add_argument("--binary",  default=None)
    args = ap.parse_args()

    binary   = os.path.abspath(args.binary) if args.binary else find_binary()
    records  = load_suite(args.suite)
    target_s = args.target

    print(f"Binary  : {binary}")
    print(f"Suite   : {args.suite}  ({len(records)} records)")
    print(f"Target  : {target_s}s sweep")
    print()

    # Split records into batches of ≤MAX_PER_K per k value.
    # Group by k, chunk each group into batches of MAX_PER_K, then interleave
    # batches across k values so that each pass has ≤MAX_PER_K of each k.
    from collections import defaultdict
    by_k = defaultdict(list)
    for r in records:
        by_k[r['k']].append(r)

    # Produce batches: batch[i] contains the i-th slice of each k group
    max_batches = max(math.ceil(len(v) / MAX_PER_K) for v in by_k.values())
    passes = []
    for bi in range(max_batches):
        batch = []
        for k in sorted(by_k):
            chunk = by_k[k][bi * MAX_PER_K : (bi + 1) * MAX_PER_K]
            batch.extend(chunk)
        if batch:
            passes.append(batch)

    print(f"Running {len(passes)} calibration pass(es) "
          f"(binary cap={MAX_PER_K} records/k)...")

    probe_rows = {}  # base_dec -> JSONL row, accumulated across all passes
    for pi, batch in enumerate(passes):
        rows = run_probe_pass(binary, batch, f"p{pi+1}")
        probe_rows.update(rows)

    print(f"\n  total parsed: {len(probe_rows)} / {len(records)} records")
    print()

    calibration = []
    missing = []
    for r in records:
        probe = probe_rows.get(r['base_dec'])
        if probe is None:
            print(f"  {r['suite_id']} {r['pattern']} bits={r['bits']}: MISSING from JSONL")
            missing.append(r['suite_id'])
            continue

        binary_elapsed = probe.get("elapsed_s", 0.0)
        binary_prefix_bits = probe.get("prefix_bits", 0)
        tput_raw = probe.get("tput_cand_per_s", 0.0)
        found    = bool(probe.get("found", 0))

        # Adjust prefix_bits so expected sweep = target_s
        # binary used budget=60s; we want target_s
        # new_prefix_bits = binary_prefix_bits + round(log2(60 / target_s))
        # (more bits = smaller range = faster sweep; fewer bits = larger range)
        if binary_elapsed > 0 and binary_elapsed < 1e6:
            # Direct measurement: elapsed tells us how long the binary's prefix took
            # Adjust so target_s / elapsed * 2^(bits - prefix_bits) is matched
            delta = math.log2(binary_elapsed / target_s)
            adj_prefix_bits = binary_prefix_bits + round(delta)
        else:
            adj_prefix_bits = binary_prefix_bits

        # Clamp: must leave at least 1 bit to scan, max bits-1
        bits = r['bits']
        adj_prefix_bits = max(1, min(bits - 1, adj_prefix_bits))

        prefix_str = compute_prefix_str(r['base_dec'], bits, adj_prefix_bits)

        status = "OK" if found else "NOTFOUND"
        print(f"  {r['suite_id']} {r['pattern']:10s} bits={bits:2d}  "
              f"binary_p={binary_prefix_bits} adj_p={adj_prefix_bits}  "
              f"elapsed={binary_elapsed:.1f}s  {status}")

        calibration.append({
            "suite_id":         r['suite_id'],
            "k":                r['k'],
            "pattern":          r['pattern'],
            "base_dec":         r['base_dec'],
            "bits":             bits,
            "prefix_bits":      adj_prefix_bits,
            "prefix_str":       prefix_str,
            "probe_elapsed_s":  round(binary_elapsed, 3),
            "probe_prefix_bits":binary_prefix_bits,
            "probe_tput_cand_per_s": tput_raw,
            "probe_found":      found,
            "target_s":         target_s,
        })

    print()
    if missing:
        print(f"WARNING: {len(missing)} records missing from JSONL: {missing}")

    out = {
        "meta": {
            "binary":        binary,
            "suite_tsv":     args.suite,
            "target_s":      target_s,
            "n_records":     len(calibration),
            "n_missing":     len(missing),
            "generated_at":  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
        "records": calibration,
    }

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    with open(args.out, 'w') as f:
        json.dump(out, f, indent=2)
    print(f"Wrote {args.out}  ({len(calibration)} records calibrated)")

if __name__ == "__main__":
    main()
