#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# tests/test_e2e_runner_soak.sh — T-H9 end-to-end runner soak fixture.
#
# Self-contained ~10-min lowbits-style campaign on a remote 5090 GPU.
# Asserts seven things via tests/parse_runner_telemetry.py:
#   1. per-cell bits non-decreasing (state-file monotonicity)
#   2. nvidia-smi dmon utilization median >= UTIL_THRESHOLD (default 90)
#   3. fluent-bit alive throughout, no kafka output errors
#   4. no partial-scan rows in sweep_status.jsonl (required fields present)
#   5. .lowbits_state schema unchanged pre/post (floor=N high=N current=N)
#   6. external (production-path) record reproduction via --prefix
#      (validate_records_external.sh; rc==0 + every selected record found)
#   7. post-exit GPU util is not attributable to a surviving kt_filter_v8 PID
#
# Env knobs:
#   SSH_HOST    ssh login (e.g. root@GPU-SERVER)
#   SSH_PORT    ssh port
#   GPU         GPU index on remote (default 0)
#   SOAK_SEC    soak duration seconds (default 600)
#   PATTERN     pattern name (default KT19_P0)
#   BITS_FLOOR  default 60
#   BITS_HIGH   default 62
#   KT_PRIMORIAL default 11 (37# wheel)
#   UTIL_THRESHOLD median-util pass bar (default 90)
set -euo pipefail

SSH_HOST="${SSH_HOST:?Set SSH_HOST to ssh login, e.g. root@GPU-SERVER}"
SSH_PORT="${SSH_PORT:?Set SSH_PORT to ssh port, e.g. 22}"
GPU="${GPU:-0}"
SOAK_SEC="${SOAK_SEC:-600}"
PATTERN="${PATTERN:-KT19_P0}"
BITS_FLOOR_VAL="${BITS_FLOOR:-60}"
BITS_HIGH_VAL="${BITS_HIGH:-62}"
KT_PRIM="${KT_PRIMORIAL:-11}"
UTIL_THRESHOLD="${UTIL_THRESHOLD:-90}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)_${PATTERN}_gpu${GPU}"
ARTDIR_LOCAL="tests/soak_artifacts/${RUN_ID}"
REMOTE_WD="/root/kt/soak_t_h9_gpu${GPU}"
mkdir -p "$ARTDIR_LOCAL"

SSH="ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 $SSH_HOST"
SCP="scp -P $SSH_PORT -o StrictHostKeyChecking=no"

echo "[soak] run_id=$RUN_ID gpu=$GPU soak=${SOAK_SEC}s pattern=$PATTERN bits=${BITS_FLOOR_VAL}..${BITS_HIGH_VAL}"

# Pre-flight: fresh remote workdir, symlink binary, capture fluent-bit baseline.
$SSH bash -s <<REMOTE_PRE
set -e
rm -rf "$REMOTE_WD"
mkdir -p "$REMOTE_WD/src"
ln -sf /root/kt/src/kt_filter_v8 "$REMOTE_WD/src/kt_filter_v8"
test -x /root/kt/src/kt_filter_v8
systemctl is-active fluent-bit
REMOTE_PRE
$SSH "pgrep -f 'fluent-bit' | sort -n | head -1" > "$ARTDIR_LOCAL/fluentbit_pid_pre.txt"

# Launch runner + dmon sampler in remote background, capture pids.
$SSH bash -s <<REMOTE_LAUNCH > "$ARTDIR_LOCAL/launch_pids.txt"
set -e
cd /root/kt
nohup env PATTERN="$PATTERN" BITS_FLOOR="$BITS_FLOOR_VAL" BITS_INITIAL_CEIL="$BITS_HIGH_VAL" \
    KT_PRIMORIAL="$KT_PRIM" GPU_ID="$GPU" PER_CELL_MAX_SEC=0 WORKDIR="$REMOTE_WD" \
    bash /root/kt/run_lowbits.sh > /dev/null 2>&1 &
echo "RUNNER_PID=\$!"
nohup nvidia-smi dmon -i "$GPU" -s u -d 1 > "$REMOTE_WD/dmon.log" 2>&1 &
echo "DMON_PID=\$!"
REMOTE_LAUNCH
cat "$ARTDIR_LOCAL/launch_pids.txt"

# Soak window: sleep on principal, then kill remote workers.
echo "[soak] sleeping ${SOAK_SEC}s..."
sleep "$SOAK_SEC"
echo "[soak] tear down remote workers."
$SSH bash -s <<REMOTE_TEARDOWN || true
pkill -TERM -f "run_lowbits.sh" 2>/dev/null || true
pkill -TERM -f "nvidia-smi dmon" 2>/dev/null || true
sleep 3
pkill -TERM -f "kt_filter_v8" 2>/dev/null || true
sleep 2
pkill -KILL -f "kt_filter_v8" 2>/dev/null || true
sync
REMOTE_TEARDOWN

