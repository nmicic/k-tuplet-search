#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
Gate-of-the-gate self-test for the W14a KPI promotion gate
(appendix §12 #2 line 231).

Three scenarios run kpi_run.py in --synthetic mode against the existing
fixture_pass.calibration.json fixture and assert the exit code matches
the appendix-binding threshold (0.85× current ≤ baseline geomean
≡ ≥1.176× speedup):

  1. Self-comparison    (current == baseline)               → EXIT 1, FAIL-PROMOTION-GATE
  2. Cross 1.5× slower  (current ≤ baseline / 1.5)          → EXIT 0
  3. Cross 1.10× slower (insufficient, only +10%, <17.6%)   → EXIT 1, FAIL-PROMOTION-GATE

The third scenario is the operator-relevant boundary case (a small,
non-zero, but sub-threshold improvement must NOT promote).

Run via: `python3 tools/test_kpi_promotion_gate.py`.
Exits 0 on success, 1 on any failure.
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KPI = os.path.join(ROOT, "tools", "kpi_run.py")
CAL = os.path.join(ROOT, "tools", "kpi_fixtures", "fixture_pass.calibration.json")


def run_kpi(out_path, baseline_path=None):
    cmd = [sys.executable, KPI,
           "--synthetic",
           "--cal", CAL,
           "--out", out_path,
           "--no-resource-gate"]
    if baseline_path:
        cmd += ["--baseline-kpi", baseline_path]
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    return p.returncode, p.stdout + p.stderr


def make_scaled_baseline(src_kpi_path, dst_path, scale):
    with open(src_kpi_path) as f:
        d = json.load(f)
    for r in d.get("records", []):
        if r.get("median_ttr_s") is not None:
            r["median_ttr_s"] = round(r["median_ttr_s"] * scale, 4)
        for rep in r.get("repeats", []):
            for k in ("elapsed_s", "ttr_s"):
                if rep.get(k) is not None:
                    rep[k] = round(rep[k] * scale, 4)
    d.setdefault("meta", {})["fixture_purpose"] = (
        f"scaled_baseline_x{scale:g}")
    with open(dst_path, "w") as f:
        json.dump(d, f, indent=2)


def assert_eq(actual, expected, msg):
    if actual != expected:
        print(f"FAIL {msg}: got {actual!r}, expected {expected!r}")
        return False
    return True


def assert_in(needle, haystack, msg):
    if needle not in haystack:
        print(f"FAIL {msg}: substring {needle!r} not found")
        return False
    return True


def main():
    failures = 0
    with tempfile.TemporaryDirectory() as td:
        baseline = os.path.join(td, "fixture_pass.out.json")
        # Step 0 — produce a baseline KPI JSON (no --baseline-kpi).
        rc, out = run_kpi(baseline)
        if not assert_eq(rc, 0, "baseline-only run"):
            print(out); failures += 1
            return 1

        # Step 1 — self-comparison: must FAIL the promotion gate.
        self_out = os.path.join(td, "self.out.json")
        rc, out = run_kpi(self_out, baseline_path=baseline)
        if not assert_eq(rc, 1, "self-compare exit code"): failures += 1
        if not assert_in("Promotion gate", out, "self-compare names gate"): failures += 1
        if not assert_in("FAIL-PROMOTION-GATE", out, "self-compare names FAIL flag"): failures += 1
        if not assert_in("speedup=1.000×", out, "self-compare speedup is 1.000×"): failures += 1
        # JSON meta records the fail bit too.
        with open(self_out) as f:
            self_meta = json.load(f).get("meta", {})
        if not assert_eq(self_meta.get("promotion_gate_fail"), True,
                         "self-compare meta.promotion_gate_fail"):
            failures += 1
        if not assert_eq(self_meta.get("promotion_gate_skipped"), False,
                         "self-compare meta.promotion_gate_skipped"):
            failures += 1

        # Step 2 — cross-compare with 1.5× slower synthetic baseline: must PASS.
        slow15 = os.path.join(td, "baseline_x1.5.json")
        make_scaled_baseline(baseline, slow15, 1.5)
        cross_out = os.path.join(td, "cross_x1.5.out.json")
        rc, out = run_kpi(cross_out, baseline_path=slow15)
        if not assert_eq(rc, 0, "cross 1.5× exit code"): failures += 1
        if not assert_in("speedup=1.500×", out, "cross 1.5× speedup display"): failures += 1
        if not assert_in("[PASS]", out, "cross 1.5× promotion PASS"): failures += 1
        with open(cross_out) as f:
            cross_meta = json.load(f).get("meta", {})
        if not assert_eq(cross_meta.get("promotion_gate_fail"), False,
                         "cross 1.5× meta.promotion_gate_fail"):
            failures += 1

        # Step 3 — boundary: 1.10× slower baseline (only +10%, sub-threshold).
        slow11 = os.path.join(td, "baseline_x1.10.json")
        make_scaled_baseline(baseline, slow11, 1.10)
        boundary_out = os.path.join(td, "boundary_x1.10.out.json")
        rc, out = run_kpi(boundary_out, baseline_path=slow11)
        if not assert_eq(rc, 1, "boundary 1.10× exit code"): failures += 1
        if not assert_in("FAIL-PROMOTION-GATE", out, "boundary 1.10× FAIL flag"): failures += 1

        # Step 4 — no --baseline-kpi: gate must SKIP (not fail).
        skip_out = os.path.join(td, "skip.out.json")
        rc, out = run_kpi(skip_out)
        if not assert_eq(rc, 0, "skip (no baseline) exit code"): failures += 1
        if not assert_in("Promotion gate : SKIPPED", out, "skip names SKIPPED"): failures += 1
        with open(skip_out) as f:
            skip_meta = json.load(f).get("meta", {})
        if not assert_eq(skip_meta.get("promotion_gate_skipped"), True,
                         "skip meta.promotion_gate_skipped"):
            failures += 1

    if failures:
        print(f"\n{failures} assertion(s) failed.")
        return 1
    print("\ntest_kpi_promotion_gate: 4 scenarios × all assertions PASS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
