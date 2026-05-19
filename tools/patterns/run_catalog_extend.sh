#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
#
# run_catalog_extend.sh — extend tools/patterns/catalog/ by running
# pattern_enum for a range of k values at narrow diameter H(k).
#
# Typical use on a fast box:
#   ./tools/patterns/run_catalog_extend.sh --from 28 --to 32
#   ./tools/patterns/run_catalog_extend.sh --from 28 --to 36 --commit --push
#
# Behavior:
#   - For each k in [from, to], runs pattern_enum at H(k) and writes
#     tools/patterns/catalog/k<NN>_d<DDD>.json (zero-padded).
#   - Skips existing files unless --force.
#   - Optionally regenerates src/common/ktuplet_pattern.{h,c}, commits, pushes.
#
# Notes:
#   - H(k) is hardcoded for k=2..35 (OEIS A008407 + Luhn pzktupel.de).
#     For k beyond 35, pass --diameter K=D to override (e.g. --diameter 36=162).
#   - pattern_enum at k>=30 is research territory: hours to days. Run with
#     `nohup` or `tmux` if the SSH session might drop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENUM_BIN="$SCRIPT_DIR/pattern_enum"
CATALOG_DIR="$SCRIPT_DIR/catalog"
GEN_HEADER="$REPO_ROOT/tools/gen_pattern_header.py"

# Hardcoded H(k) — narrow-diameter least-known.
# Authoritative source (k>=25): Norman Luhn https://pzktupel.de/ktpatt_hl.php
# Cross-checked 2026-05-10: prior OEIS A008407-based values for k>=29 were
# too wide by 2..30 (the OEIS sequence appears stale at high k; Luhn's
# published narrow diameters are smaller). Using Luhn values throughout.
# k<=28 values match OEIS A008407 and Luhn (verified by count match).
declare -A H_K=(
    [2]=2  [3]=6  [4]=8  [5]=12 [6]=16 [7]=20 [8]=26 [9]=30
    [10]=32 [11]=36 [12]=42 [13]=48 [14]=50 [15]=56 [16]=60 [17]=66
    [18]=70 [19]=76 [20]=80 [21]=84 [22]=90 [23]=94 [24]=100
    [25]=110 [26]=114 [27]=120 [28]=126
    [29]=130 [30]=136 [31]=140 [32]=146 [33]=152 [34]=156 [35]=158
    [36]=162 [37]=168 [38]=176 [39]=182 [40]=186 [41]=188 [42]=196
    [43]=200 [44]=210 [45]=212 [46]=216 [47]=226 [48]=236 [49]=240 [50]=246
)

K_FROM=""
K_TO=""
THREADS="$(nproc)"
FORCE=0
DO_REGEN=0
DO_COMMIT=0
DO_PUSH=0

usage() {
    cat <<EOF
Usage: $0 --from <K1> --to <K2> [options]

Required:
  --from <K1>             starting k (inclusive)
  --to   <K2>             ending k   (inclusive)

Options:
  --threads <N>           OpenMP threads (default: nproc = $THREADS)
  --diameter <K=D>        override H(k) for one k (repeatable: --diameter 36=162 --diameter 37=168)
  --force                 re-enumerate even if catalog file exists
  --regen                 after enumeration, run gen_pattern_header.py
  --commit                stage catalog files (+ regen output if --regen) and commit
  --push                  git push origin main after commit (implies --commit)
  -h, --help              this message

Output:
  Catalog JSONs at $CATALOG_DIR/k<NN>_d<DDD>.json
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)     K_FROM="$2"; shift 2 ;;
        --to)       K_TO="$2";   shift 2 ;;
        --threads)  THREADS="$2"; shift 2 ;;
        --diameter)
            if [[ ! "$2" =~ ^[0-9]+=[0-9]+$ ]]; then
                echo "ERROR: --diameter expects K=D form, got '$2'" >&2; exit 2
            fi
            kk="${2%=*}"; dd="${2#*=}"
            H_K[$kk]="$dd"
            shift 2 ;;
        --force)    FORCE=1; shift ;;
        --regen)    DO_REGEN=1; shift ;;
        --commit)   DO_COMMIT=1; shift ;;
        --push)     DO_COMMIT=1; DO_PUSH=1; shift ;;
        -h|--help)  usage 0 ;;
        *)          echo "ERROR: unknown arg '$1'" >&2; usage 2 ;;
    esac