# Assertion 7 (W19-B-9 / multi-angle P1-3): post-exit phantom-util gate.
# W18-I + W19-B-1 install kt_cuda_cleanup_atexit which calls cudaDeviceReset
# at process exit; if the cleanup actually fires, nvidia-smi util should
# drop to ~0% within a second of the last engine PID exiting. A sustained
# >5% reading after 1s indicates the CUDA context is still warm — the
# phantom-util artifact W17-C diagnosed. Capture 5 samples at 1s cadence
# AFTER the kill block ensured no engine PIDs remain.
echo "[soak] post-exit phantom-util sampling..."
sleep 1  # give the OS/driver a beat to reap the last process and release SM counters
$SSH "nvidia-smi dmon -c 5 -d 1 -s u -i $GPU 2>/dev/null" \
    > "$ARTDIR_LOCAL/dmon_post_exit.log" || \
    echo "[soak] WARNING: post-exit dmon capture failed (may still pass via cumulative)"
$SSH "pgrep -af kt_filter_v8 2>/dev/null || true" \
    > "$ARTDIR_LOCAL/kt_filter_pids_post_exit.txt" || true

# Capture post fluent-bit state, then rsync artifacts back.
$SSH "systemctl is-active fluent-bit; pgrep -f 'fluent-bit' | sort -n | head -1" > "$ARTDIR_LOCAL/fluentbit_pid_post.txt"
$SSH "journalctl -u fluent-bit --since '${SOAK_SEC} seconds ago' --no-pager 2>/dev/null | tail -60" > "$ARTDIR_LOCAL/fluentbit_journal.txt" || true
# Pull state file, dmon, runner log, sweep status JSONL(s).
$SSH "cat $REMOTE_WD/.lowbits_state 2>/dev/null || echo MISSING" > "$ARTDIR_LOCAL/state_post.txt"
$SCP -r "$SSH_HOST:$REMOTE_WD/runner.log" "$ARTDIR_LOCAL/runner.log" 2>/dev/null || echo "[soak] runner.log not pulled"
$SCP    "$SSH_HOST:$REMOTE_WD/dmon.log"   "$ARTDIR_LOCAL/dmon.log"   2>/dev/null || echo "[soak] dmon.log not pulled"
$SSH "find $REMOTE_WD/runs -name sweep_status.jsonl -printf '%p\n'" > "$ARTDIR_LOCAL/sweep_status_paths.txt" || true
mkdir -p "$ARTDIR_LOCAL/runs"
while read -r p; do
    [[ -z "$p" ]] && continue
    rel="${p#$REMOTE_WD/}"; mkdir -p "$ARTDIR_LOCAL/$(dirname "$rel")"
    $SCP "$SSH_HOST:$p" "$ARTDIR_LOCAL/$rel" 2>/dev/null || true
done < "$ARTDIR_LOCAL/sweep_status_paths.txt"

# Assertion 6: external record reproduction via --prefix on the production
# binary. Runs from this (controlling) host and ssh's into the same target;
# does not need to be shipped to the remote. Subset (bits ≤ EXT_MAX_BITS,
# default 70 → ~4 records of k=16/17) keeps wall time under ~2 min so the
# soak still fits its ~10-min envelope without padding any threshold.
EXT_LOG="$ARTDIR_LOCAL/validate_external.log"
EXT_RC_FILE="$ARTDIR_LOCAL/validate_external.rc"
echo "[soak] external record validation (MAX_BITS=${EXT_MAX_BITS:-70})..."
set +e
SSH_HOST="$SSH_HOST" SSH_PORT="$SSH_PORT" GPU_ID="$GPU" \
    MAX_BITS="${EXT_MAX_BITS:-70}" PER_TEST_SEC="${EXT_PER_TEST_SEC:-25}" \
    PREFIX_HEAD="${EXT_PREFIX_HEAD:-30}" PRIMORIAL="$KT_PRIM" \
    bash longevity_gpu/scripts/validate_records_external.sh \
    > "$EXT_LOG" 2>&1
ext_rc=$?
set -e
echo "$ext_rc" > "$EXT_RC_FILE"
echo "[soak] external validation rc=$ext_rc (log: $EXT_LOG)"

# Prune to last 3 soak runs by mtime (newest-first; keep top 3, delete the rest).
( cd tests/soak_artifacts && ls -1t | tail -n +4 | xargs -r rm -rf ) || true

# Run telemetry parser; exit code propagates pass/fail.
python3 tests/parse_runner_telemetry.py \
    --artdir "$ARTDIR_LOCAL" \
    --util-threshold "$UTIL_THRESHOLD"
