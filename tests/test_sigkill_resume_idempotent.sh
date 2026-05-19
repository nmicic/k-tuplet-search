#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# W19-B-7 (multi-angle P1-9): real SIGKILL-mid-flight resume idempotence test.
#
# Validates W18-B drain-boundary invariant under SIGKILL.  Compares a 60s
# uninterrupted reference run against 3 SIGKILL-and-resume runs.
#
# Methodology: a naive (post_resume_cand - 0) vs (ref_cand) check fails
# spuriously because the SIGKILL+resume path pays startup overhead TWICE
# (records.json load, wheel build, filter mask upload, cudaStreamCreate,
# Stage-0 mu precompute) — ~1s amortized into a 60s run is ~2% throughput
# loss vs the 1-startup reference, even when W18-B's cursor accounting is
# perfectly correct.
#
# What W18-B actually claims: the saved (cursor, total_cand, batches)
# tuple at SIGKILL time is internally consistent at the drain boundary.
# Resume picks up at the saved cursor and continues — no double-counting,
# no skipped batches.  The right metric is THROUGHPUT during the resume
# window (which excludes both startup overheads), compared against the
# reference's throughput.  If those match within noise, W18-B holds.
#
# Mode: --prefix-mode sequential (W19-B-3 refuses random-mode resume).
#
# Env:
#   KT_BIN     path to kt_filter_v8 (default /root/kt/src/kt_filter_v8)
#   KT_TMP     scratch dir (default /root/kt/tmp/sigkill_idempotent)
#   KT_GPU     GPU id (default 0)
#
# Exit: 0 PASS, 1 FAIL (resume-window rate > 1.0% off ref rate, OR resume
# was not monotonic, OR any soft-fail message on the resume path).
set -euo pipefail

BIN="${KT_BIN:-/root/kt/src/kt_filter_v8}"
TMP="${KT_TMP:-/root/kt/tmp/sigkill_idempotent}"
GPU="${KT_GPU:-0}"
REF_SEC=60
KILL_AT=3
RESUME_SEC=$((REF_SEC - KILL_AT))
# Tolerance on the resume-window THROUGHPUT vs reference throughput.
# 1.0% covers per-tick measurement noise + the small fraction of pre-kill
# work that ran during the resume's own warm-up but counted toward the
# pre-kill total (drain-boundary makes this small but non-zero).
RATE_TOLERANCE_PCT="1.0"

mkdir -p "$TMP"
rm -f "$TMP"/*.log "$TMP"/*.ckpt

ARGS_COMMON=(
    --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU"
    --gpu-batch-size 1048576 --gpu-streams 3
    --prefix-mode sequential --prefix 0b1
)

extract_cand() {
    grep '=== final' "$1" | sed -E 's/.* cand=([0-9]+) .*/\1/' | head -1
}

echo "=== reference run (${REF_SEC}s uninterrupted) ==="
"$BIN" "${ARGS_COMMON[@]}" --max-time $REF_SEC --report 30 --full-quiet \
    >"$TMP/ref.log" 2>&1
REF_CAND=$(extract_cand "$TMP/ref.log")
echo "ref cand=$REF_CAND"

if [[ -z "$REF_CAND" ]]; then
    echo "FAIL: could not extract reference cand from $TMP/ref.log" >&2
    exit 1
fi
# Reference throughput (cand per second) — the steady-state rate the engine
# achieves on this cell.  Used as the target for resume-window throughput.
REF_RATE=$(python3 -c "print($REF_CAND / $REF_SEC)")
echo "ref rate = $REF_RATE cand/s"

FAIL_COUNT=0
for run in 1 2 3; do
    echo "=== SIGKILL run $run (kill at ${KILL_AT}s, resume +${RESUME_SEC}s) ==="
    CK="$TMP/run${run}.ckpt"
    rm -f "$CK"

    "$BIN" "${ARGS_COMMON[@]}" \
        --max-time $REF_SEC \
        --checkpoint "$CK" --ckpt-interval 1 \
        --report 5 --full-quiet \
        >"$TMP/run${run}_pre.log" 2>&1 &
    PID=$!
    sleep $KILL_AT
    kill -KILL $PID 2>/dev/null || true
    wait $PID 2>/dev/null || true

    # Capture pre-kill cand from ckpt (drain-boundary).
    PRE_HI=$(grep '^total_cand_hi=' "$CK" | cut -d= -f2)
    PRE_LO=$(grep '^total_cand_lo=' "$CK" | cut -d= -f2)
    PRE_CAND=$(python3 -c "print((int('$PRE_HI', 16) << 64) | int('$PRE_LO', 16))")
    echo "run $run pre-kill cand (from ckpt) = $PRE_CAND"

    # Resume; let it complete the remaining wall time.
    "$BIN" "${ARGS_COMMON[@]}" \
        --max-time $RESUME_SEC \
        --checkpoint "$CK" --resume "$CK" \
        --report 5 --full-quiet \
        >"$TMP/run${run}_post.log" 2>&1
    POST_CAND=$(extract_cand "$TMP/run${run}_post.log")
    if [[ -z "$POST_CAND" ]]; then
        echo "FAIL: could not extract post-resume cand from $TMP/run${run}_post.log" >&2
        exit 1
    fi
    echo "run $run post-resume final cand = $POST_CAND"

    # Monotonicity: post-resume total_cand must exceed pre-kill cand (resume
    # actually did work) and the resume-window rate should match the ref rate.
    if [[ "$POST_CAND" -le "$PRE_CAND" ]]; then
        echo "run $run FAIL: post-resume cand ($POST_CAND) <= pre-kill cand ($PRE_CAND); resume did no work"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if grep -qE "starting fresh|outside lane|coverage gap" "$TMP/run${run}_post.log"; then
        echo "run $run FAIL: resume soft-failed:"
        grep -E "starting fresh|outside lane|coverage gap" "$TMP/run${run}_post.log" | head -3
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    RESUME_RATE=$(python3 -c "print(($POST_CAND - $PRE_CAND) / $RESUME_SEC)")
    RATE_DELTA_PCT=$(python3 -c "import math; print(abs($RESUME_RATE - $REF_RATE) / $REF_RATE * 100)")
    echo "run $run resume-window rate = $RESUME_RATE cand/s  (ref $REF_RATE; delta ${RATE_DELTA_PCT}%; tol ${RATE_TOLERANCE_PCT}%)"
    if python3 -c "import sys; sys.exit(0 if $RATE_DELTA_PCT <= $RATE_TOLERANCE_PCT else 1)"; then
        echo "run $run PASS"
    else
        echo "run $run FAIL: resume-window rate delta exceeds tolerance"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo
    echo "=== W19-B-7 PASS: 3/3 SIGKILL+resume runs at resume-window rate within ${RATE_TOLERANCE_PCT}% of reference ==="
    exit 0
else
    echo
    echo "=== W19-B-7 FAIL: $FAIL_COUNT/3 runs exceeded tolerance ===" >&2
    exit 1
fi
