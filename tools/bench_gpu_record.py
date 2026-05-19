#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""Per-commit GPU performance snapshot for kt_filter_v8.

Stages files to a remote GPU server, builds, runs
``--validate-known --k <K>`` (or a single-pattern --max-time bench), parses
the engine's --bench-jsonl output, attaches build/host/GPU metadata, and
appends rows to bench/gpu_history.jsonl. Diffs against the most recent
prior row with the same (k, pattern, base, flag_set, gpu_uuid) tuple.

This is the GPU sibling of tools/bench_record.py; same exit codes, same
threshold semantics. The flag_set field is what makes Phase-4 pattern A/B
tractable: each new flag combination is a separate row, queryable via
tools/bench_compare.py.

Exit codes:
  0   no regression (or first run on this combo, or info-only diff)
  1   regression detected (>20% cand_per_s drop on any matching row)
  2   harness error (build failed, ssh failed, parse failed)

Usage:
  bench_gpu_record.py --remote-host HOST [--remote-port PORT]
                      [--ssh-user USER]
                      [--validate-k K]                # default 17
                      [--pattern KT19_P0 --bits 100]  # alt: single pattern bench
                      [--max-time SEC]
                      [--flag-set --foo --bar]        # rest of argv = flags
                      [--no-remote]                   # local-only smoke
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HISTORY = REPO_ROOT / "bench" / "gpu_history.jsonl"
REGRESSION_PCT = 20.0
WARN_PCT = 10.0
RATE_FIELD = "tput_cand_per_s"
KEY_FIELDS = ("k", "pattern", "base", "flag_set_str", "gpu_uuid")

# Remote staging files. Keep the current public source layout intact because
# src/cuda/Makefile expects src/cuda plus src/common relative paths.
REMOTE_DIR = "/tmp/kt_gpu"
SOURCE_FILES = [
    "src/cuda/Makefile",
    "src/cuda/kt_filter_v8.cu",
    "src/cuda/kt_filter_v5_f1_baked.h",
    "src/cuda/kt_u128.cu",
    "src/cuda/kt_u128.h",
    "src/cuda/kt_wheel.c",
    "src/cuda/kt_wheel.h",
    "src/cuda/kt_lanes.c",
    "src/cuda/kt_lanes.h",
    "src/cuda/kt_checkpoint.c",
    "src/cuda/kt_checkpoint.h",
    "src/cuda/kt_novel_record.c",
    "src/cuda/kt_novel_record.h",
    "src/cuda/kt_records.c",
    "src/cuda/kt_records.h",
    "src/cuda/kt_cli.c",
    "src/cuda/kt_cli.h",
    "src/cuda/kt_signal.cu",
    "src/cuda/kt_signal.h",
    "src/cuda/kt_reporter.cu",
    "src/cuda/kt_reporter.h",
    "src/cuda/kt_tests.cu",
    "src/cuda/kt_tests.h",
    "src/common/ktuplet_pattern.c",
    "src/common/ktuplet_pattern.h",
    "src/common/kt_verify.c",
    "src/common/kt_verify.h",
    "src/common/kt_json_min.c",
    "src/common/kt_json_min.h",
    "known/records.json",
    "tools/records_manifest.tsv",
]


def short_sha() -> str:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(REPO_ROOT),
            stderr=subprocess.DEVNULL,
        )
        return out.decode().strip() or "unknown"
    except Exception:
        return "unknown"


def ssh_args(host: str, port: int, user: str) -> list[str]:
    return [
        "ssh", "-p", str(port),
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=no",
        f"{user}@{host}",
    ]


def scp_args(port: int) -> list[str]:
    return ["scp", "-P", str(port), "-o", "StrictHostKeyChecking=no"]


