#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""
Usage: build synthetic fixtures that exercise each KPI gate.

Each fixture is a calibration-shape JSON with `synthetic_repeats` per record.
Run via:
    python3 tools/kpi_run.py --synthetic \
            --cal tools/kpi_fixtures/<name>.calibration.json \
            --out /tmp/<name>.out.json
"""
import json
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

def ok_rep(elapsed, base_dec, peak_rss_kb=None):
    rep = {
        "hits": 1,
        "elapsed_s": elapsed,
        "cand_per_s": 1.0e10,
        "useful_cand_per_s": 1.0e9,
        "gpu_util_pct": 100.0,
        "kpi_match_seen": 1,
        "kpi_early_exit": 1,
        "found_bases": [str(base_dec)],
        "kpi_target_base": str(base_dec),
    }
    if peak_rss_kb is not None:
        rep["peak_rss_kb"] = peak_rss_kb
    return rep

def make_record(suite_id, base_dec, elapsed_list, peak_rss_kb=None):
    return {
        "suite_id": suite_id,
        "k": 16,
        "pattern": "KT16_P0",
        "base_dec": str(base_dec),
        "bits": 66,
        "prefix_bits": 6,
        "prefix_str": "0b101001",
        "probe_elapsed_s": 20.0,
        "probe_prefix_bits": 7,
        "probe_tput_cand_per_s": 1,
        "probe_found": True,
        "target_s": 30.0,
        "synthetic_repeats": [ok_rep(e, base_dec, peak_rss_kb) for e in elapsed_list],
    }

def write(name, records, target_s=30.0):
    cal = {
        "meta": {
            "binary": "(synthetic)",
            "suite_tsv": f"tools/kpi_fixtures/{name}.calibration.json",
            "target_s": target_s,
            "n_records": len(records),
            "n_missing": 0,
            "generated_at": "2026-05-10T00:00:00Z",
            "fixture_purpose": name,
        },
        "records": records,
    }
    path = os.path.join(OUT_DIR, f"{name}.calibration.json")
    with open(path, "w") as f:
        json.dump(cal, f, indent=2)
    print(f"wrote {path}")

# ── W4.A: within-record RSD > 15%
# 1 record, 3 reps with elapsed {1.0, 1.5, 2.0}: mean=1.5, std=0.5, RSD≈33%.
write("fixture_a_within_rsd",
      [make_record("F1A", base_dec=999, elapsed_list=[1.0, 1.5, 2.0])])

# ── W4.B: bootstrap SE > 7%
# 2 valid records, internally stable, but 4× spread on the suite means the
# bootstrap of the geomean has very high relative SE.  (Suite-level rel_std
# also fires here: by construction the §5 variance gate and the bootstrap
# gate both scream when N=2 — appendix §5 specifies N≥20 for the 7% floor.)
write("fixture_b_bootstrap_se",
      [make_record("F2A", base_dec=101, elapsed_list=[1.0, 1.0, 1.0]),
       make_record("F2B", base_dec=102, elapsed_list=[4.0, 4.0, 4.0])])

# ── W4.C: coverage gate
# 5 records, 4 of them with all reps parse-fail, 1 fully valid.
# Threshold = min(20, 5) = 5; valid_count = 1 → coverage_fail.
def parse_fail_rec(suite_id, base_dec):
    return {
        "suite_id": suite_id,
        "k": 16, "pattern": "KT16_P0", "base_dec": str(base_dec),
        "bits": 66, "prefix_bits": 6, "prefix_str": "0b101001",
        "probe_elapsed_s": 20.0, "probe_prefix_bits": 7,
        "probe_tput_cand_per_s": 1, "probe_found": True, "target_s": 30.0,
        "synthetic_repeats": [
            {"parse_fail": "synthetic-timeout"},
            {"parse_fail": "synthetic-malformed"},
            {"parse_fail": "synthetic-rc1"},
        ],
    }
write("fixture_c_coverage", [
    parse_fail_rec("F3A", 201),
    parse_fail_rec("F3B", 202),
    parse_fail_rec("F3C", 203),
    parse_fail_rec("F3D", 204),
    make_record("F3E", base_dec=205, elapsed_list=[1.0, 1.0, 1.0]),
])

# ── W4.D: resource gate (host RSS > 8 GiB)
# 1 record, stable timing, peak_rss_kb = 10 * 1024 * 1024 = 10 GiB → > 8 GiB.
# Coverage threshold = 1; bootstrap N/A; within-RSD = 0%.  Only resource fires.
big_rss_kb = 10 * 1024 * 1024
write("fixture_d_resource",
      [make_record("F4A", base_dec=401, elapsed_list=[1.0, 1.0, 1.0],
                   peak_rss_kb=big_rss_kb)])

# ── PASS fixture: 22 records, stable internally, low suite spread.
# All gates should print OK and the run should exit 0.
import random
rng = random.Random(0xC0FFEE)
pass_records = []
for i in range(22):
    base = 9000 + i
    target_e = 1.00 + rng.uniform(-0.02, 0.02)         # within 2% suite spread
    reps = [target_e + rng.uniform(-0.01, 0.01) for _ in range(3)]  # ~1% within
    pass_records.append(make_record(f"P{i:02d}", base_dec=base,
                                    elapsed_list=[round(r, 3) for r in reps],
                                    peak_rss_kb=512 * 1024))   # 512 MiB RSS
write("fixture_pass", pass_records)

# ── W7.B: top-half coverage gate
# 10 candidate records all stable internally.  Candidate medians are 7×1.05
# (slightly slower than baseline) + 3×0.95 (slightly faster).  Baseline KPI
# JSON below has 10 records, each with median_ttr_s = 1.00.  Per-record
# top-half check (cand_median ≤ baseline_median) ⇒ only 3/10 = 30% top-half,
# which is < 70% threshold ⇒ coverage_top_half_fail fires.
# All other gates stay green by construction.
e_records = []
for i in range(10):
    base = 8000 + i
    target_med = 1.05 if i < 7 else 0.95
    e_records.append(make_record(f"E{i:02d}", base_dec=base,
                                 elapsed_list=[target_med, target_med, target_med]))
write("fixture_e_top_half", e_records)

# Companion synthetic baseline KPI JSON (output-shape, not calibration-shape).
# Match each candidate suite_id; baseline median_ttr_s = 1.00 for all.
baseline_records = []
for i in range(10):
    base = 8000 + i
    baseline_records.append({
        "suite_id":      f"E{i:02d}",
        "k":             16,
        "pattern":       "KT16_P0",
        "bits":          66,
        "prefix_str":    "0b101001",
        "prefix_bits":   6,
        "base_dec":      str(base),
        "median_ttr_s":  1.00,
        "rel_std":       0.0,
        "within_record_rsd_pct": 0.0,
        "notfound":      False,
        "repeats": [
            {"rep": 1, "elapsed_s": 1.00, "ttr_s": 1.00, "hits": 1,
             "status": "OK", "kpi_match_seen": 1, "kpi_early_exit": 1,
             "found_bases": [str(base)]},
        ],
    })
baseline_kpi = {
    "meta": {
        "binary":              "(synthetic baseline)",
        "cal_json":            "tools/kpi_fixtures/fixture_e_top_half.calibration.json",
        "repeats":             3,
        "n_records":           10,
        "n_pass":              10,
        "n_fail":              0,
        "suite_geomean_ttr_s": 1.00,
        "synthetic":           True,
        "generated_at":        "2026-05-10T00:00:00Z",
        "fixture_purpose":     "fixture_e_top_half_baseline",
    },
    "records": baseline_records,
}
baseline_path = os.path.join(OUT_DIR, "fixture_e_top_half.baseline.json")
with open(baseline_path, "w") as f:
    json.dump(baseline_kpi, f, indent=2)
print(f"wrote {baseline_path}")
