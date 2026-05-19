#!/usr/bin/env python3
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
"""Read-only query tool over CPU + GPU bench history.

Reads bench/history.jsonl (CPU) and bench/gpu_history.jsonl (GPU). Filters
by pattern, bits, engine, flag_set, or git_sha range. Emits plain text;
stdlib only.

CLI:
  bench_compare.py --pattern KT19_P0 --bits 100
  bench_compare.py --pattern KT19_P0 --bits 100 --engine gpu
  bench_compare.py --flag-set base
  bench_compare.py --flag-set --no-stage-fermat
  bench_compare.py --diff <sha-a>:<sha-b>
  bench_compare.py --leaderboard
  bench_compare.py --diff S0:S1 --metric useful
  bench_compare.py --leaderboard --metric tput
  bench_compare.py --diff S0:S1 --metric ttr   # exits nonzero until S2.5
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CPU_HISTORY = REPO_ROOT / "bench" / "history.jsonl"
GPU_HISTORY = REPO_ROOT / "bench" / "gpu_history.jsonl"
RATE_FIELD = "tput_cand_per_s"
SAT_THRESHOLD = 95.0     # gpu_util_pct_min >= 95 to be "saturated"
LATEST_SCHEMA = 4         # v8-Sobs-B: search-position obs fields (mode/seed/coverage/...)
# Schemas 3 and 4 are forward-compatible for tput/useful comparisons; 4 adds
# observability fields (`mode`, `seed`, `anchors_visited`, `unique_tiles_visited`,
# `coverage_ratio`, `revisited_anchors`, `runner_cell_id`).


def is_saturated(row: dict) -> bool:
    """GPU rows need gpu_util_pct_min >= SAT_THRESHOLD (95%) to count as
    directly comparable. Pre-3f rows lack the field; treat as non-saturated.
    CPU rows are always 'saturated' (CPU has no analogous gate)."""
    if (row.get("engine") or "") != "gpu":
        return True
    v = row.get("gpu_util_pct_min")
    if v is None:
        return False
    try:
        return float(v) >= SAT_THRESHOLD
    except (TypeError, ValueError):
        return False


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


def load_all(engine: str | None) -> list[dict]:
    rows = []
    if engine in (None, "cpu"):
        for r in read_jsonl(CPU_HISTORY):
            r.setdefault("engine", "cpu")
            r.setdefault("flag_set_str", "")
            rows.append(r)
    if engine in (None, "gpu"):
        for r in read_jsonl(GPU_HISTORY):
            r.setdefault("engine", "gpu")
            r.setdefault("flag_set_str", "")
            rows.append(r)
    return rows


def schema_version(row: dict) -> int:
    """Returns the bench-row schema version. Pre-3f.1 rows lack the field
    and default to 1. Post-3f.1 rows write 2 (real per-100ms-tick
    gpu_util_pct_min). v8-S1 rows write 3 (useful_cand_per_s alias added)."""
    v = row.get("bench_schema_version")
    if v is None:
        return 1
    try:
        return int(v)
    except (TypeError, ValueError):
        return 1


def get_rate(row: dict, metric: str) -> tuple[float | None, str]:
    """Return (rate_value, alias_name) for the given metric.

    metric='tput'   -> tput_cand_per_s
    metric='useful' -> useful_cand_per_s if present, else tput_useful_cand_per_s
    metric='ttr'    -> caller should have handled this before calling get_rate
    """
    if metric == "tput":
        v = row.get("tput_cand_per_s")
        return (float(v) if v is not None else None, "tput_cand_per_s")
    if metric == "useful":
        if "useful_cand_per_s" in row:
            v = row["useful_cand_per_s"]
            return (float(v) if v is not None else None, "useful_cand_per_s")
        if "tput_useful_cand_per_s" in row:
            v = row["tput_useful_cand_per_s"]
            return (float(v) if v is not None else None, "tput_useful_cand_per_s [compat]")
        return (None, "useful_cand_per_s [missing]")
    # fallback
    v = row.get(RATE_FIELD)
    return (float(v) if v is not None else None, RATE_FIELD)


def matches(row: dict, args: argparse.Namespace) -> bool:
    if args.pattern and row.get("pattern") != args.pattern:
        return False
    if args.bits is not None and row.get("bits") != args.bits:
        return False
    if args.k is not None and row.get("k") != args.k:
        return False
    if args.flag_set is not None:
        want = (args.flag_set or "").strip()
        if want == "base":
            want = ""
        if (row.get("flag_set_str") or "") != want:
            return False
    if args.schema_version is not None and schema_version(row) != args.schema_version:
        return False
    return True


def fmt_row(row: dict, metric: str = "tput") -> str:
    rate, alias = get_rate(row, metric)
    rate_s = f"{rate:.0f}" if rate is not None else "-"
    util = row.get("gpu_util_pct_min")
    if (row.get("engine") or "") == "gpu":
        if util is None:
            util_s = "util=-     "
        else:
            try:
                util_s = f"util={float(util):>5.1f}%"
            except (TypeError, ValueError):
                util_s = "util=?     "
        if not is_saturated(row):
            util_s += "*"     # non-saturated marker
        else:
            util_s += " "
    else:
        util_s = "             "
    return (
        f"{row.get('engine','?'):<3}  "
        f"sha={row.get('git_sha') or row.get('sha') or '-':<8}  "
        f"k={row.get('k') or '-':<3} {row.get('pattern') or '-':<10}  "
        f"bits={row.get('bits') or '-':<4}  "
        f"flags={row.get('flag_set_str') or 'base':<32}  "
        f"{alias}={rate_s:<14}  "
        f"{util_s}  "
        f"elapsed={row.get('elapsed_s', 0):.2f}s  "
        f"ts={row.get('ts_utc') or row.get('ts') or ''}"
    )


def cmd_filter(args: argparse.Namespace, rows: list[dict]) -> int:
    metric = getattr(args, "metric", "tput")
    show_cov = getattr(args, "show_coverage", False)
    matched = [r for r in rows if matches(r, args)]
    if not matched:
        print("(no matching rows)")
        return 0
    print(f"# {len(matched)} matching row(s)")
    for r in matched:
        line = fmt_row(r, metric)
        if show_cov:
            sv = schema_version(r)
            if sv >= 4:
                cr = r.get("coverage_ratio")
                ra = r.get("revisited_anchors")
                cr_s = f"{float(cr):.4f}" if cr is not None else "-"
                ra_s = f"{int(ra)}" if ra is not None else "-"
                line += f"  cov={cr_s} rev={ra_s}"
            else:
                line += "  cov=- rev=-"
        print(line)
    return 0


def cmd_diff(args: argparse.Namespace, rows: list[dict]) -> int:
    metric = getattr(args, "metric", "tput")
    if not args.diff or ":" not in args.diff:
        sys.stderr.write("ERROR: --diff expects <sha-a>:<sha-b>\n")
        return 2
    a, b = args.diff.split(":", 1)

    def schema_warn(ra: dict | None, rb: dict | None) -> str:
        if not ra or not rb:
            return ""
        sa = schema_version(ra)
        sb = schema_version(rb)
        if sa != sb:
            return f"  [WARN: cross-schema {sa}->{sb}]"
        return ""

    def by_sha(s: str) -> dict[tuple, dict]:
        out: dict[tuple, dict] = {}
        for r in rows:
            sha = r.get("git_sha") or r.get("sha")
            if sha != s:
                continue
            if not matches(r, args):
                continue
            key = (r.get("engine"), r.get("k"), r.get("pattern"),
                   r.get("base"), r.get("bits"), r.get("flag_set_str") or "")
            out[key] = r
        return out

    A = by_sha(a)
    B = by_sha(b)
    keys = sorted(set(A) | set(B), key=lambda x: tuple("" if v is None else v for v in x))
    if not keys:
        print(f"(no rows for sha={a} or sha={b})")
        return 0
    print(f"# diff {a} -> {b}  [metric={metric}]")
    for k in keys:
        ra = A.get(k)
        rb = B.get(k)
        ra_rate, ra_alias = get_rate(ra, metric) if ra else (None, "")
        rb_rate, rb_alias = get_rate(rb, metric) if rb else (None, "")
        ra_sat = is_saturated(ra) if ra else True
        rb_sat = is_saturated(rb) if rb else True
        nonsat_tag = "" if (ra_sat and rb_sat) else "  [WARN: non-saturated]"
        schema_tag = schema_warn(ra, rb)
        alias_tag = f"  [alias:{ra_alias}]" if ra_alias != rb_alias and ra and rb else ""
        if ra and rb and ra_rate and rb_rate:
            delta = (rb_rate - ra_rate) / ra_rate * 100.0
            print(
                f"  {k}  a={ra_rate:.0f} b={rb_rate:.0f}  delta={delta:+.1f}%{nonsat_tag}{schema_tag}{alias_tag}"
            )
        elif rb and not ra:
            print(f"  {k}  NEW  b={rb_rate}{nonsat_tag}")
        elif ra and not rb:
            print(f"  {k}  GONE a={ra_rate}{nonsat_tag}")
    return 0


def cmd_leaderboard(args: argparse.Namespace, rows: list[dict]) -> int:
    metric = getattr(args, "metric", "tput")
    # Phase 3f.1: --leaderboard defaults to schema-version>=LATEST_SCHEMA
    # for GPU rows. v8-S1 bumped LATEST_SCHEMA to 3.
    matched = [r for r in rows if matches(r, args)]
    if not args.include_old_schema and args.schema_version is None:
        matched = [r for r in matched
                   if (r.get("engine") or "") != "gpu"
                   or schema_version(r) >= LATEST_SCHEMA]
    # Filter to rows that have a non-None rate for the chosen metric.
    matched = [r for r in matched if get_rate(r, metric)[0] is not None]
    if not matched:
        print(f"(no rows with {metric} metric)")
        return 0
    sat_rows = [r for r in matched if is_saturated(r)]
    nonsat_rows = [r for r in matched if not is_saturated(r)]

    # Group by (engine, pattern, bits) and pick the best per group.
    def best_per_group(pool: list[dict]) -> dict:
        best: dict[tuple, dict] = {}
        for r in pool:
            key = (r.get("engine"), r.get("pattern"), r.get("bits"))
            rv, _ = get_rate(r, metric)
            if rv is None:
                continue
            if key not in best:
                best[key] = r
            else:
                bv, _ = get_rate(best[key], metric)
                if bv is None or rv > bv:
                    best[key] = r
        return best

    primary_pool = sat_rows if not args.include_nonsat else matched
    best = best_per_group(primary_pool)
    ordered = sorted(best.values(),
                     key=lambda r: get_rate(r, metric)[0] or 0.0,
                     reverse=True)
    top = ordered[:args.top or 20]
    label = ("(non-saturated rows excluded; pass --include-nonsat to include them)"
             if not args.include_nonsat else "(saturated + non-saturated)")
    print(f"# leaderboard top-{len(top)} {label} "
          f"sat_rows={len(sat_rows)} nonsat_rows={len(nonsat_rows)} "
          f"groups={len(best)}")
    for r in top:
        print(fmt_row(r, metric))

    # Always report non-saturated separately when default-excluded.
    if not args.include_nonsat and nonsat_rows:
        ns_best = best_per_group(nonsat_rows)
        ns_ordered = sorted(ns_best.values(),
                            key=lambda r: get_rate(r, metric)[0] or 0.0,
                            reverse=True)
        print(f"\n# non-saturated; not directly comparable "
              f"({len(nonsat_rows)} rows, {len(ns_best)} groups)")
        for r in ns_ordered[:args.top or 20]:
            print(fmt_row(r, metric))
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--pattern", default=None)
    p.add_argument("--bits", type=int, default=None)
    p.add_argument("--k", type=int, default=None)
    p.add_argument("--engine", choices=["cpu", "gpu"], default=None)
    p.add_argument("--flag-set", default=None,
                   help="empty/base for B1 default; otherwise the flag string "
                        "(quote it: --flag-set '--no-stage-fermat')")
    p.add_argument("--diff", default=None)
    p.add_argument("--leaderboard", action="store_true")
    p.add_argument("--top", type=int, default=20)
    p.add_argument("--include-nonsat", action="store_true",
                   help="Include rows with gpu_util_pct_min < 95 in the "
                        "leaderboard primary section (default: separate them).")
    p.add_argument("--schema-version", type=int, default=None,
                   help="Filter to rows with this bench_schema_version. "
                        "Pre-3f.1 rows are version 1; post-3f.1 are version 2; "
                        "v8-S1 rows are version 3.")
    p.add_argument("--include-old-schema", action="store_true",
                   help=f"--leaderboard otherwise restricts GPU rows to "
                        f"schema_version >= {LATEST_SCHEMA}; pass this flag "
                        f"to include older rows.")
    p.add_argument("--metric", choices=["tput", "useful", "ttr"], default="useful",
                   help="Metric to display and compare. "
                        "'tput' = raw tput_cand_per_s (audit only). "
                        "'useful' = useful_cand_per_s or tput_useful_cand_per_s (monitoring proxy). "
                        "'ttr' = Time To Record (production gate; requires S2.5 KPI suite). "
                        "Default: useful.")
    p.add_argument("--show-coverage", action="store_true",
                   help="Sobs-B (schema 4+): also print coverage_ratio + "
                        "revisited_anchors per row.  Rows from older schemas show '-'.")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    metric = args.metric

    # TTR gate: S2.5 KPI harness not yet built; refuse comparison.
    if metric == "ttr":
        sys.stderr.write(
            "ERROR: --metric ttr requires TTR rows from the S2.5 KPI harness "
            "(tools/kpi_run.py). No TTR rows exist yet; run S2.5 first.\n"
        )
        return 1

    # Non-KPI warning for tput/useful.
    sys.stderr.write(
        f"[NOT-KPI] reporting {metric} — production gate is TTR "
        f"(see general_kpi_exit_criteria_appendix.md)\n"
    )

    rows = load_all(args.engine)
    if args.diff:
        return cmd_diff(args, rows)
    if args.leaderboard:
        return cmd_leaderboard(args, rows)
    return cmd_filter(args, rows)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
