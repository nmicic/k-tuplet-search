#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
kpi_run.py — TTR harness for kt_filter_v8 KPI suite

Reads tools/kpi_suite_v1.calibration.json, runs each record M=3 times with the
calibrated prefix, collects elapsed_s, computes per-record median and suite-level
geomean TTR. Hard-fails on any NOTFOUND (hits=0).

Outputs: bench/kpi_baseline.json

Coverage note:
  kpi_suite_v1.tsv is a v1 sparse-record fallback covering 66-99 bits only.
  The intended 5-bucket suite (80/90/100/110/120 bits, N>=20) requires B1-class
  hits at 100+ bits that do not yet exist.  When new records land:
    1. Add rows to kpi_suite_v1.tsv (or create kpi_suite_v2.tsv for a new suite).
    2. Re-run tools/kpi_calibrate.py to regenerate the calibration JSON.
    3. Update CAL_JSON constant below to point at the new calibration file.
  Until then, TTR comparisons across engines are valid but the suite is not
  representative of the full 100-120 bit production regime.
"""

import argparse
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
import time

BINARY_NAME    = "kt_filter_v8"
CAL_JSON       = "tools/kpi_suite_v1.calibration.json"
OUTPUT_JSON    = "bench/kpi_baseline.json"
M_REPEATS      = 3
MAX_TIME_MULT  = 3.0   # max_time = target_s * MAX_TIME_MULT

# Gate thresholds summarized in TESTING.md.
WITHIN_RSD_THRESHOLD       = 0.15      # §5 line 124: per-record RSD ≤15%
SUITE_REL_SE_THRESHOLD     = 0.07      # §12 #3 line 233: bootstrap rel-SE ≤7%
BOOTSTRAP_RESAMPLES        = 1000      # §5 line 127: bootstrap-CI default
BOOTSTRAP_SEED             = 0xCAFEBABE
MIN_VALID_RECORDS_FLOOR    = 20        # §3 / §5: statistical N≥20 floor (data-hygiene only)

# W7.B — Top-half coverage gate (appendix §12 #4 line 235).
COVERAGE_TOP_HALF_THRESHOLD = 0.70     # ≥70% of suite records must be top-half vs baseline

# W14a — Promotion gate (appendix §12 #2 line 231).  Geomean TTR speedup
# vs --baseline-kpi must be ≥1/0.85 ≈ 1.176× (≡ current_geomean ≤ 0.85×
# baseline_geomean).  Without --baseline-kpi the gate is SKIPPED.
PROMOTION_GATE_RATIO = 0.85

# W7.C — Resource sub-gates (appendix §12 #5 line 237).
RESOURCE_HOST_RSS_KB_LIMIT = 8 * 1024 * 1024       # host RAM ≤ 8 GB
RESOURCE_HBM_LIMIT_MIB     = int(0.80 * 25.6 * 1024)  # 80% of 25.6 GB target HBM = 20971 MiB
PCIE_LINK_MIBPS_REF        = 63 * 1024              # PCIe 5.0 x16 ≈ 63 GB/s reference
RESOURCE_PCIE_FRACTION_LIM = 0.50                   # peak PCIe util ≤ 50% of link bandwidth

def find_binary():
    for p in [f"src/cuda/{BINARY_NAME}", f"./{BINARY_NAME}"]:
        if os.path.isfile(p):
            return os.path.abspath(p)
    sys.exit(f"ERROR: {BINARY_NAME} not found in src/cuda/ or ./")

def parse_final(text):
    """Extract elapsed_s, hits, cand_per_s, useful_cand_per_s from === final === line.

    Actual field order: hits= elapsed= cand/s= useful_cand/s= ... gpu_util_pct=

    also pull every emitted FOUND base and the
    kpi_target_base/kpi_early_exit/kpi_match_seen marker line so the caller
    can distinguish OK from WRONG_BASE.
    """
    # Primary: match fields in actual output order
    m = re.search(
        r"=== final:.*?hits=(\d+)\s+elapsed=([\d.]+)s\s+"
        r"cand/s=([\d.e+\-]+)\s+useful_cand/s=([\d.e+\-]+)"
        r".*?gpu_util_pct=([\d.]+)",
        text,
    )
    parsed = None
    if m:
        parsed = {
            "hits":              int(m.group(1)),
            "elapsed_s":         float(m.group(2)),
            "cand_per_s":        float(m.group(3)),
            "useful_cand_per_s": float(m.group(4)),
            "gpu_util_pct":      float(m.group(5)),
        }
    else:
        # Fallback: extract individual fields independently
        def extract(pat, t):
            fm = re.search(pat, t)
            return fm.group(1) if fm else None
        hits_s    = extract(r"hits=(\d+)", text)
        elapsed_s = extract(r"elapsed=([\d.]+)s", text)
        if hits_s and elapsed_s:
            parsed = {
                "hits":              int(hits_s),
                "elapsed_s":         float(elapsed_s),
                "cand_per_s":        0.0,
                "useful_cand_per_s": 0.0,
                "gpu_util_pct":      0.0,
            }
    if parsed is None:
        return None

    # collect every emitted base from FOUND banners (stderr).
    # crash_safe_announce format: "*** FOUND k=K bits=B pattern=P base=DEC ***"
    parsed["found_bases"] = re.findall(
        r"\*\*\* FOUND .*?base=(\d+) \*\*\*", text)

    # parse the kpi marker line.  Absent on non-KPI runs.
    km = re.search(
        r"kpi_target_base=(\d+)\s+kpi_early_exit=(\d+)\s+kpi_match_seen=(\d+)",
        text)
    if km:
        parsed["kpi_target_base"] = km.group(1)
        parsed["kpi_early_exit"]  = int(km.group(2))
        parsed["kpi_match_seen"]  = int(km.group(3))
    else:
        parsed["kpi_target_base"] = None
        parsed["kpi_early_exit"]  = 0
        parsed["kpi_match_seen"]  = 0
    return parsed

def _parse_time_v_rss(time_log_text):
    """Extract Maximum RSS (kB) from /usr/bin/time -v output.  Returns int or None."""
    if not time_log_text:
        return None
    m = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", time_log_text)
    return int(m.group(1)) if m else None

def _which(name):
    for p in os.environ.get("PATH", "").split(os.pathsep):
        cand = os.path.join(p, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None

def _start_gpu_pollers(hbm_path, pcie_path, gpu_idx=0):
    """Spawn nvidia-smi pollers scoped to ``gpu_idx``.

    HBM:  ``--query-gpu=memory.used,utilization.gpu --id=<idx> -lms 200``.
    PCIe: ``dmon -s t -d 1 -i <idx>`` (W14b: was ``-s u``, which emits
          sm/mem/enc/dec; the parser expects rxpci/txpci which only ``-s t``
          emits, so PCIe samples were silently dropped).

    Returns (hbm_proc, pcie_proc); either may be None if launch failed.
    """
    hp, pp = None, None
    try:
        hp = subprocess.Popen(
            ["nvidia-smi", "--query-gpu=memory.used,utilization.gpu",
             "--format=csv,noheader,nounits",
             f"--id={gpu_idx}", "-lms", "200"],
            stdout=open(hbm_path, "w"), stderr=subprocess.DEVNULL,
        )
    except (OSError, FileNotFoundError):
        hp = None
    try:
        pp = subprocess.Popen(
            ["nvidia-smi", "dmon", "-s", "t", "-d", "1", "-i", str(gpu_idx)],
            stdout=open(pcie_path, "w"), stderr=subprocess.DEVNULL,
        )
    except (OSError, FileNotFoundError):
        pp = None
    return hp, pp

def _stop_proc(proc):
    if proc is None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=3)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=2)
        except Exception:
            pass

def _parse_query_gpu_max_mib(text):
    """Parse `nvidia-smi --query-gpu=memory.used,utilization.gpu ...` CSV polling output.
    Returns max memory.used (MiB) across samples, or None if no samples parsed.
    """
    if not text:
        return None
    peak = None
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        toks = [t.strip() for t in ln.split(",")]
        if not toks:
            continue
        try:
            mib = int(toks[0])
        except ValueError:
            continue
        if peak is None or mib > peak:
            peak = mib
    return peak

def _parse_dmon_pcie(text):
    """Parse `nvidia-smi dmon -s u -d 1` column output for rxpci+txpci (MiB/s).

    Header lines start with '#'; the second '#'-line names columns.  We locate
    the rxpci and txpci column indices and aggregate across data rows.
    Returns (peak_total_mibps, avg_total_mibps, n_samples) or (None, None, 0).
    """
    if not text:
        return None, None, 0
    rx_idx, tx_idx = None, None
    samples = []
    seen_data = False
    for ln in text.splitlines():
        ln_strip = ln.strip()
        if not ln_strip:
            continue
        if ln_strip.startswith("#"):
            toks = ln_strip.lstrip("#").split()
            if "rxpci" in toks and "txpci" in toks:
                rx_idx = toks.index("rxpci")
                tx_idx = toks.index("txpci")
            continue
        if rx_idx is None or tx_idx is None:
            continue
        toks = ln_strip.split()
        if len(toks) <= max(rx_idx, tx_idx):
            continue
        try:
            rx = float(toks[rx_idx])
            tx = float(toks[tx_idx])
        except ValueError:
            continue
        samples.append(rx + tx)
        seen_data = True
    if not samples:
        return None, None, 0
    peak = max(samples)
    avg = sum(samples) / len(samples)
    return peak, avg, len(samples)

def run_one(binary, rec, max_time, extra_args, time_v_path, gpu_poll=False,
            gpu_idx=0):
    """Run binary for one record, return (parsed, status, wall, resource).

    pass --kpi-target-base so the engine early-exits on the
    matching base and emits the kpi marker line; the harness uses that to
    distinguish OK / WRONG_BASE / NOTFOUND.

    Wrap the binary in /usr/bin/time -v when available
    so the harness can record host peak RSS for the resource gate.

    when gpu_poll=True (and nvidia-smi is on PATH), spawn HBM and
    PCIe pollers in the background and harvest peak memory.used (MiB) and
    peak/avg PCIe rx+tx throughput (MiB/s) for the resource gate.

    `resource` is a dict:
        peak_rss_kb       — host max-RSS from /usr/bin/time -v, or None
        gpu_hbm_peak_mib  — peak nvidia-smi memory.used during run, or None
        pcie_peak_mibps   — peak rx+tx throughput, or None
        pcie_avg_mibps    — avg rx+tx throughput, or None
    """
    inner_cmd = [
        binary,
        "--k",       str(rec["k"]),
        "--bits",    str(rec["bits"]),
        "--pattern", rec["pattern"],
        "--prefix",  rec["prefix_str"],
        "--max-time", str(int(max_time) + 1),
        "--kpi-target-base", str(rec["base_dec"]),
        "--full-quiet",
    ] + extra_args

    time_log_path = None
    if time_v_path:
        # Write time -v output to a side file under ./tmp/ so it doesn't
        # contaminate the binary's stderr (which the parser scans).
        fd, time_log_path = tempfile.mkstemp(prefix="kpi_time_", suffix=".log",
                                             dir="./tmp")
        os.close(fd)
        cmd = [time_v_path, "-v", "-o", time_log_path] + inner_cmd
    else:
        cmd = inner_cmd

    hbm_log = pcie_log = None
    hbm_proc = pcie_proc = None
    if gpu_poll:
        hfd, hbm_log = tempfile.mkstemp(prefix="kpi_hbm_", suffix=".log", dir="./tmp")
        os.close(hfd)
        pfd, pcie_log = tempfile.mkstemp(prefix="kpi_pcie_", suffix=".log", dir="./tmp")
        os.close(pfd)
        hbm_proc, pcie_proc = _start_gpu_pollers(hbm_log, pcie_log,
                                                 gpu_idx=gpu_idx)

    def _empty_resource():
        return {"peak_rss_kb": None, "gpu_hbm_peak_mib": None,
                "pcie_peak_mibps": None, "pcie_avg_mibps": None,
                "pcie_n_samples": 0}

    def _harvest_gpu():
        gpu_hbm_peak_mib = None
        pcie_peak = pcie_avg = None
        pcie_n = 0
        _stop_proc(hbm_proc)
        _stop_proc(pcie_proc)
        if hbm_log and os.path.isfile(hbm_log):
            try:
                with open(hbm_log) as f:
                    gpu_hbm_peak_mib = _parse_query_gpu_max_mib(f.read())
            except OSError:
                pass
            try: os.unlink(hbm_log)
            except OSError: pass
        if pcie_log and os.path.isfile(pcie_log):
            try:
                with open(pcie_log) as f:
                    pcie_peak, pcie_avg, pcie_n = _parse_dmon_pcie(f.read())
            except OSError:
                pass
            try: os.unlink(pcie_log)
            except OSError: pass
        return gpu_hbm_peak_mib, pcie_peak, pcie_avg, pcie_n

    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            cmd, capture_output=False, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            timeout=int(max_time * 2) + 60,
        )
    except subprocess.TimeoutExpired:
        if time_log_path and os.path.isfile(time_log_path):
            os.unlink(time_log_path)
        res = _empty_resource()
        if gpu_poll:
            (res["gpu_hbm_peak_mib"], res["pcie_peak_mibps"],
             res["pcie_avg_mibps"], res["pcie_n_samples"]) = _harvest_gpu()
        return None, "timeout", time.monotonic() - t0, res

    wall = time.monotonic() - t0

    peak_rss_kb = None
    if time_log_path:
        try:
            with open(time_log_path) as f:
                peak_rss_kb = _parse_time_v_rss(f.read())
        except OSError:
            peak_rss_kb = None
        finally:
            if os.path.isfile(time_log_path):
                os.unlink(time_log_path)

    res = _empty_resource()
    res["peak_rss_kb"] = peak_rss_kb
    if gpu_poll:
        (res["gpu_hbm_peak_mib"], res["pcie_peak_mibps"],
         res["pcie_avg_mibps"], res["pcie_n_samples"]) = _harvest_gpu()

    combined = proc.stdout + proc.stderr
    parsed = parse_final(combined)
    if parsed is None:
        return None, f"no-final (rc={proc.returncode})", wall, res
    return parsed, "ok", wall, res

def _synthetic_one(rec, rep_idx):
    """Replay a synthetic_repeats[rep_idx] entry as if it came from
    the binary.  The fixture format mirrors the parsed-final dict.

    Each entry is one of:
      None / {"parse_fail": "<reason>"}   → harness treats as PARSE_FAIL
      {"hits": int, "elapsed_s": float, "kpi_match_seen": 0|1,
       "found_bases": [str,...], optional "peak_rss_kb": int, ...}

    Returns (parsed, status, wall, resource) — same shape as run_one().
    """
    def _res_from(sr):
        if not isinstance(sr, dict):
            sr = {}
        return {
            "peak_rss_kb":      sr.get("peak_rss_kb"),
            "gpu_hbm_peak_mib": sr.get("gpu_hbm_peak_mib"),
            "pcie_peak_mibps":  sr.get("pcie_peak_mibps"),
            "pcie_avg_mibps":   sr.get("pcie_avg_mibps"),
            "pcie_n_samples":   sr.get("pcie_n_samples", 0),
        }
    sr_list = rec.get("synthetic_repeats")
    empty_res = {"peak_rss_kb": None, "gpu_hbm_peak_mib": None,
                 "pcie_peak_mibps": None, "pcie_avg_mibps": None,
                 "pcie_n_samples": 0}
    if not sr_list or rep_idx >= len(sr_list):
        return None, "synthetic-missing", 0.0, empty_res
    sr = sr_list[rep_idx]
    if sr is None:
        return None, "synthetic-parse-fail", 0.0, empty_res
    if isinstance(sr, dict) and sr.get("parse_fail"):
        return None, sr["parse_fail"], 0.0, _res_from(sr)
    parsed = {
        "hits":              int(sr.get("hits", 0)),
        "elapsed_s":         float(sr.get("elapsed_s", 0.0)),
        "cand_per_s":        float(sr.get("cand_per_s", 0.0)),
        "useful_cand_per_s": float(sr.get("useful_cand_per_s", 0.0)),
        "gpu_util_pct":      float(sr.get("gpu_util_pct", 100.0)),
        "found_bases":       list(sr.get("found_bases", [])),
        "kpi_target_base":   sr.get("kpi_target_base"),
        "kpi_early_exit":    int(sr.get("kpi_early_exit", 0)),
        "kpi_match_seen":    int(sr.get("kpi_match_seen", 0)),
    }
    return parsed, "ok", float(sr.get("elapsed_s", 0.0)), _res_from(sr)

def bootstrap_geomean_relstderr(values, n_resamples=BOOTSTRAP_RESAMPLES,
                                seed=BOOTSTRAP_SEED):
    """Bootstrap relative std-error of the geomean (appendix §5 line 127).

    Returns (relative_se, lo_80, hi_80) where:
      - relative_se = std(bootstrap_geomeans) / mean(bootstrap_geomeans)
      - lo_80, hi_80 = 10th/90th percentile of bootstrap_geomeans (80% CI)

    Returns (None, None, None) if fewer than 2 samples.
    Pure stdlib — no scipy/numpy.
    """
    if len(values) < 2:
        return None, None, None
    rng = random.Random(seed)
    n = len(values)
    boot_means = []
    for _ in range(n_resamples):
        sample = rng.choices(values, k=n)
        boot_means.append(geomean(sample))
    boot_means.sort()
    mean = sum(boot_means) / len(boot_means)
    if mean == 0:
        return 0.0, 0.0, 0.0
    var = sum((v - mean) ** 2 for v in boot_means) / (len(boot_means) - 1)
    rel_se = math.sqrt(var) / mean
    lo_idx = int(0.10 * len(boot_means))
    hi_idx = int(0.90 * len(boot_means))
    return rel_se, boot_means[lo_idx], boot_means[hi_idx]

def geomean(values):
    if not values:
        return 0.0
    log_sum = sum(math.log(v) for v in values)
    return math.exp(log_sum / len(values))

def rel_std(values):
    """Relative std-dev: std / mean."""
    if len(values) < 2:
        return 0.0
    n = len(values)
    mean = sum(values) / n
    if mean == 0:
        return 0.0
    var = sum((v - mean) ** 2 for v in values) / (n - 1)
    return math.sqrt(var) / mean

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cal",     default=CAL_JSON)
    ap.add_argument("--out",     default=OUTPUT_JSON)
    ap.add_argument("--repeats", type=int, default=M_REPEATS)
    ap.add_argument("--binary",  default=None)
    ap.add_argument("--extra",   nargs="*", default=[],
                    help="Extra flags passed to the binary (e.g. --gpu-batch-size 2097152)")
    ap.add_argument("--synthetic", action="store_true",
                    help="replay synthetic_repeats from the calibration "
                         "instead of running the binary (gate fixtures / unit tests).")
    ap.add_argument("--no-resource-gate", action="store_true",
                    help="Disable resource gates (host RSS + GPU HBM + PCIe); still report values.")
    ap.add_argument("--baseline-kpi", default=None,
                    help="prior KPI output JSON used as the baseline for "
                         "the top-half coverage gate (appendix §12 #4). When omitted, "
                         "the top-half gate is skipped (cannot promote without baseline).")
    ap.add_argument("--no-gpu-poll", action="store_true",
                    help="disable nvidia-smi polling for HBM/PCIe sub-gates "
                         "even when nvidia-smi is on PATH.")
    ap.add_argument("--gpu-device", type=int, default=None,
                    help="scope HBM + PCIe pollers to this CUDA "
                         "device index (default: 0 with WARN). The same index "
                         "is also auto-appended to the engine command via "
                         "--gpu-device <N> unless already present in --extra.")
    args = ap.parse_args()

    binary = None
    time_v_path = None
    gpu_poll_available = False
    # W14b — effective GPU index for pollers (and auto-prepended for engine).
    # Unset → default 0 with a stderr WARN so multi-GPU runs cannot silently
    # mis-sample the wrong device.
    if args.gpu_device is None:
        gpu_idx = 0
        gpu_idx_explicit = False
    else:
        gpu_idx = int(args.gpu_device)
        gpu_idx_explicit = True
    if not args.synthetic:
        binary = os.path.abspath(args.binary) if args.binary else find_binary()
        # /usr/bin/time -v is the only stdlib-free way to capture peak RSS on Linux.
        if os.access("/usr/bin/time", os.X_OK):
            time_v_path = "/usr/bin/time"
        os.makedirs("./tmp", exist_ok=True)
        gpu_poll_available = (not args.no_gpu_poll) and (_which("nvidia-smi") is not None)
        if gpu_poll_available and not gpu_idx_explicit:
            print(f"WARN: --gpu-device unset; HBM+PCIe pollers will sample "
                  f"GPU 0. On multi-GPU hosts pass --gpu-device <N> "
                  f"matching the engine to avoid mis-sampling.",
                  file=sys.stderr)
        # W14b — auto-prepend --gpu-device <N> to the engine command when the
        # operator hasn't already passed it via --extra (so the pollers and
        # the engine target the same device).
        extra_has_gpu_device = any(a == "--gpu-device" for a in args.extra)
        if not extra_has_gpu_device:
            args.extra = ["--gpu-device", str(gpu_idx)] + list(args.extra)

    with open(args.cal) as f:
        cal = json.load(f)
    records = cal["records"]
    target_s = cal["meta"].get("target_s", 45.0)
    max_time = target_s * MAX_TIME_MULT

    print(f"Binary  : {binary if binary else '(synthetic mode)'}")
    print(f"Cal     : {args.cal}  ({len(records)} records)")
    print(f"Repeats : {args.repeats}")
    print(f"MaxTime : {max_time:.0f}s per run")
    print(f"Resource: time -v {'AVAILABLE' if time_v_path else 'UNAVAILABLE (host-RSS gate will skip)'}"
          f"  | nvidia-smi {'AVAILABLE' if gpu_poll_available else 'UNAVAILABLE (HBM+PCIe gates will skip)'}"
          f"{'  (synthetic — values taken from fixture)' if args.synthetic else ''}")
    print(f"Baseline: {args.baseline_kpi if args.baseline_kpi else '(none — top-half gate will skip)'}")
    print(f"GPU dev : {gpu_idx}{'  (--gpu-device)' if gpu_idx_explicit else '  (default; pollers + engine target GPU 0)'}")
    print()

    M = args.repeats
    record_results = []
    any_notfound      = False
    any_parse_failure = False

    for ri, rec in enumerate(records):
        sid = rec["suite_id"]
        print(f"[{ri+1:2d}/{len(records)}] {sid} {rec['pattern']:10s} bits={rec['bits']:2d}  "
              f"prefix={rec['prefix_str'][:20]}...  target={target_s:.0f}s")
        sys.stdout.flush()

        repeat_data = []
        rec_notfound = False

        for rep in range(M):
            t_wall0 = time.monotonic()
            if args.synthetic:
                parsed, status, wall, resource = _synthetic_one(rec, rep)
            else:
                parsed, status, wall, resource = run_one(
                    binary, rec, max_time, args.extra, time_v_path,
                    gpu_poll=gpu_poll_available, gpu_idx=gpu_idx)
            peak_rss_kb       = resource.get("peak_rss_kb")
            gpu_hbm_peak_mib  = resource.get("gpu_hbm_peak_mib")
            pcie_peak_mibps   = resource.get("pcie_peak_mibps")
            pcie_avg_mibps    = resource.get("pcie_avg_mibps")
            pcie_n_samples    = resource.get("pcie_n_samples", 0)
            t_wall1 = time.monotonic()

            if parsed is None:
                # parse failure (timeout / FATAL / malformed) must
                # propagate to the suite gate, not just mark this rep bad.
                # Surface the underlying status string in the JSON record.
                parse_status = f"PARSE_FAIL:{status}"
                print(f"   rep{rep+1}: ERROR ({status})  wall={wall:.1f}s")
                rec_notfound     = True
                any_notfound     = True
                any_parse_failure = True
                repeat_data.append({"rep": rep+1, "elapsed_s": None,
                                     "hits": 0, "status": parse_status,
                                     "peak_rss_kb":      peak_rss_kb,
                                     "gpu_hbm_peak_mib": gpu_hbm_peak_mib,
                                     "pcie_peak_mibps":  pcie_peak_mibps,
                                     "pcie_avg_mibps":   pcie_avg_mibps,
                                     "pcie_n_samples":   pcie_n_samples})
                continue

            hits     = parsed["hits"]
            elapsed  = parsed["elapsed_s"]
            util     = parsed["gpu_util_pct"]

            # status is now match-aware.  OK iff the engine
            # emitted the suite row's base (kpi_match_seen=1).  Any FOUND
            # with a different base is WRONG_BASE — an alarm, not a PASS.
            target_base = str(rec["base_dec"])
            kpi_seen    = parsed.get("kpi_match_seen", 0)
            found_bases = parsed.get("found_bases", []) or []
            any_wrong_base = any(b != target_base for b in found_bases)

            if kpi_seen == 1:
                status = "OK"
            elif any_wrong_base:
                status = "WRONG_BASE"
                rec_notfound = True
                any_notfound = True
            else:
                status = "NOTFOUND"
                rec_notfound = True
                any_notfound = True

            ttr_s = elapsed if status == "OK" else None

            print(f"   rep{rep+1}: elapsed={elapsed:.2f}s  hits={hits}  "
                  f"util={util:.0f}%  [{status}]")
            sys.stdout.flush()

            repeat_data.append({
                "rep":            rep + 1,
                "elapsed_s":      elapsed,
                "ttr_s":          ttr_s,
                "hits":           hits,
                "cand_per_s":     parsed["cand_per_s"],
                "useful_cand_per_s": parsed["useful_cand_per_s"],
                "gpu_util_pct":   util,
                "status":         status,
                "kpi_match_seen": kpi_seen,
                "kpi_early_exit": parsed.get("kpi_early_exit", 0),
                "found_bases":    found_bases,
                "peak_rss_kb":      peak_rss_kb,
                "gpu_hbm_peak_mib": gpu_hbm_peak_mib,
                "pcie_peak_mibps":  pcie_peak_mibps,
                "pcie_avg_mibps":   pcie_avg_mibps,
                "pcie_n_samples":   pcie_n_samples,
            })

        # Per-record stats: use ttr_s (set only on status=OK)
        # so WRONG_BASE / NOTFOUND reps no longer pollute the median.
        valid_elapsed = [d["ttr_s"] for d in repeat_data
                         if d.get("ttr_s") is not None]
        if valid_elapsed:
            valid_elapsed.sort()
            n = len(valid_elapsed)
            median_ttr = valid_elapsed[n // 2]
            rsd = rel_std(valid_elapsed)
        else:
            median_ttr = None
            rsd = None

        rsd_str = f"{rsd*100:.1f}%" if rsd is not None else "N/A"
        med_str = f"{median_ttr:.2f}s" if median_ttr is not None else "N/A"
        status_str = "NOTFOUND" if rec_notfound else "PASS"
        print(f"   => median={med_str}  rsd={rsd_str}  [{status_str}]")
        print()

        # W4.A: within-record RSD over valid reps (None when <2 valid reps).
        within_record_rsd_pct = (rsd * 100.0) if rsd is not None else None

        # W4.D / W7.C: peak host RSS + peak GPU HBM + peak PCIe across all reps.
        def _max_or_none(key):
            vals = [d.get(key) for d in repeat_data if d.get(key) is not None]
            return max(vals) if vals else None
        rec_peak_rss_kb       = _max_or_none("peak_rss_kb")
        rec_gpu_hbm_peak_mib  = _max_or_none("gpu_hbm_peak_mib")
        rec_pcie_peak_mibps   = _max_or_none("pcie_peak_mibps")
        rec_pcie_avg_mibps    = _max_or_none("pcie_avg_mibps")
        rec_pcie_n_samples    = sum(d.get("pcie_n_samples", 0) or 0
                                    for d in repeat_data)

        record_results.append({
            "suite_id":      sid,
            "k":             rec["k"],
            "pattern":       rec["pattern"],
            "bits":          rec["bits"],
            "prefix_str":    rec["prefix_str"],
            "prefix_bits":   rec["prefix_bits"],
            "base_dec":      rec["base_dec"],
            "repeats":       repeat_data,
            "median_ttr_s":  median_ttr,
            "rel_std":       rsd,
            "within_record_rsd_pct": within_record_rsd_pct,
            "peak_rss_kb":      rec_peak_rss_kb,
            "gpu_hbm_peak_mib": rec_gpu_hbm_peak_mib,
            "pcie_peak_mibps":  rec_pcie_peak_mibps,
            "pcie_avg_mibps":   rec_pcie_avg_mibps,
            "pcie_n_samples":   rec_pcie_n_samples,
            "notfound":      rec_notfound,
        })

    # Suite-level stats
    valid_medians = [r["median_ttr_s"] for r in record_results
                     if r["median_ttr_s"] is not None and not r["notfound"]]
    suite_geomean  = geomean(valid_medians) if valid_medians else None
    # cross-record RSD is informational dispersion, not a gate.
    cross_record_dispersion = rel_std(valid_medians) if len(valid_medians) >= 2 else None
    n_pass         = sum(1 for r in record_results if not r["notfound"])
    n_fail         = len(record_results) - n_pass

    print("=" * 60)
    print(f"Suite N        : {len(record_results)}")
    print(f"PASS           : {n_pass}")
    print(f"NOTFOUND       : {n_fail}")
    if suite_geomean is not None:
        print(f"Geomean TTR    : {suite_geomean:.2f}s")
    if cross_record_dispersion is not None:
        # Informational only — appendix §12 #3 gates suite_rel_se (bootstrap), not raw spread.
        print(f"Cross-rec disp.: {cross_record_dispersion*100:.1f}%  [info, ungated]")

    # ──────────────────────────────────────────────────────────────────
    # KPI-canonical gates. These replace earlier appendix-misaligned gates
    # with the canonical TTR and resource forms.
    # ──────────────────────────────────────────────────────────────────

    # W4.A — Within-record RSD ≤ 15% (appendix §5 line 124).
    within_rsd_offenders = [
        (r["suite_id"], r["within_record_rsd_pct"])
        for r in record_results
        if r["within_record_rsd_pct"] is not None
        and r["within_record_rsd_pct"] > WITHIN_RSD_THRESHOLD * 100.0
    ]
    within_rsd_fail = len(within_rsd_offenders) > 0
    if within_rsd_offenders:
        offender_str = ", ".join(f"{sid}={pct:.1f}%"
                                 for sid, pct in within_rsd_offenders[:5])
        print(f"Within-rec RSD : FAIL ({len(within_rsd_offenders)} offenders, "
              f">15% threshold) [{offender_str}]")
    else:
        print(f"Within-rec RSD : OK (all records ≤15% over M={M} reps)")

    # W7.A — Suite-level relative std-error of bootstrap geomean ≤ 7%
    # (appendix §5 lines 120, 127 + §12 #3 line 233).  This is the canonical
    # variance gate; it replaces the raw cross-record RSD that W4.B kept.
    suite_rel_se, bootstrap_lo80, bootstrap_hi80 = bootstrap_geomean_relstderr(
        valid_medians)
    suite_rel_se_fail = (suite_rel_se is not None
                         and suite_rel_se > SUITE_REL_SE_THRESHOLD)
    if suite_rel_se is None:
        print(f"Suite rel-SE   : N/A (need ≥2 valid records, got {len(valid_medians)})")
    else:
        flag = "  [FAIL: >7%]" if suite_rel_se_fail else "  [OK]"
        print(f"Suite rel-SE   : {suite_rel_se*100:.1f}%  "
              f"(80%% CI [{bootstrap_lo80:.2f}s, {bootstrap_hi80:.2f}s], "
              f"{BOOTSTRAP_RESAMPLES} resamples){flag}")

    # W7.B — Coverage gate (top-half on ≥70% of suite records, appendix §12 #4
    # line 235).  Requires --baseline-kpi.  Without baseline, the gate is
    # SKIPPED with a warning that promotion cannot fire.
    coverage_top_half_fail = False
    coverage_top_half_pct = None
    coverage_top_half_n = None
    coverage_top_half_total = None
    coverage_top_half_detail = []
    coverage_top_half_skipped = False
    baseline_meta = None
    bl_by_id = {}                     # W14a: shared with promotion gate
    if args.baseline_kpi:
        try:
            with open(args.baseline_kpi) as f:
                bl = json.load(f)
            bl_by_id = {r["suite_id"]: r for r in bl.get("records", [])}
            baseline_meta = bl.get("meta", {})
            n_top = 0
            for r in record_results:
                sid = r["suite_id"]
                cm = r["median_ttr_s"]
                bm = bl_by_id.get(sid, {}).get("median_ttr_s") if sid in bl_by_id else None
                top = (cm is not None and bm is not None and cm <= bm)
                if top:
                    n_top += 1
                coverage_top_half_detail.append({
                    "suite_id": sid, "candidate_s": cm,
                    "baseline_s": bm, "top_half": top,
                })
            coverage_top_half_n = n_top
            coverage_top_half_total = len(record_results)
            coverage_top_half_pct = (
                (n_top / coverage_top_half_total)
                if coverage_top_half_total > 0 else 0.0)
            coverage_top_half_fail = (
                coverage_top_half_pct < COVERAGE_TOP_HALF_THRESHOLD)
            cov_flag = "  [FAIL: <70%]" if coverage_top_half_fail else "  [OK]"
            print(f"Coverage TopH  : {n_top}/{coverage_top_half_total} = "
                  f"{coverage_top_half_pct*100:.1f}% top-half vs baseline{cov_flag}")
        except (OSError, ValueError, KeyError) as ex:
            coverage_top_half_skipped = True
            print(f"Coverage TopH  : SKIPPED (failed to load --baseline-kpi: {ex})")
    else:
        coverage_top_half_skipped = True
        print(f"Coverage TopH  : SKIPPED (no --baseline-kpi; promotion gate cannot fire)")

    # W14a — Promotion gate (appendix §12 #2 line 231).  Compute geomean of
    # current run median_ttr_s over records also present in baseline; same
    # for baseline.  Pass: current_geomean ≤ 0.85 × baseline_geomean
    # (equivalently speedup = baseline/current ≥ 1.176×).  Without
    # --baseline-kpi the gate is SKIPPED (cannot promote without baseline).
    promotion_gate_fail      = False
    promotion_gate_skipped   = False
    promotion_speedup        = None
    promotion_current_geo    = None
    promotion_baseline_geo   = None
    promotion_n_paired       = 0
    if args.baseline_kpi and bl_by_id:
        cur_pairs  = []
        base_pairs = []
        for r in record_results:
            sid = r["suite_id"]
            cm  = r.get("median_ttr_s")
            br  = bl_by_id.get(sid) if sid in bl_by_id else None
            bm  = br.get("median_ttr_s") if br else None
            if cm is None or bm is None or cm <= 0 or bm <= 0:
                continue
            cur_pairs.append(cm)
            base_pairs.append(bm)
        promotion_n_paired = len(cur_pairs)
        if promotion_n_paired == 0:
            promotion_gate_skipped = True
            print(f"Promotion gate : SKIPPED (no paired records vs baseline)")
        else:
            promotion_current_geo  = geomean(cur_pairs)
            promotion_baseline_geo = geomean(base_pairs)
            if promotion_current_geo <= 0:
                promotion_gate_skipped = True
                print(f"Promotion gate : SKIPPED (current geomean is non-positive)")
            else:
                promotion_speedup   = (
                    promotion_baseline_geo / promotion_current_geo)
                promotion_pass      = (
                    promotion_current_geo
                    <= PROMOTION_GATE_RATIO * promotion_baseline_geo)
                promotion_gate_fail = not promotion_pass
                flag = ("  [PASS]" if promotion_pass
                        else "  [FAIL: speedup<1.176×, ≥15% required]")
                print(f"Promotion gate : speedup={promotion_speedup:.3f}× "
                      f"(current geomean {promotion_current_geo:.2f}s "
                      f"vs baseline {promotion_baseline_geo:.2f}s); "
                      f"appendix threshold {PROMOTION_GATE_RATIO:.2f}×{flag}")
    else:
        promotion_gate_skipped = True
        print(f"Promotion gate : SKIPPED (no --baseline-kpi)")

    # W7.B (data-hygiene only, was W4.C "coverage") — minimum valid records.
    # Threshold = min(20, n_loaded).  Distinct from the appendix promotion
    # gate; kept as a weaker hygiene check on the run itself.
    min_valid_records       = len(valid_medians)
    min_valid_records_thr   = min(MIN_VALID_RECORDS_FLOOR, len(record_results))
    min_valid_records_fail  = min_valid_records < min_valid_records_thr
    coverage_substandard    = len(record_results) < MIN_VALID_RECORDS_FLOOR
    mvr_flag = "  [FAIL]" if min_valid_records_fail else "  [OK]"
    mvr_warn = "  [WARN: suite size <20, sub-spec]" if coverage_substandard else ""
    print(f"Min-valid-recs : {min_valid_records}/{len(record_results)} valid "
          f"(threshold ≥{min_valid_records_thr}){mvr_flag}{mvr_warn}")

    # W7.C — Resource gate (appendix §12 #5 line 237):
    #   • host RAM ≤ 8 GB
    #   • GPU HBM ≤ 80% of 25.6 GB target (≈20.5 GiB)
    #   • PCIe util ≤ 50% of link bandwidth (PCIe 5.0 x16 ≈ 63 GB/s ref)
    rss_values = [r["peak_rss_kb"] for r in record_results
                  if r["peak_rss_kb"] is not None]
    resource_peak_rss_kb = max(rss_values) if rss_values else None
    hbm_values = [r["gpu_hbm_peak_mib"] for r in record_results
                  if r["gpu_hbm_peak_mib"] is not None]
    resource_peak_hbm_mib = max(hbm_values) if hbm_values else None
    pcie_peak_values = [r["pcie_peak_mibps"] for r in record_results
                        if r["pcie_peak_mibps"] is not None]
    resource_peak_pcie_mibps = max(pcie_peak_values) if pcie_peak_values else None
    resource_peak_pcie_pct = (
        resource_peak_pcie_mibps / PCIE_LINK_MIBPS_REF
        if resource_peak_pcie_mibps is not None else None)
    # W14b — total PCIe samples across the suite.  Pre-W14b this would
    # always be 0 due to the dmon -s u column-mismatch silently dropping
    # every row; post-W14b a real GPU run must report >0.
    pcie_n_samples_total = sum(r.get("pcie_n_samples", 0) or 0
                                for r in record_results)

    warning_resource_gpu_unavailable = False
    resource_rss_fail  = False
    resource_hbm_fail  = False
    resource_pcie_fail = False

    if args.no_resource_gate:
        print(f"Resource gates : DISABLED (--no-resource-gate)")
    else:
        # Host RSS sub-gate
        if resource_peak_rss_kb is None:
            print(f"Resource RSS   : SKIPPED (no peak-RSS captured)")
        else:
            resource_rss_fail = resource_peak_rss_kb > RESOURCE_HOST_RSS_KB_LIMIT
            flag = "  [FAIL: >8 GB]" if resource_rss_fail else "  [OK ≤8 GB]"
            print(f"Resource RSS   : peak={resource_peak_rss_kb/1024:.1f} MiB{flag}")
        # GPU HBM sub-gate
        if resource_peak_hbm_mib is None:
            warning_resource_gpu_unavailable = True
            print(f"Resource HBM   : SKIPPED (no nvidia-smi memory.used samples)")
        else:
            resource_hbm_fail = resource_peak_hbm_mib > RESOURCE_HBM_LIMIT_MIB
            pct = 100.0 * resource_peak_hbm_mib / (25.6 * 1024)
            flag = (f"  [FAIL: >{RESOURCE_HBM_LIMIT_MIB} MiB = 80% of 25.6 GB]"
                    if resource_hbm_fail else "  [OK ≤80% HBM]")
            print(f"Resource HBM   : peak={resource_peak_hbm_mib} MiB "
                  f"({pct:.1f}% of 25.6 GB){flag}")
        # PCIe sub-gate
        if resource_peak_pcie_mibps is None:
            warning_resource_gpu_unavailable = True
            print(f"Resource PCIe  : SKIPPED (no nvidia-smi dmon rxpci/txpci samples)")
        else:
            resource_pcie_fail = resource_peak_pcie_pct > RESOURCE_PCIE_FRACTION_LIM
            flag = (f"  [FAIL: >50% of {PCIE_LINK_MIBPS_REF} MiB/s]"
                    if resource_pcie_fail else "  [OK ≤50% PCIe]")
            print(f"Resource PCIe  : peak={resource_peak_pcie_mibps:.0f} MiB/s "
                  f"({resource_peak_pcie_pct*100:.1f}% of PCIe 5.0 x16 ref){flag}")

    # ──────────────────────────────────────────────────────────────────
    # Multi-cause correctness gate.  Print every flag that fired.
    # ──────────────────────────────────────────────────────────────────
    gate_flags = []
    if any_notfound:           gate_flags.append("FAIL-NOTFOUND")
    if within_rsd_fail:        gate_flags.append("FAIL-WITHIN-RSD")
    if suite_rel_se_fail:      gate_flags.append("FAIL-SUITE-REL-SE")
    if coverage_top_half_fail: gate_flags.append("FAIL-COVERAGE-TOP-HALF")
    if promotion_gate_fail:    gate_flags.append("FAIL-PROMOTION-GATE")
    if min_valid_records_fail: gate_flags.append("FAIL-MIN-VALID-RECORDS")
    if resource_rss_fail:      gate_flags.append("FAIL-RESOURCE-RSS")
    if resource_hbm_fail:      gate_flags.append("FAIL-RESOURCE-HBM")
    if resource_pcie_fail:     gate_flags.append("FAIL-RESOURCE-PCIE")
    correctness_gate = " | ".join(gate_flags) if gate_flags else "PASS"
    print(f"Correctness gate: {correctness_gate}")
    if coverage_top_half_skipped and not args.synthetic:
        print(f"  (note: top-half coverage gate did not run — provide --baseline-kpi to enable promotion)")
    if warning_resource_gpu_unavailable:
        print(f"  (warning_resource_gpu_unavailable: GPU sub-gates skipped)")
    print()

    os.makedirs(os.path.dirname(args.out) if os.path.dirname(args.out) else ".", exist_ok=True)
    out = {
        "meta": {
            "binary":           binary,
            "cal_json":         args.cal,
            "repeats":          M,
            "n_records":        len(record_results),
            "n_pass":           n_pass,
            "n_fail":           n_fail,
            "suite_geomean_ttr_s": suite_geomean,
            # W7.A: keep raw cross-record dispersion as informational, ungated.
            "cross_record_dispersion_pct": (
                cross_record_dispersion * 100.0
                if cross_record_dispersion is not None else None),
            "correctness_gate": correctness_gate,
            "gate_flags":       gate_flags,
            "any_parse_failure": any_parse_failure,
            # Within-record RSD gate (W4.A unchanged):
            "within_rsd_fail":  within_rsd_fail,
            "within_rsd_offenders": [
                {"suite_id": sid, "rsd_pct": pct}
                for sid, pct in within_rsd_offenders
            ],
            # W7.A — canonical suite-level relative std-error (bootstrap of geomean).
            "suite_rel_se_pct":  (suite_rel_se * 100.0) if suite_rel_se is not None else None,
            "suite_rel_se_threshold_pct": SUITE_REL_SE_THRESHOLD * 100.0,
            "suite_rel_se_fail": suite_rel_se_fail,
            "bootstrap_ci80_lo_s": bootstrap_lo80,
            "bootstrap_ci80_hi_s": bootstrap_hi80,
            "bootstrap_resamples": BOOTSTRAP_RESAMPLES,
            # W7.B — top-half coverage vs --baseline-kpi (canonical).
            "baseline_kpi":              args.baseline_kpi,
            "coverage_top_half_n":       coverage_top_half_n,
            "coverage_top_half_total":   coverage_top_half_total,
            "coverage_top_half_pct":     (coverage_top_half_pct * 100.0
                                          if coverage_top_half_pct is not None else None),
            "coverage_top_half_threshold_pct": COVERAGE_TOP_HALF_THRESHOLD * 100.0,
            "coverage_top_half_fail":    coverage_top_half_fail,
            "coverage_top_half_skipped": coverage_top_half_skipped,
            "coverage_top_half_detail":  coverage_top_half_detail,
            "baseline_kpi_meta":         baseline_meta,
            # W14a — promotion gate (appendix §12 #2: geomean speedup ≥1.176×).
            "promotion_gate_fail":          promotion_gate_fail,
            "promotion_gate_skipped":       promotion_gate_skipped,
            "promotion_gate_threshold":     PROMOTION_GATE_RATIO,
            "promotion_speedup":            promotion_speedup,
            "promotion_current_geomean_s":  promotion_current_geo,
            "promotion_baseline_geomean_s": promotion_baseline_geo,
            "promotion_n_paired_records":   promotion_n_paired,
            # W7.B (data-hygiene only) — minimum valid records.
            "min_valid_records":           min_valid_records,
            "min_valid_records_threshold": min_valid_records_thr,
            "min_valid_records_fail":      min_valid_records_fail,
            "coverage_substandard_suite":  coverage_substandard,
            # W7.C — resource sub-gates (host RSS + GPU HBM + PCIe).
            "resource_peak_rss_kb":        resource_peak_rss_kb,
            "resource_host_rss_limit_kb":  RESOURCE_HOST_RSS_KB_LIMIT,
            "resource_rss_fail":           resource_rss_fail,
            "resource_peak_hbm_mib":       resource_peak_hbm_mib,
            "resource_hbm_limit_mib":      RESOURCE_HBM_LIMIT_MIB,
            "resource_hbm_fail":           resource_hbm_fail,
            "resource_peak_pcie_mibps":    resource_peak_pcie_mibps,
            "resource_pcie_link_mibps_ref": PCIE_LINK_MIBPS_REF,
            "resource_pcie_fraction_limit": RESOURCE_PCIE_FRACTION_LIM,
            "resource_peak_pcie_pct":      (resource_peak_pcie_pct * 100.0
                                            if resource_peak_pcie_pct is not None else None),
            "resource_pcie_fail":          resource_pcie_fail,
            "resource_pcie_n_samples_total": pcie_n_samples_total,
            "resource_gate_disabled":      args.no_resource_gate,
            "warning_resource_gpu_unavailable": warning_resource_gpu_unavailable,
            # W14b — GPU device pollers were scoped to (and engine ran on).
            "gpu_device_idx":              gpu_idx,
            "gpu_device_idx_explicit":     gpu_idx_explicit,
            "synthetic":        args.synthetic,
            "generated_at":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
        "records": record_results,
    }
    with open(args.out, 'w') as f:
        json.dump(out, f, indent=2)
    print(f"Wrote {args.out}")

    # Exit nonzero if any gate fired.
    if (any_notfound or within_rsd_fail or suite_rel_se_fail or
            coverage_top_half_fail or promotion_gate_fail or
            min_valid_records_fail or
            resource_rss_fail or resource_hbm_fail or resource_pcie_fail):
        sys.exit(1)

if __name__ == "__main__":
    main()