def stage_remote(host: str, port: int, user: str) -> int:
    """Reset and populate REMOTE_DIR with the public build tree."""
    sshc = ssh_args(host, port, user)
    rc = subprocess.run(sshc + [f"rm -rf {shlex.quote(REMOTE_DIR)}"]).returncode
    if rc != 0:
        return rc
    dirs = sorted({str(Path(rel).parent) for rel in SOURCE_FILES})
    mkdirs = " ".join(shlex.quote(f"{REMOTE_DIR}/{d}") for d in dirs)
    rc = subprocess.run(sshc + [f"mkdir -p {mkdirs}"]).returncode
    if rc != 0:
        return rc
    for rel in SOURCE_FILES:
        src = REPO_ROOT / rel
        if not src.exists():
            sys.stderr.write(f"ERROR: source missing: {rel}\n")
            return 2
        dst = f"{user}@{host}:{REMOTE_DIR}/{rel}"
        rc = subprocess.run(scp_args(port) + [str(src), dst]).returncode
        if rc != 0:
            return rc
    return 0


def remote_build(host: str, port: int, user: str) -> int:
    sshc = ssh_args(host, port, user)
    sha = shlex.quote(short_sha())
    rc = subprocess.run(
        sshc + [f"cd {shlex.quote(REMOTE_DIR)}/src/cuda && "
                f"make KT_BUILD_SHA={sha} kt_filter_v8"]
    ).returncode
    return rc


def remote_run_validate(host: str, port: int, user: str, k: int,
                        timeout_s: int, extra_flags: list[str]) -> tuple[int, str]:
    sshc = ssh_args(host, port, user)
    flag_str = " ".join(shlex.quote(f) for f in extra_flags)
    remote_jsonl = f"{REMOTE_DIR}/src/cuda/run.jsonl"
    cmd = (f"cd {shlex.quote(REMOTE_DIR)}/src/cuda && "
           f"rm -f {shlex.quote(remote_jsonl)} && "
           f"timeout {int(timeout_s)} ./kt_filter_v8 --validate-known --k {int(k)} "
           f"--bench-jsonl {shlex.quote(remote_jsonl)} --full-quiet {flag_str}")
    proc = subprocess.run(sshc + [cmd], capture_output=True, text=True)
    return proc.returncode, remote_jsonl


def remote_run_pattern(host: str, port: int, user: str, pattern: str, bits: int,
                       max_time: float, extra_flags: list[str]
                       ) -> tuple[int, str]:
    """Single-pattern bench with --max-time. Emits one synthetic JSONL row.
    The kt_filter binary's --bench-jsonl path only emits rows in
    --validate-known mode, so for an ad-hoc bench we synthesize a row
    from stdout fields. Captured here for the B1 anchor case."""
    sshc = ssh_args(host, port, user)
    flag_str = " ".join(shlex.quote(f) for f in extra_flags)
    cmd = (f"cd {shlex.quote(REMOTE_DIR)}/src/cuda && "
           f"timeout {int(max_time) + 30} "
           f"./kt_filter_v8 --pattern {shlex.quote(pattern)} --bits {int(bits)} "
           f"--max-time {float(max_time)} --full-quiet {flag_str}")
    proc = subprocess.run(sshc + [cmd], capture_output=True, text=True)
    return proc.returncode, proc.stdout + "\n" + proc.stderr


def remote_fetch_jsonl(host: str, port: int, user: str, remote_path: str
                       ) -> list[dict]:
    """scp remote JSONL to local tempfile, parse, return rows."""
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as tf:
        local = Path(tf.name)
    try:
        rc = subprocess.run(
            scp_args(port) + [
                f"{user}@{host}:{remote_path}",
                str(local),
            ],
            capture_output=True,
        ).returncode
        if rc != 0:
            return []
        rows = []
        with local.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return rows
    finally:
        try:
            local.unlink()
        except FileNotFoundError:
            pass


