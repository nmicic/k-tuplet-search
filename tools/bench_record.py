#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""Per-commit performance snapshot for kt_gmp_v1.

Runs `--validate-known --k 17` on a fixed subset, captures per-record throughput
via the engine's `--bench-jsonl` emission, appends rows to bench/history.jsonl
keyed by short git SHA, and diffs against the previous SHA's row to flag
regressions.

Exit codes:
  0   no regression (or first run on this SHA, or info-only diff)
  1   regression detected (>20% cand_per_s drop on any record)
  2   harness error (build failed, parse failed, missing tool)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ENGINE = REPO_ROOT / "src" / "cpu" / "kt_search"
HISTORY = REPO_ROOT / "bench" / "history.jsonl"
TIMEOUT_SEC = 90
REGRESSION_PCT = 20.0
WARN_PCT = 10.0
KEY_FIELDS = ("k", "pattern", "base")
RATE_FIELD = "tput_cand_per_s"


def short_sha() -> str:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(REPO_ROOT),
            stderr=subprocess.DEVNULL,
        )
        return out.decode().strip() or "unknown"
    except Exception as exc:
        sys.stderr.write(f"warn: git rev-parse failed: {exc}; sha=unknown\n")
        return "unknown"


def ensure_built() -> int:
    cmd = ["make", "-C", str(REPO_ROOT / "src" / "cpu")]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write("ERROR: build failed\n")
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        return 2
    return 0


def run_bench(jsonl_path: Path) -> int:
    cmd = [
        "timeout", str(TIMEOUT_SEC),
        str(ENGINE),
        "--validate-known", "--k", "17",
        "--report-interval-sec", "0.5",
        "--bench-jsonl", str(jsonl_path),
    ]
    proc = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True)
    # Engine returns 0 on full pass; we tolerate non-zero only if some rows landed.
    if not jsonl_path.exists() or jsonl_path.stat().st_size == 0:
        sys.stderr.write("ERROR: engine produced no JSONL rows\n")
        sys.stderr.write(proc.stdout[-2000:])
        sys.stderr.write(proc.stderr[-2000:])
        return 2
    if proc.returncode not in (0, 124):  # 124 = timeout
        sys.stderr.write(f"warn: engine exit={proc.returncode} (continuing if rows exist)\n")
    return 0


def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    if not path.exists():
        return rows
    with path.open("r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                sys.stderr.write(f"warn: bad jsonl line in {path}: {exc}\n")
    return rows


def append_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")


def row_key(row: dict) -> tuple:
    return tuple(row.get(f) for f in KEY_FIELDS)


def diff_against_prior(prior: list[dict], new: list[dict], new_sha: str) -> int:
    """Return exit code (0 ok, 1 regression). Also prints lines per record."""
    # Build map of latest prior row per key. We include same-SHA priors so a
    # second run on the same SHA still diffs against the first (noise check).
    latest: dict[tuple, dict] = {}
    for r in prior:
        k = row_key(r)
        latest[k] = r  # last write wins; file is append-only so order is chronological

    worst = 0
    n_regress = 0
    n_warn = 0
    n_improve = 0
    n_ok = 0
    n_baseline = 0
    for r in new:
        k = row_key(r)
        prev = latest.get(k)
        new_rate = float(r.get(RATE_FIELD) or 0)
        label = f"k={r.get('k')} {r.get('pattern')} base={r.get('base')}"
        if prev is None or not prev.get(RATE_FIELD):
            print(f"BASELINE  {label}  cand_per_s={new_rate:.0f}")
            n_baseline += 1
            continue
        prev_rate = float(prev.get(RATE_FIELD))
        if prev_rate <= 0:
            print(f"BASELINE  {label}  cand_per_s={new_rate:.0f}")
            n_baseline += 1
            continue
        delta = (new_rate - prev_rate) / prev_rate * 100.0
        tag = "OK"
        if delta <= -REGRESSION_PCT:
            tag = "REGRESSION"
            n_regress += 1
            worst = max(worst, 1)
        elif delta <= -WARN_PCT:
            tag = "WARN"
            n_warn += 1
        elif delta >= WARN_PCT:
            tag = "IMPROVED"
            n_improve += 1
        else:
            n_ok += 1
        print(
            f"{tag:<10} {label}  prior={prev_rate:.0f} new={new_rate:.0f} "
            f"delta={delta:+.1f}% (vs sha={prev.get('sha','?')})"
        )

    print(
        f"\nsummary: {len(new)} rows  ok={n_ok} improved={n_improve} "
        f"warn={n_warn} regression={n_regress} baseline={n_baseline}"
    )
    return worst


def main() -> int:
    if not ENGINE.exists():
        # try to build first
        rc = ensure_built()
        if rc != 0:
            return rc
    rc = ensure_built()
    if rc != 0:
        return rc

    sha = short_sha()
    ts = datetime.now(timezone.utc).isoformat()

    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as tf:
        tmp_path = Path(tf.name)
    try:
        rc = run_bench(tmp_path)
        if rc != 0:
            return rc
        new_rows = read_jsonl(tmp_path)
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass

    if not new_rows:
        sys.stderr.write("ERROR: no new rows parsed\n")
        return 2

    for r in new_rows:
        r["sha"] = sha
        r["ts"] = ts

    prior = read_jsonl(HISTORY)
    append_jsonl(HISTORY, new_rows)

    print(f"\n# bench_record  sha={sha}  ts={ts}  rows={len(new_rows)}")
    return diff_against_prior(prior, new_rows, sha)


if __name__ == "__main__":
    sys.exit(main())
