#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# checkin_multi.sh — operator-side health check + auto-recovery for a
# multi-GPU longevity campaign. Designed to be the body of an hourly /loop.
#
# What it does (in order, each step idempotent):
#   1. Probe SSH. If unreachable: print one warning line and exit 0 (a /loop
#      caller can decide whether to alarm).
#   2. Detect VM reboot (uptime drops below the last seen value). If yes,
#      relaunch all 4 tmux runners.
#   3. Pull latest local-HEAD short SHA. If different from what's stamped
#      on the remote binary (kt_filter_v8 --version), rebuild + relaunch.
#   4. For each GPU in 0..N-1, check that its tmux session is alive and that
#      a kt_filter_v8 process is running with --gpu-device matching. If
#      missing, relaunch just that GPU's session.
#   5. Aggregate per-GPU progress: cells_done, current cell, last useful_cand/s,
#      gpu temp/util/mem, novel_records*.jsonl count, found.txt non-empty.
#      Emit one stdout line per GPU + one summary line.
#
# Env / config:
#   SSH_HOST       (required)  e.g. root@GPU-SERVER
#   SSH_PORT       (required)
#   N_GPUS         default 4
#   REMOTE_DIR     default /root/kt
#   CAMPAIGN_MODE  "lowbits" (default) or "bands". Selects the runner script
#                  + per-GPU param scheme:
#                    lowbits → run_lowbits.sh, PATTERN_GPU0..3 (one pattern per GPU,
#                              exhaustive sweep, KT_PRIMORIAL=14 = 47# wheel default)
#                    bands   → run_matrix.sh,  BANDS_GPU0..3   (multi-band random sweep,
#                              K_FILTER=19, KT_PRIMORIAL=12 = 41# wheel default)
#   K_FILTER       default 19              (bands mode only)
#   KT_PRIMORIAL   default 14 in lowbits mode, 12 in bands mode
#   KT_WHEEL_EXPR  optional; overrides KT_PRIMORIAL in runner scripts
#   REPO_ROOT      default = git root containing this script
#
# Idempotent. Safe to run any time. Designed for cron / /loop firings.

set -uo pipefail

SSH_HOST="${SSH_HOST:?set SSH_HOST=root@<ip>}"
SSH_PORT="${SSH_PORT:?set SSH_PORT=<port>}"
N_GPUS="${N_GPUS:-4}"
REMOTE_DIR="${REMOTE_DIR:-/root/kt}"
CAMPAIGN_MODE="${CAMPAIGN_MODE:-lowbits}"
K_FILTER="${K_FILTER:-19}"
if [[ "$CAMPAIGN_MODE" == "lowbits" ]]; then
    KT_PRIMORIAL="${KT_PRIMORIAL:-14}"
else
    KT_PRIMORIAL="${KT_PRIMORIAL:-12}"
fi
KT_WHEEL_EXPR="${KT_WHEEL_EXPR:-}"

# lowbits mode: per-GPU PATTERN assignment (each GPU runs ONE pattern,
# walking bits BITS_FLOOR..BITS_HIGH exhaustively). Operator's task
# 2026-05-09: novel patterns at 47# wheel, low bits.
PATTERN_GPU0="${PATTERN_GPU0:-KT22_P3}"
PATTERN_GPU1="${PATTERN_GPU1:-KT22_P2}"
PATTERN_GPU2="${PATTERN_GPU2:-KT23_P1}"
PATTERN_GPU3="${PATTERN_GPU3:-KT24_P3}"
BITS_FLOOR="${BITS_FLOOR:-60}"
BITS_INITIAL_CEIL="${BITS_INITIAL_CEIL:-127}"
BITS_BAND_STEP="${BITS_BAND_STEP:-4}"
PER_CELL_MAX_SEC="${PER_CELL_MAX_SEC:-0}"

# bands mode: per-GPU BANDS for the 89..119 8-band random sweep across 4 GPUs.
BANDS_GPU0="${BANDS_GPU0:-89 92}"
BANDS_GPU1="${BANDS_GPU1:-95 98}"
BANDS_GPU2="${BANDS_GPU2:-101 105}"
BANDS_GPU3="${BANDS_GPU3:-110 119}"

REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

ssh_run() { ssh -p "$SSH_PORT" -o ConnectTimeout=15 -o ServerAliveInterval=5 "$SSH_HOST" "$@"; }

shell_quote() { printf '%q' "$1"; }

bands_for_gpu() {
    case "$1" in
        0) echo "$BANDS_GPU0" ;;
        1) echo "$BANDS_GPU1" ;;
        2) echo "$BANDS_GPU2" ;;
        3) echo "$BANDS_GPU3" ;;
        *) echo "" ;;
    esac
}

pattern_for_gpu() {
    case "$1" in
        0) echo "$PATTERN_GPU0" ;;
        1) echo "$PATTERN_GPU1" ;;
        2) echo "$PATTERN_GPU2" ;;
        3) echo "$PATTERN_GPU3" ;;
        *) echo "" ;;
    esac
}

launch_gpu_session() {
    local gpu="$1"
    local workdir="$REMOTE_DIR/gpu$gpu"
    local session="ktlong$gpu"
    local q_wheel_expr; q_wheel_expr="$(shell_quote "$KT_WHEEL_EXPR")"
    if [[ "$CAMPAIGN_MODE" == "lowbits" ]]; then
        local pattern; pattern="$(pattern_for_gpu "$gpu")"
        echo "[checkin] (re)launching GPU $gpu  pattern=$pattern  workdir=$workdir  (lowbits, 47#=14)"
        ssh_run "
            mkdir -p $workdir
            ln -sfn $REMOTE_DIR/src $workdir/src
            tmux kill-session -t $session 2>/dev/null || true
            tmux new-session -d -s $session \\
              \"BIN=$REMOTE_DIR/src/kt_filter_v8 WORKDIR=$workdir GPU_ID=$gpu \\
                PATTERN='$pattern' KT_PRIMORIAL=$KT_PRIMORIAL KT_WHEEL_EXPR=$q_wheel_expr \\
                BITS_FLOOR=$BITS_FLOOR BITS_INITIAL_CEIL=$BITS_INITIAL_CEIL \\
                BITS_BAND_STEP=$BITS_BAND_STEP PER_CELL_MAX_SEC=$PER_CELL_MAX_SEC \\
                bash $REMOTE_DIR/run_lowbits.sh\"
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                pgrep -f \"kt_filter_v8.*--gpu-device $gpu\" >/dev/null && break
                sleep 1
            done
        "
    else
        local bands; bands="$(bands_for_gpu "$gpu")"
        echo "[checkin] (re)launching GPU $gpu  bands=\"$bands\"  workdir=$workdir  (bands)"
        ssh_run "
            mkdir -p $workdir
            ln -sfn $REMOTE_DIR/src $workdir/src
            tmux kill-session -t $session 2>/dev/null || true
            tmux new-session -d -s $session \\
              \"BIN=$REMOTE_DIR/src/kt_filter_v8 WORKDIR=$workdir GPU_ID=$gpu \\
                K_FILTER='$K_FILTER' BANDS='$bands' KT_PRIMORIAL=$KT_PRIMORIAL KT_WHEEL_EXPR=$q_wheel_expr \\
                bash $REMOTE_DIR/run_matrix.sh\"
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                pgrep -f \"kt_filter_v8.*--gpu-device $gpu\" >/dev/null && break
                sleep 1
            done
        "
    fi
}

launch_all() {
    for ((g=0; g<N_GPUS; g++)); do launch_gpu_session "$g"; done
}

# ----- 1. SSH reachable? -----
if ! ssh_run 'true' >/dev/null 2>&1; then
    echo "[checkin] FATAL: $SSH_HOST:$SSH_PORT unreachable"
    exit 0   # let caller decide; do not raise loudly here
fi

