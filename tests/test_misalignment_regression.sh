#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# W18-F: Misalignment-injection regression test .
#
# For each record selected by tests/select_records_by_bit_bucket.py, run the
# engine with --inject-cursor-offset = 0 (Case A), 1 (Case B), 0x4000000 (Case C)
# inside a tight --prefix range that the engine's batch-0 chunk fully covers.
# Engine output ("*** FOUND ... base=<base> ***") gates each case.
#
# Modes:
#   --expect prefix   pre-W18-A binary: assert A=FIND, B=MISS, C=MISS
#   --expect postfix  post-W19-A-1 binary: assert A=FIND, B/C=ABORT_ALIGN
#                     (the post-init inject must reach the kernel-launch
#                      alignment trip-wire, not be silently rounded away)
#
# Required env:
#   GPU1_HOST="-p PORT root@GPU_SERVER"  (ssh args)
#   REMOTE_BIN=/root/kt/src/kt_filter_v8
#   PER_CASE_TIMEOUT=90  (seconds, --max-time arg)
#
# Output dir: tests/soak_artifacts/misalignment_<run_id>/

set -uo pipefail

EXPECT=""
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

while [ $# -gt 0 ]; do
    case "$1" in
        --expect) EXPECT="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ "$EXPECT" != "prefix" ] && [ "$EXPECT" != "postfix" ]; then
    echo "Usage: $0 --expect {prefix|postfix} [--run-id ID]" >&2
    exit 2
fi

GPU1_HOST="${GPU1_HOST:?Set GPU1_HOST to ssh args, e.g. -p PORT root@GPU_SERVER}"
REMOTE_BIN="${REMOTE_BIN:-/root/kt/src/kt_filter_v8}"
PER_CASE_TIMEOUT="${PER_CASE_TIMEOUT:-90}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEL="$ROOT/tests/select_records_by_bit_bucket.py"
OUTDIR="$ROOT/tests/soak_artifacts/misalignment_${RUN_ID}"
mkdir -p "$OUTDIR"

echo "[W18-F] run_id=$RUN_ID  expect=$EXPECT  remote_bin=$REMOTE_BIN  out=$OUTDIR"

CASES_NAME=(A B C)
CASES_OFF=(0 1 0x4000000)

declare -i n_records=0
declare -i n_pass=0
declare -i n_fail=0
declare -a anomalies

while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    n_records+=1
    k=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['k'])")
    bits=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['bits'])")
    pat=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['pattern'])")
    prim_n=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['primorial_n'])")
    pfx_bits=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['prefix_bits'])")
    pfx_bin=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['prefix_binary'])")
    base=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['base_str'])")
    bucket=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['bucket'])")
    seed=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['random_seed'])")
    gbs=$(printf %s "$rec" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['gpu_batch_size'])")

    echo "  [rec k=$k bits=$bits bucket=$bucket pattern=$pat base=${base:0:12}...]"

    for i in 0 1 2; do
        cname="${CASES_NAME[$i]}"
        coff="${CASES_OFF[$i]}"
        logf="$OUTDIR/k${k}_b${bits}_${cname}_off${coff}.log"
        # Set KT_RECORDS_JSON so the engine's records-cross-check sees the
        # known canon and the test does not spuriously append to novel_records.jsonl.
        cmd="KT_RECORDS_JSON=/root/kt/src/baseline/records.json $REMOTE_BIN --pattern $pat --bits $bits --primorial $prim_n \
            --prefix $pfx_bin --prefix-mode random --random-seed $seed \
            --max-time $PER_CASE_TIMEOUT \
            --gpu-batch-size $gbs \
            --inject-cursor-offset $coff \
            --gpu-device 0 --quiet 2>&1"
        # shellcheck disable=SC2029
        ssh $GPU1_HOST "$cmd" > "$logf" 2>&1 </dev/null || true

        # Outcome detection (W19-A-1):
        #  FIND        — engine emitted "*** FOUND ... base=<expected_base> ***"
        #  ABORT_ALIGN — engine printed FATAL cursor-alignment + aborted (= kernel-launch trip-wire fired; expected for the W19-A-1 binary on inject != 0)
        #  MISS        — neither: legacy pre-W18-A binary outcome on inject != 0 (silent 0 survivors)
        if grep -F "base=$base" "$logf" | grep -q FOUND; then
            outcome="FIND"
        elif grep -qE "(\[FATAL\]|FATAL:) cursor not primorial-aligned" "$logf"; then
            outcome="ABORT_ALIGN"
        else
            outcome="MISS"
        fi

        # Expected-outcome table:
        #   --expect prefix  : legacy pre-W18-A binary (no trip-wire)
        #                      A=FIND, B/C=MISS (kernel silently filters all candidates)
        #   --expect postfix : post-W19-A-1 binary (3-site fix + trip-wire, NO trailing round)
        #                      A=FIND, B/C=ABORT_ALIGN (trip-wire catches the inject)
        # Note: the worker brief text reads "post-fix Cases A=B=C all FIND" but
        # that is inconsistent with the same brief's "remove the trailing
        # defensive round" instruction (which lets the inject reach the
        # kernel-launch trip-wire).  ABORT_ALIGN on B/C is the operationally
        # correct outcome and the one that actually proves the trip-wire works.
        if [ "$EXPECT" = "prefix" ]; then
            if [ "$cname" = "A" ]; then exp="FIND"; else exp="MISS"; fi
        else
            if [ "$cname" = "A" ]; then exp="FIND"; else exp="ABORT_ALIGN"; fi
        fi

        if [ "$outcome" = "$exp" ]; then
            n_pass+=1
            verdict="ok"
        else
            n_fail+=1
            verdict="FAIL"
            anomalies+=("k${k} bits=${bits} case=${cname} off=${coff} expected=${exp} got=${outcome} log=${logf##*/}")
        fi
        echo "    case $cname (off=$coff): outcome=$outcome expected=$exp $verdict"
    done
done < <(python3 "$SEL")

echo
echo "[W18-F] summary: records=$n_records cases=$((n_records*3)) pass=$n_pass fail=$n_fail"

if [ "$n_fail" -ne 0 ]; then
    echo "[W18-F] FAIL — anomalies:"
    for a in "${anomalies[@]}"; do echo "    - $a"; done
    if [ "$EXPECT" = "prefix" ]; then
        echo "[W18-F] STOP: pre-fix run mismatch — bug shape differs from spec; surface and reconsider W18-A."
    else
        echo "[W18-F] STOP: post-fix run failed — alignment fix did not close the bug across all records."
    fi
    exit 1
fi

if [ "$EXPECT" = "prefix" ]; then
    echo "[W18-F] PRE-FIX PROOF: legacy bug confirmed across $n_records records, B+C miss as predicted (pre-W18-A binary)"
else
    echo "[W18-F] POST-FIX VALIDATION: A finds, B+C trip kernel-launch ABORT_ALIGN across $n_records records (3-site fix intact, trip-wire armed)"
fi
exit 0