def remote_gpu_meta(host: str, port: int, user: str) -> dict:
    """Pull a few metadata fields via ssh: nvidia-smi UUID, driver, CUDA."""
    sshc = ssh_args(host, port, user)
    out = {}
    proc = subprocess.run(
        sshc + [
            "nvidia-smi --query-gpu=uuid,name,driver_version --format=csv,noheader"
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        first = proc.stdout.strip().splitlines()[0]
        parts = [p.strip() for p in first.split(",")]
        if len(parts) >= 1:
            out["gpu_uuid"] = parts[0]
        if len(parts) >= 2:
            out["gpu_name"] = parts[1]
        if len(parts) >= 3:
            out["driver_version"] = parts[2]
    proc = subprocess.run(
        sshc + ["/usr/local/cuda-13.2/bin/nvcc --version"],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        for line in proc.stdout.splitlines():
            if "release" in line:
                out["cuda_version"] = line.strip()
                break
    return out


def append_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    rows = []
    if not path.exists():
        return rows
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def row_key(row: dict) -> tuple:
    return tuple(row.get(f, "") for f in KEY_FIELDS)


def diff_against_prior(prior: list[dict], new: list[dict]) -> int:
    latest: dict[tuple, dict] = {}
    for r in prior:
        latest[row_key(r)] = r
    worst = 0
    n_regress = n_warn = n_improve = n_ok = n_baseline = 0
    for r in new:
        k = row_key(r)
        prev = latest.get(k)
        new_rate = float(r.get(RATE_FIELD) or 0)
        label = (f"k={r.get('k')} {r.get('pattern')} bits={r.get('bits')} "
                 f"flags={r.get('flag_set_str') or 'base'}")
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
        print(f"{tag:<10} {label}  prior={prev_rate:.0f} new={new_rate:.0f} "
              f"delta={delta:+.1f}% (vs sha={prev.get('git_sha','?')})")
    print(f"\nsummary: {len(new)} rows  ok={n_ok} improved={n_improve} "
          f"warn={n_warn} regression={n_regress} baseline={n_baseline}")
    return worst


def parse_args(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--remote-host", default=None)
    p.add_argument("--remote-port", type=int, default=1166)
    p.add_argument("--ssh-user", default="root")
    p.add_argument("--no-remote", action="store_true",
                   help="local smoke build only (no GPU run)")
    p.add_argument("--validate-k", type=int, default=17)
    p.add_argument("--pattern", default=None)
    p.add_argument("--bits", type=int, default=None)
    p.add_argument("--max-time", type=float, default=30.0)
    p.add_argument("--timeout-s", type=int, default=900)
    p.add_argument("--flag-set", nargs=argparse.REMAINDER,
                   help="all remaining argv = engine flags (e.g. --no-stage-fermat)")
    args, leftover = p.parse_known_args(argv)
    extra = list(args.flag_set or []) + list(leftover)
    return args, extra


def main(argv: list[str]) -> int:
    args, extra = parse_args(argv)

    if not args.remote_host and not args.no_remote:
        sys.stderr.write(
            "ERROR: --remote-host required (or pass --no-remote for local-only smoke)\n")
        return 2

    if args.no_remote:
        # Just probe the local build setup. The full bench needs a GPU we don't
        # have on the principal box; emit a no-gpu warning row.
        rc = subprocess.run(
            ["make", "-C", str(REPO_ROOT / "src" / "cuda")],
            capture_output=True, text=True,
        ).returncode
        if rc != 0:
            sys.stderr.write("WARN: local make in src/cuda failed (no nvcc?)\n")
        ts = datetime.now(timezone.utc).isoformat()
        row = {
            "engine": "gpu",
            "git_sha": short_sha(),
            "ts_utc": ts,
            "host": socket.gethostname(),
            "no_gpu": True,
            "note": "local smoke; bench requires --remote-host",
        }
        append_jsonl(HISTORY, [row])
        print(f"# bench_gpu_record (no-remote)  ts={ts}")
        return 0

    print(f"# bench_gpu_record  remote={args.remote_host}:{args.remote_port}  "
          f"flags={extra or '(base)'}", flush=True)

    if stage_remote(args.remote_host, args.remote_port, args.ssh_user) != 0:
        sys.stderr.write("ERROR: stage_remote failed\n")
        return 2
    if remote_build(args.remote_host, args.remote_port, args.ssh_user) != 0:
        sys.stderr.write("ERROR: remote build failed\n")
        return 2

    meta = remote_gpu_meta(args.remote_host, args.remote_port, args.ssh_user)
    sha = short_sha()
    ts = datetime.now(timezone.utc).isoformat()
    flag_set_str = " ".join(extra) if extra else ""

    new_rows: list[dict] = []

    if args.pattern and args.bits:
        # Single-pattern bench. The engine's --bench-jsonl emits rows only in
        # --validate-known mode, so we run --max-time and synthesize a row.
        rc, output = remote_run_pattern(
            args.remote_host, args.remote_port, args.ssh_user,
            args.pattern, args.bits, args.max_time, extra,
        )
        if rc not in (0, 124):
            sys.stderr.write(f"ERROR: remote run rc={rc}\n{output[-2000:]}\n")
            return 2
        # Parse the "=== final: cand=... cand/s=... ===" line.
        cand = surv = hits = 0
        cand_per_s = 0.0
        elapsed = 0.0
        stages_active = 0
        gpu_util_pct = 0.0
        gpu_util_pct_min = 0.0
        prove_to_kernel_ratio = 0.0
        total_kernel_ms = 0.0
        total_prove_ms = 0.0
        wall_time_ms = 0.0
        bench_schema_version = 1     # default for missing field (pre-3f.1)
        for line in output.splitlines():
            if "=== final:" in line:
                # Brittle but predictable; engine's own format.
                # cand=... surv=... hits=... elapsed=...s cand/s=...
                tokens = line.replace("cand/s", "candrate").split()
                kv = {}
                for t in tokens:
                    if "=" in t:
                        k, v = t.split("=", 1)
                        kv[k] = v.rstrip("s,")
                try:
                    cand = int(kv.get("cand", 0))
                    surv = int(kv.get("surv", 0))
                    hits = int(kv.get("hits", 0))
                    elapsed = float(str(kv.get("elapsed", "0")).rstrip("s"))
                    cand_per_s = float(kv.get("candrate", 0))
                    sa_raw = kv.get("[stages", "0x0").rstrip("]")
                    if sa_raw.startswith("0x") or sa_raw.startswith("0X"):
                        sa_raw = sa_raw[2:]
                    stages_active = int(sa_raw, 16) if sa_raw else 0
                    gpu_util_pct = float(kv.get("gpu_util_pct", 0))
                    gpu_util_pct_min = float(kv.get("gpu_util_pct_min", 0))
                    prove_to_kernel_ratio = float(kv.get("prove_to_kernel_ratio", 0))
                    total_kernel_ms = float(kv.get("total_kernel_ms", 0))
                    total_prove_ms = float(kv.get("total_prove_ms", 0))
                    wall_time_ms = float(kv.get("wall_time_ms", 0))
                    bench_schema_version = int(kv.get(
                        "bench_schema_version", bench_schema_version))
                except (ValueError, KeyError):
                    pass
                break
        new_rows.append({
            "engine": "gpu",
            "k": None,
            "pattern": args.pattern,
            "base": None,
            "bits": args.bits,
            "elapsed_s": elapsed,
            "cand": cand,
            "surv": surv,
            "verified": 0,
            "found": hits,
            RATE_FIELD: cand_per_s,
            "ts_utc": ts,
            "host": socket.gethostname(),
            "git_sha": sha,
            "flag_set_str": flag_set_str,
            "stages_active": stages_active,
            "gpu_util_pct": gpu_util_pct,
            "gpu_util_pct_min": gpu_util_pct_min,
            "prove_to_kernel_ratio": prove_to_kernel_ratio,
            "total_kernel_ms": total_kernel_ms,
            "total_prove_ms": total_prove_ms,
            "wall_time_ms": wall_time_ms,
            "bench_schema_version": bench_schema_version,
            **meta,
        })
    else:
        rc, remote_jsonl = remote_run_validate(
            args.remote_host, args.remote_port, args.ssh_user,
            args.validate_k, args.timeout_s, extra,
        )
        if rc not in (0, 1, 124):
            sys.stderr.write(f"ERROR: remote run rc={rc}\n")
            return 2
        rows = remote_fetch_jsonl(
            args.remote_host, args.remote_port, args.ssh_user, remote_jsonl,
        )
        if not rows:
            sys.stderr.write("ERROR: no JSONL rows produced\n")
            return 2
        for r in rows:
            r["ts_utc"] = ts
            r["git_sha"] = sha
            r["host"] = socket.gethostname()
            r["flag_set_str"] = flag_set_str
            for k, v in meta.items():
                r[k] = v
            new_rows.append(r)

    prior = read_jsonl(HISTORY)
    append_jsonl(HISTORY, new_rows)
    print(f"# appended {len(new_rows)} row(s) to {HISTORY}\n", flush=True)
    return diff_against_prior(prior, new_rows)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
