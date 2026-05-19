#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# checkin.sh — pull progress + novel records from the remote GPU box back here.
# Idempotent; safe to call repeatedly. Designed for hourly cron / ScheduleWakeup.
#
# Outputs (under scripts/longevity_gpu/runs/, NEVER touches existing repo files):
#   runs/last_checkin.txt              human summary (overwritten)
#   runs/novel_records.jsonl           cumulative merge of remote novel records
#   runs/gpu_samples.jsonl             cumulative copy of nvidia-smi samples
#   runs/runner.log                    cumulative copy of remote runner.log
#   runs/sweeps/<sweep>/sweep_status.jsonl   per-sweep status streams
#   runs/health.json                   machine-readable summary

set -euo pipefail

SSH_HOST="${SSH_HOST:?set SSH_HOST=root@<gpu-host>}"
SSH_PORT="${SSH_PORT:?set SSH_PORT=<ssh-port>}"
REMOTE_DIR="${REMOTE_DIR:-/root/kt_longevity}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL="$REPO_ROOT/scripts/longevity_gpu/runs"
mkdir -p "$LOCAL/sweeps"

SSH="ssh -p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=15"
SCP="scp -P $SSH_PORT -q -o BatchMode=yes -o ConnectTimeout=15"

# 1. Liveness: is run_matrix.sh + kt_filter alive? Latest sweep + cell?
remote_status="$($SSH "$SSH_HOST" bash -s <<'EOREMOTE'
WORKDIR="${WORKDIR:-/root/kt_longevity}"
runner_pid="$(pgrep -f run_matrix.sh | head -1 || true)"
filter_pid="$(pgrep -f kt_filter | head -1 || true)"
sweep_dir="$(ls -td $WORKDIR/runs/sweep_* 2>/dev/null | head -1)"
sweep_name="$(basename "$sweep_dir" 2>/dev/null || echo none)"
status_file="$sweep_dir/sweep_status.jsonl"
last_status="$(tail -1 "$status_file" 2>/dev/null || echo {})"
cells_done="$(wc -l < "$status_file" 2>/dev/null || echo 0)"
novel_count="$(cat "$WORKDIR"/novel_records.jsonl "$WORKDIR"/novel_records_gpu*.jsonl 2>/dev/null | wc -l || echo 0)"
gpu_one="$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,memory.used --format=csv,noheader,nounits | head -1)"
echo "RUNNER_PID=$runner_pid"
echo "FILTER_PID=$filter_pid"
echo "SWEEP=$sweep_name"
echo "CELLS_DONE=$cells_done"
echo "NOVEL_COUNT=$novel_count"
echo "GPU=$gpu_one"
echo "LAST_STATUS=$last_status"
EOREMOTE
)"

echo "$remote_status" > "$LOCAL/last_checkin.txt"
echo "[checkin] === $(date -u +%FT%TZ) ==="
echo "$remote_status"

# 2. Pull novel records (small files; full merged copy is fine)
$SSH "$SSH_HOST" "cat $REMOTE_DIR/novel_records.jsonl $REMOTE_DIR/novel_records_gpu*.jsonl 2>/dev/null" > "$LOCAL/novel_records.jsonl" || true

# 3. Pull runner log + GPU samples + all sweep_status.jsonl files
$SCP "$SSH_HOST:$REMOTE_DIR/runner.log"          "$LOCAL/runner.log"          2>/dev/null || true
$SCP "$SSH_HOST:$REMOTE_DIR/gpu_samples.jsonl"   "$LOCAL/gpu_samples.jsonl"   2>/dev/null || true

# Use rsync for the per-sweep tree (only changed bits; tolerate rsync absent)
if command -v rsync >/dev/null 2>&1; then
    rsync -aq -e "ssh -p $SSH_PORT -o BatchMode=yes" \
        --include='*/' --include='sweep_status.jsonl' --include='meta.json' --exclude='*' \
        "$SSH_HOST:$REMOTE_DIR/runs/" "$LOCAL/sweeps/" || true
else
    # Fallback: tar over ssh, just status files
    $SSH "$SSH_HOST" "cd $REMOTE_DIR/runs && tar cf - --files-from <(find . -name sweep_status.jsonl -o -name meta.json)" \
        | tar xf - -C "$LOCAL/sweeps/" 2>/dev/null || true
fi

# 4. Build a compact health.json
python3 - "$LOCAL" <<'EOPY' || true
import json, os, sys, glob, statistics
local = sys.argv[1]

def parse_kv_blob(p):
    out = {}
    if not os.path.exists(p): return out
    for line in open(p):
        if "=" in line:
            k, v = line.rstrip().split("=", 1)
            out[k] = v
    return out

kv = parse_kv_blob(os.path.join(local, "last_checkin.txt"))
nov = os.path.join(local, "novel_records.jsonl")
nov_count = sum(1 for _ in open(nov)) if os.path.exists(nov) else 0

# Aggregate elapsed/rate from all sweep_status.jsonl
elapsed_total = 0
cells_total = 0
rc_nonzero = 0
last_run = None
for sf in glob.glob(os.path.join(local, "sweeps", "*", "sweep_status.jsonl")):
    for line in open(sf):
        try: row = json.loads(line)
        except Exception: continue
        cells_total += 1
        elapsed_total += row.get("elapsed_sec", 0)
        if row.get("rc", 0) != 0: rc_nonzero += 1
        last_run = row

samples = os.path.join(local, "gpu_samples.jsonl")
util_avg = None
if os.path.exists(samples):
    utils = []
    for line in open(samples):
        try: utils.append(float(json.loads(line).get("util_pct", 0)))
        except Exception: pass
    if utils:
        util_avg = round(statistics.mean(utils[-60:]), 1)  # last hour-ish

out = {
    "checked_at": __import__('datetime').datetime.utcnow().isoformat()+"Z",
    "remote": kv,
    "novel_count": nov_count,
    "sweeps_cells_total": cells_total,
    "sweeps_cells_failed": rc_nonzero,
    "sweeps_elapsed_sec_total": elapsed_total,
    "util_avg_last60": util_avg,
    "last_run": last_run,
}
with open(os.path.join(local, "health.json"), "w") as fh:
    json.dump(out, fh, indent=2)
print("[checkin] health.json written")
EOPY

echo "[checkin] done."