done

[[ -n "$K_FROM" && -n "$K_TO" ]] || { echo "ERROR: --from and --to required" >&2; usage 2; }
[[ "$K_FROM" =~ ^[0-9]+$ && "$K_TO" =~ ^[0-9]+$ ]] || { echo "ERROR: --from/--to must be integers" >&2; exit 2; }
(( K_FROM <= K_TO )) || { echo "ERROR: --from ($K_FROM) > --to ($K_TO)" >&2; exit 2; }

# Build pattern_enum if missing.
if [[ ! -x "$ENUM_BIN" ]]; then
    echo "[build] pattern_enum not found; building..."
    make -C "$SCRIPT_DIR" pattern_enum >&2
fi

mkdir -p "$CATALOG_DIR"

echo "=== catalog extend: k=$K_FROM..$K_TO threads=$THREADS ==="
echo "  catalog dir: $CATALOG_DIR"
echo "  pattern_enum: $ENUM_BIN"
echo

written_files=()
overall_start=$(date +%s)

for (( k=K_FROM; k<=K_TO; k++ )); do
    d="${H_K[$k]:-}"
    if [[ -z "$d" ]]; then
        echo "[k=$k] SKIP: H($k) unknown. Pass --diameter $k=<D> to override."
        continue
    fi

    out=$(printf "%s/k%02d_d%03d.json" "$CATALOG_DIR" "$k" "$d")

    if [[ -f "$out" && "$FORCE" -eq 0 ]]; then
        existing_count=$(python3 -c "import json,sys; print(json.load(open('$out'))['total_count'])" 2>/dev/null || echo "?")
        echo "[k=$k d=$d] SKIP: $out exists (count=$existing_count). Use --force to re-enumerate."
        continue
    fi

    echo "[k=$k d=$d] enumerating -> $out"
    start=$(date +%s)

    # Use a tmp file then rename so an interrupted run doesn't leave a partial JSON.
    tmp="${out}.partial"
    if "$ENUM_BIN" --k "$k" --diameter "$d" --threads "$THREADS" --format json --quiet > "$tmp"; then
        mv "$tmp" "$out"
        end=$(date +%s)
        count=$(python3 -c "import json,sys; print(json.load(open('$out'))['total_count'])")
        elapsed=$((end - start))
        echo "[k=$k d=$d] OK: count=$count elapsed=${elapsed}s -> $out"
        written_files+=("$out")
    else
        rm -f "$tmp"
        echo "[k=$k d=$d] FAIL: pattern_enum returned non-zero. Aborting." >&2
        exit 1
    fi
done

overall_end=$(date +%s)
echo
echo "=== enumeration done in $((overall_end - overall_start))s; ${#written_files[@]} new file(s) ==="

if (( ${#written_files[@]} == 0 )) && (( ! DO_REGEN )); then
    echo "Nothing new written; not regenerating header."
    exit 0
fi

if (( DO_REGEN )); then
    echo
    echo "=== regenerating src/common/ktuplet_pattern.{h,c} ==="
    python3 "$GEN_HEADER"
fi

if (( DO_COMMIT )); then
    echo
    echo "=== git commit ==="
    cd "$REPO_ROOT"
    if (( ${#written_files[@]} > 0 )); then
        git add "${written_files[@]}"
    fi
    if (( DO_REGEN )); then
        git add src/common/ktuplet_pattern.h src/common/ktuplet_pattern.c
    fi

    if git diff --cached --quiet; then
        echo "No staged changes; nothing to commit."
    else
        k_list=$(printf '%s\n' "${written_files[@]}" \
            | sed -n 's|.*/k\([0-9]\+\)_d.*|\1|p' \
            | sort -un | paste -sd, -)
        msg_subject="Extend pattern catalog: k=${k_list:-(none)}"
        git commit -m "$(printf '%s\n\nFiles: %s\n%s' \
            "$msg_subject" \
            "$(printf '\n  - %s' "${written_files[@]#$REPO_ROOT/}")" \
            "$( (( DO_REGEN )) && echo 'Regenerated src/common/ktuplet_pattern.{h,c}.' )" \
        )"
        echo "Commit: $(git log -1 --oneline)"
    fi
fi

if (( DO_PUSH )); then
    echo
    echo "=== git push origin main ==="
    cd "$REPO_ROOT"
    git push origin main
fi

echo
echo "=== done ==="