# ----- 2. Reboot detection -----
LAST_BOOT_FILE="/tmp/checkin_multi_last_boot.${SSH_HOST//[@\/]/_}"
remote_boot="$(ssh_run 'stat -c %Y /proc/1' 2>/dev/null || echo 0)"
last_boot="$(cat "$LAST_BOOT_FILE" 2>/dev/null || echo 0)"
if [[ "$remote_boot" != "0" && "$remote_boot" != "$last_boot" ]]; then
    if [[ "$last_boot" != "0" && "$remote_boot" -gt "$last_boot" ]]; then
        echo "[checkin] !! VM rebooted (PID 1 boot time changed: $last_boot -> $remote_boot). Relaunching all runners."
        # post-reboot, tmux is gone and fluent-bit may need a moment; the relaunch handles tmux.
        launch_all
    fi
    echo "$remote_boot" > "$LAST_BOOT_FILE"
fi

# ----- 3. Code-update detection -----
local_sha="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
remote_sha="$(ssh_run "$REMOTE_DIR/src/kt_filter_v8 --version 2>&1 | grep -oE 'sha=[a-f0-9]+' | head -1 | sed 's/sha=//'" 2>/dev/null || echo unknown)"
# v8 --version output format may not include sha=; fall back to file mtime check.
remote_mtime="$(ssh_run "stat -c %Y $REMOTE_DIR/src/kt_filter_v8 2>/dev/null" || echo 0)"
local_src_mtime="$(stat -c %Y "$REPO_ROOT/src/cuda/kt_filter_v8.cu" 2>/dev/null || echo 0)"

if [[ "$local_sha" != "unknown" && "$remote_sha" != "$local_sha" ]] || \
   [[ "$local_src_mtime" -gt "$remote_mtime" && "$remote_mtime" != "0" ]]; then
    echo "[checkin] code change detected (local=$local_sha remote=$remote_sha; local_src_mtime=$local_src_mtime remote_bin_mtime=$remote_mtime). Rebuilding."
    # IMPORTANT: only relaunch if the build actually succeeded. If the build
    # fails, the existing binary on the remote stays (build_remote.sh no
    # longer 'make clean's), so the running runners keep working on the old
    # binary. We must NOT kill them and try to relaunch — that's what bricked
    # the campaign on 2026-05-09 (build failed, runners got relaunched against
    # a binary that no longer existed, all GPUs went idle).
    if SSH_HOST="$SSH_HOST" SSH_PORT="$SSH_PORT" REMOTE_DIR="$REMOTE_DIR" TARGET=kt_filter_v8 \
            bash "$REPO_ROOT/longevity_gpu/scripts/build_remote.sh" 2>&1 | tail -8; then
        echo "[checkin] build succeeded — relaunching all runners on new binary"
        launch_all
    else
        echo "[checkin] !! BUILD FAILED — keeping existing runners on previous binary."
        echo "[checkin] !! Will retry on next tick. Inspect build_remote.sh stderr above for the cause."
    fi
fi

# ----- 4. Per-GPU liveness -----
# Circuit-breaker: only relaunch a session if the binary actually exists.
# Without this, a missing binary causes infinite relaunch attempts that
# spawn tmux sessions that immediately die (kt_filter_v8 ENOENT).
binary_exists="$(ssh_run "test -x $REMOTE_DIR/src/kt_filter_v8 && echo yes || echo no")"
if [[ "$binary_exists" != "yes" ]]; then
    echo "[checkin] !! $REMOTE_DIR/src/kt_filter_v8 is missing or non-executable — skipping per-GPU relaunch."
    echo "[checkin] !! Run 'bash longevity_gpu/scripts/build_remote.sh' manually to investigate."
else
    for ((g=0; g<N_GPUS; g++)); do
        if ! ssh_run "tmux has-session -t ktlong$g 2>/dev/null && pgrep -f \"kt_filter_v8.*--gpu-device $g\" >/dev/null"; then
            echo "[checkin] GPU $g session/process missing — relaunching"
            launch_gpu_session "$g"
        fi
    done
fi

