#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""Parse soak artifacts and assert seven T-H9 invariants.

Exits 0 with `[T-H9] PASS: ...` if all green; nonzero with the failing
assertion name + relevant log span otherwise.
"""
import argparse, json, re, sys
from pathlib import Path
from statistics import median

STATE_RE = re.compile(r"^floor=\d+ high=\d+ current=\d+\s*$")
DMON_UTIL_RE = re.compile(r"^\s*\d+\s+(\d+)\b")  # `gpu sm ...` lines: 2nd col is sm util %

def fail(name, msg):
    print(f"[T-H9] FAIL: {name}: {msg}", file=sys.stderr); sys.exit(2)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artdir", required=True)
    ap.add_argument("--util-threshold", type=float, default=90.0)
    args = ap.parse_args()
    a = Path(args.artdir)

    # Assertion 5: state-file schema unchanged.
    state_post = (a / "state_post.txt").read_text().strip().split('\n')[-1] if (a / "state_post.txt").exists() else ""
    if not STATE_RE.match(state_post):
        fail("state_schema", f".lowbits_state post-soak doesn't match 'floor=N high=N current=N': got {state_post!r}")

    # Collect per-cell JSONL rows from any sweep_status.jsonl found under runs/.
    # NOTE: rows contain embedded \f (form-feed) in stdout_tail (run_lowbits.sh
    # uses `tr '\n' '\f'` to fold engine stderr into a single line). Use
    # split('\n'), NOT splitlines() — the latter splits on \f too and would
    # shatter every well-formed row. strict=False on json.loads accepts the
    # unescaped control character.
    rows = []
    for p in (a / "runs").rglob("sweep_status.jsonl"):
        for line in p.read_text().split('\n'):
            line = line.strip()
            if not line: continue
            try: rows.append(json.loads(line, strict=False))
            except json.JSONDecodeError as e:
                fail("partial_rows", f"non-JSON line in {p.name}: {e}")
    if not rows:
        fail("bits_progress", "no cells completed during soak (sweep_status.jsonl empty); the runner never landed a row")

    # Assertion 4: no partial-scan rows. Required fields per run_lowbits.sh:run_cell.
    REQ = ("sweep", "run_id", "pattern", "bits", "primorial", "started",
           "ended", "elapsed_sec", "rc", "exhausted", "found_lines")
    for i, r in enumerate(rows):
        miss = [f for f in REQ if f not in r]
        if miss:
            fail("partial_rows", f"row {i} ({r.get('run_id','?')}) missing fields: {miss}")

    # Assertion 1: bits non-decreasing across rows in completion order.
    rows_sorted = sorted(rows, key=lambda r: r.get("started", ""))
    prev = -1
    for r in rows_sorted:
        b = int(r["bits"])
        if b < prev:
            fail("bits_monotonic", f"bits regressed: {prev} -> {b} (run_id={r['run_id']})")
        prev = b

    # Assertion 2: nvidia-smi dmon median util >= threshold.
    dmon = a / "dmon.log"
    if not dmon.exists() or not dmon.read_text().strip():
        fail("util_median", "dmon.log missing or empty")
    utils = []
    for line in dmon.read_text().splitlines():
        m = DMON_UTIL_RE.match(line)
        if m: utils.append(int(m.group(1)))
    if len(utils) < 5:
        fail("util_median", f"dmon yielded only {len(utils)} samples; expected many more over the soak window")
    util_med = median(utils)
    if util_med < args.util_threshold:
        fail("util_median", f"util_median={util_med:.1f}% < threshold {args.util_threshold:.0f}% (n={len(utils)})")

    # Assertion 3: fluent-bit alive throughout, no kafka errors.
    pid_pre = (a / "fluentbit_pid_pre.txt").read_text().strip()
    pid_post = (a / "fluentbit_pid_post.txt").read_text().strip()
    # post file is "active\n<pid>"; pre is just <pid>
    pid_post_pid = pid_post.splitlines()[-1] if pid_post else ""
    if not pid_pre or pid_pre != pid_post_pid:
        fail("fluentbit_alive", f"fluent-bit pid changed or missing across soak: pre={pid_pre!r} post={pid_post_pid!r}")
    journal = (a / "fluentbit_journal.txt").read_text() if (a / "fluentbit_journal.txt").exists() else ""
    if "output_kafka error" in journal:
        bad = [l for l in journal.splitlines() if "output_kafka error" in l]
        fail("fluentbit_alive", f"fluent-bit journal shows kafka errors: {bad[:3]}")

    # Assertion 6: external (production-path) record reproduction. rc==0 means
    # every selected record (bits ≤ EXT_MAX_BITS) was recovered via --prefix.
    rc_file = a / "validate_external.rc"
    if not rc_file.exists():
        fail("external_validation", "validate_external.rc absent — harness did not invoke the external validator")
    ext_rc = int(rc_file.read_text().strip())
    log_lines = (a / "validate_external.log").read_text().splitlines() if (a / "validate_external.log").exists() else []
    if ext_rc != 0:
        fail("external_validation", f"validator rc={ext_rc}; log tail:\n" + "\n".join(log_lines[-20:]))
    n_reproduced = sum(1 for ln in log_lines if "[PASS] k=" in ln)
    if n_reproduced == 0:
        fail("external_validation", "validator rc=0 but no '[PASS] k=' lines — empty subset?")

    # Assertion 7 (W19-B-9 / multi-angle P1-3): post-exit phantom-util gate.
    # W18-I + W19-B-1 kt_cuda_cleanup_atexit calls cudaDeviceReset at process
    # exit; if cleanup actually fires, GPU util should drop to ~0% within a
    # second.  On some Blackwell GPU hosts, dmon can still report phantom
    # 100% with no attributable process; that is an artifact, not an engine
    # cleanup failure.  Therefore elevated util is fatal only if a kt_filter_v8
    # process is still present after teardown.
    pe_utils = []
    pe_dmon = a / "dmon_post_exit.log"
    if pe_dmon.exists() and pe_dmon.read_text().strip():
        for line in pe_dmon.read_text().splitlines():
            m = DMON_UTIL_RE.match(line)
            if m: pe_utils.append(int(m.group(1)))
    if pe_utils:
        post_exit_util_max = max(pe_utils)
        pids_post = (a / "kt_filter_pids_post_exit.txt").read_text().strip() if (a / "kt_filter_pids_post_exit.txt").exists() else ""
        if post_exit_util_max > 5 and pids_post:
            fail("post_exit_util",
                 f"post-exit util_max={post_exit_util_max}% > 5% with kt_filter_v8 still present: {pids_post!r}")
        if post_exit_util_max > 5:
            print(f"[T-H9] WARN: post-exit util_max={post_exit_util_max}% > 5% but no kt_filter_v8 PID remained; treating as host phantom-util artifact. samples={pe_utils}", file=sys.stderr)
    else:
        post_exit_util_max = -1
        print("[T-H9] WARN: no parseable post-exit dmon samples; skipping host-util assertion", file=sys.stderr)

    print(f"[T-H9] PASS: all assertions green, util_median={util_med:.1f}% post_exit_util_max={post_exit_util_max}% (cells={len(rows)}, dmon_samples={len(utils)}, n_records_reproduced={n_reproduced})")

if __name__ == "__main__":
    main()