# ----- 5. Per-GPU summary -----
echo "[checkin] === $(date -u +%FT%TZ) ==="
total_novel=0
for ((g=0; g<N_GPUS; g++)); do
    workdir="$REMOTE_DIR/gpu$g"
    if [[ "$CAMPAIGN_MODE" == "lowbits" ]]; then
        slot="pattern=$(pattern_for_gpu "$g")"
    else
        slot="bands=\"$(bands_for_gpu "$g")\""
    fi
    out=$(ssh_run "
        latest=\$(ls -1dt $workdir/runs/sweep_* 2>/dev/null | head -1)
        cells_done=\$(wc -l < \"\$latest/sweep_status.jsonl\" 2>/dev/null || echo 0)
        current_cell=\$(pgrep -af 'kt_filter_v8.*--gpu-device $g' | grep -oE 'KT[0-9]+_P[0-9]+ --bits [0-9]+' | head -1)
        # W19-B-6 (multi-angle P1-13): W18-K added a "[reporter] kills: ..."
        # diagnostic line that interleaves with the existing "[reporter] t=..."
        # status line.  `grep reporter | tail -1` would return the kills line
        # whenever it happened to be last, breaking the dashboard's parse of
        # the status-line fields.  Anchor the grep on the status-line prefix.
        last_reporter=\$(ls -1dt \$latest/KT* 2>/dev/null | head -1 | xargs -I{} sh -c 'grep "\[reporter\] t=" "{}/stdout.log" 2>/dev/null | tail -1')
        gpu_query=\$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used --format=csv,noheader,nounits -i $g 2>/dev/null | head -1)
        novel=\$(find $workdir -maxdepth 1 \\( -name 'novel_records.jsonl' -o -name 'novel_records_gpu*.jsonl' \\) -type f -exec wc -l {} + 2>/dev/null | awk '{s += \$1} END {print s+0}')
        nonempty_found=\$(find $workdir/runs -name found.txt -size +0c 2>/dev/null | wc -l)
        printf 'cells_done=%s|current=%s|gpu=%s|novel=%s|nonempty_found=%s|reporter=%s\n' \\
            \"\$cells_done\" \"\$current_cell\" \"\$gpu_query\" \"\$novel\" \"\$nonempty_found\" \"\$last_reporter\"
    " 2>/dev/null || echo "ssh-fail")
    novel_n=$(echo "$out" | grep -oE 'novel=[0-9]+' | head -1 | sed 's/novel=//')
    [[ "$novel_n" =~ ^[0-9]+$ ]] && total_novel=$((total_novel + novel_n))
    nef=$(echo "$out" | grep -oE 'nonempty_found=[0-9]+' | head -1 | sed 's/nonempty_found=//')
    if [[ "$novel_n" -gt 0 ]] || [[ "$nef" -gt 0 ]]; then
        echo "  !! GPU $g ($slot)  $out"
    else
        echo "  GPU $g ($slot)  $out"
    fi
done

# Fluent-bit single status line
fb_status=$(ssh_run 'systemctl is-active fluent-bit 2>/dev/null')
fb_conns=$(ssh_run "ss -tn state established \\( dport = :443 \\) 2>/dev/null | grep -c ${LOG_SERVER_IP:-<log-server-ip>}")
echo "[checkin] fluent-bit=$fb_status  conns_to_log_server=$fb_conns  total_novel_hits_across_gpus=$total_novel"

if [[ "$total_novel" -gt 0 ]]; then
    echo "[checkin] !!!!! NOVEL HIT(S) FOUND — pull novel_records*.jsonl from each GPU's WORKDIR for inspection !!!!!"
fi

# ----- 6. Coverage / progress report -----
if [[ "$CAMPAIGN_MODE" == "lowbits" ]]; then
    # For exhaustive sequential mode, the meaningful axes are:
    #   - per (pattern, bits): cells run, # exhausted, total elapsed sec, surv_total
    #   - per pattern: current ceiling (from .lowbits_state)
    echo "[checkin] --- lowbits exhaustive progress (across all GPUs) ---"
    raw=$(ssh_run "
      for G in 0 1 2 3; do
        [ -d $REMOTE_DIR/gpu\$G/runs ] || continue
        for J in $REMOTE_DIR/gpu\$G/runs/sweep_*/sweep_status.jsonl; do
          [ -f \"\$J\" ] || continue
          cat \"\$J\"
        done
      done
    " 2>/dev/null)
    # Each line is JSON; extract pattern, bits, elapsed, exhausted, surv, found_lines.
    echo "$raw" | awk '
        function jget(s, k,    pat, hit) {
            pat = "\"" k "\"[ ]*:[ ]*"
            if (match(s, pat "\"[^\"]*\"")) {
                hit = substr(s, RSTART, RLENGTH)
                sub(pat "\"", "", hit); sub("\"$", "", hit)
                return hit
            } else if (match(s, pat "[0-9-]+")) {
                hit = substr(s, RSTART, RLENGTH)
                sub(pat, "", hit)
                return hit
            }
            return ""
        }
        {
            p = jget($0, "pattern"); b = jget($0, "bits")
            if (p == "" || b == "") next
            key = p "_b" b
            cells[key]++
            ex = jget($0, "exhausted") + 0; if (ex) exhausted[key]++
            el = jget($0, "elapsed_sec") + 0; elapsed[key] += el
            fl = jget($0, "found_lines") + 0; found[key] += fl
        }
        END {
            for (k in cells) {
                printf "  %-25s  cells=%-3d exhausted=%-3d total_elapsed=%-7ds  found_lines=%d\n", \
                       k, cells[k], exhausted[k]+0, elapsed[k]+0, found[k]+0
            }
        }
    ' | sort
    echo "[checkin] --- per-GPU current ceiling ---"
    ssh_run "
      for G in 0 1 2 3; do
        [ -f $REMOTE_DIR/gpu\$G/.lowbits_state ] || continue
        ceil=\$(cat $REMOTE_DIR/gpu\$G/.lowbits_state)
        echo \"  gpu\$G  BITS_HIGH=\$ceil\"
      done
    " 2>/dev/null
    echo "[checkin] (exhausted count = cells that emitted PREFIX EXHAUSTED; if exhausted < cells, the cell hit PER_CELL_MAX_SEC before completing — bump the cap or the search space is just larger than expected)"
else
    # Anchor-coverage report (bands mode, v8 random sequential walk).
    echo "[checkin] --- anchor coverage (across all GPUs, all sweeps still on disk) ---"
    raw=$(ssh_run "
      for G in 0 1 2 3; do
        [ -d $REMOTE_DIR/gpu\$G/runs ] || continue
        for D in $REMOTE_DIR/gpu\$G/runs/sweep_*/KT*; do
          [ -d \"\$D\" ] || continue
          anchor=\$(grep -m1 '^\\[search\\] anchor=' \"\$D/stdout.log\" 2>/dev/null | sed 's/.*anchor=//; s/ .*//')
          cell_id=\$(basename \"\$D\")
          key=\$(echo \"\$cell_id\" | grep -oE '^KT[0-9]+_P[0-9]+_b[0-9]+')
          surv=\$(grep -m1 '=== final:' \"\$D/stdout.log\" 2>/dev/null | grep -oE 'surv=[0-9]+' | head -1 | sed 's/surv=//')
          hits=\$(grep -m1 '=== final:' \"\$D/stdout.log\" 2>/dev/null | grep -oE 'hits=[0-9]+' | head -1 | sed 's/hits=//')
          [ -n \"\$anchor\" ] && [ -n \"\$key\" ] && printf '%s\t%s\t%s\t%s\t%s\n' \"\$key\" \"\$anchor\" \"gpu\$G\" \"\${surv:-?}\" \"\${hits:-?}\"
        done
      done
    " 2>/dev/null)
    echo "$raw" | awk -F'\t' '
        NF<2 { next }
        { keys[$1]++; akey=$1"|"$2; anchors[akey]=1; surv_sum[$1]+=($4=="?"?0:$4); hits_sum[$1]+=($5=="?"?0:$5); last_anchor[$1]=$2 }
        END {
            for (k in keys) {
                n_distinct=0
                for (a in anchors) {
                    split(a, parts, "|")
                    if (parts[1] == k) n_distinct++
                }
                printf "  %-22s  cells=%-3d distinct_anchors=%-3d surv_total=%-4d hits=%d  last_anchor=%s\n", k, keys[k], n_distinct, surv_sum[k], hits_sum[k], last_anchor[k]
            }
        }
    ' | sort
    echo "[checkin] (surv_total>0 means a post-Fermat-2 candidate reached host BPSW — that's our 'near-hit' signal; CC-search analog is CC10/CC11 partial chains)"
fi
