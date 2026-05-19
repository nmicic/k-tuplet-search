#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# run_matrix.sh — longevity matrix runner for kt_filter on GPU.
# Lives on the remote GPU server. Loops the matrix forever (until killed),
# recording one log per (k, pattern, bits) cell and a JSONL status stream.
#
# Layout (under $WORKDIR, default /root/kt_longevity):
#   src/kt_filter                          binary (built by build_remote.sh)
#   runs/<sweep>/<run_id>/stdout.log       per-run stdout
#   runs/<sweep>/<run_id>/found.txt        --output sink (kt_filter)
#   runs/<sweep>/<run_id>/meta.json        per-run metadata
#   runs/<sweep>/sweep_status.jsonl        one line per completed run
#   runs/matrix_status.jsonl               (symlink to current sweep status)
#   novel_records.jsonl or novel_records_gpuN.jsonl
#                                           fsync'd by kt_filter; aggregated
#   gpu_samples.jsonl                      nvidia-smi snapshots (1/min)
#   runner.log                             this script's own stderr
#
# Bit bands (per the operator plan, capped at 119 to stay clear of G1):
#   k record_bits: tested at record+3, +8, +15  (capped at 110)
#   k=22..24 (no record): 95, 105, 115
set -euo pipefail

WORKDIR="${WORKDIR:-/root/kt_longevity}"
BIN="${BIN:-$WORKDIR/src/kt_filter_v8}"   # v8 default (phase-v8-Sobs)
DURATION_SEC="${DURATION_SEC:-300}"    # 5 min per cell (was 1800); shorter cells create more
                                       # seed-anchor jumps per hour under v8's random-then-
                                       # sequential walk model.
CHUNK_TILES="${CHUNK_TILES:-500}"
BIT_CAP="${BIT_CAP:-119}"
GPU_STREAMS="${GPU_STREAMS:-3}"        # stream pool depth
GPU_BATCH_SIZE="${GPU_BATCH_SIZE:-2097152}"   # 2^21 + 3 streams = v8 anchor

# Optional: multi-GPU campaigns. Set GPU_ID=N to pin one runner to one device.
# Convention: each GPU gets its own WORKDIR (e.g. WORKDIR=/root/kt/gpu0) so the
# per-cell runs/ tree, runner.log, and novel_records.jsonl don't collide.
GPU_ID="${GPU_ID:-}"
if [[ -n "$GPU_ID" ]]; then
    NOVEL_JSONL="${KT_NOVEL_JSONL:-$WORKDIR/novel_records_gpu${GPU_ID}.jsonl}"
else
    NOVEL_JSONL="${KT_NOVEL_JSONL:-$WORKDIR/novel_records.jsonl}"
fi

# Optional: wheel size. KT_PRIMORIAL=11 (default, 37#) is v8 production baseline;
# 12 = 41#, 13 = 43#, 14 = 47#. Higher = larger admissible-residue table.
# KT_WHEEL_EXPR overrides KT_PRIMORIAL, e.g. KT_WHEEL_EXPR='47#/31'.
KT_PRIMORIAL="${KT_PRIMORIAL:-}"
KT_WHEEL_EXPR="${KT_WHEEL_EXPR:-}"

mkdir -p "$WORKDIR/runs" "$WORKDIR/logs"
exec > >(tee -a "$WORKDIR/runner.log") 2>&1

if [[ ! -x "$BIN" ]]; then
    echo "[FATAL] $BIN not found / not executable. Run build_remote.sh first."
    exit 2
fi

# k → space-separated patterns (catalog as of this build)
declare -A PATTERNS=(
    [16]="KT16_P0 KT16_P1"
    [17]="KT17_P0 KT17_P1 KT17_P2 KT17_P3"
    [18]="KT18_P0 KT18_P1"
    [19]="KT19_P0 KT19_P1 KT19_P2 KT19_P3"
    [20]="KT20_P0 KT20_P1"
    [21]="KT21_P0 KT21_P1"
    [22]="KT22_P0 KT22_P1"
    [23]="KT23_P0"
    [24]="KT24_P0 KT24_P1 KT24_P2"
)

# k → record bits (from records.json). 0 = no record yet. Kept for reference;
# matrix bands now controlled by BANDS env var (default = 95+ territory only).
declare -A REC_BITS=([16]=66 [17]=71 [18]=81 [19]=88 [20]=92 [21]=95 [22]=0 [23]=0 [24]=0)

# Bit bands. Default targets >=95 bits per operator decision: lower territory
# is considered scanned by older programs (Forbes/Waldvogel/Chermoni-Jaroslaw/
# Armitage 1997-2026). Override with BANDS env, e.g.
#   BANDS="98 101 105 110" bash run_matrix.sh
BANDS_DEFAULT="${BANDS:-95 101 110 119}"

# k filter. Default sweeps every k 16..24; pass K_FILTER (space-separated)
# to restrict, e.g. K_FILTER="19 20 21 22 23 24" for the high-k novelty pass.
K_FILTER_DEFAULT="${K_FILTER:-16 17 18 19 20 21 22 23 24}"

bands_for_k() {
    local k="$1" out=()
    for b in $BANDS_DEFAULT; do
        (( b > BIT_CAP )) && b=$BIT_CAP
        (( b < 70 )) && b=70    # respect line-sieve floor (G2)
        out+=("$b")
    done
    echo "${out[@]}"
}

# Background nvidia-smi sampler: one JSON line per minute.
sampler_loop() {
    local out="$WORKDIR/gpu_samples.jsonl"
    while :; do
        local ts util tempC pwr mem_used mem_total
        local smi_args=()
        [[ -n "$GPU_ID" ]] && smi_args=(-i "$GPU_ID")
        IFS=, read -r util tempC pwr mem_used mem_total < <(
            nvidia-smi "${smi_args[@]}" --query-gpu=utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total \
                       --format=csv,noheader,nounits 2>/dev/null | head -1
        ) || true
        ts="$(date -u +%FT%TZ)"
        printf '{"ts":"%s","util_pct":%s,"temp_c":%s,"power_w":%s,"mem_used_mib":%s,"mem_total_mib":%s}\n' \
            "$ts" "${util// /}" "${tempC// /}" "${pwr// /}" "${mem_used// /}" "${mem_total// /}" >> "$out"
        sleep 60
    done
}

# Start sampler if not already running
if ! pgrep -f 'sampler_loop' >/dev/null 2>&1; then
    ( sampler_loop ) &
    SAMPLER_PID=$!
    echo "[runner] sampler PID=$SAMPLER_PID"
fi

run_cell() {
    local sweep="$1" k="$2" pattern="$3" bits="$4"
    local run_id="${pattern}_b${bits}_$(date -u +%Y%m%dT%H%M%SZ)"
    local rd="$WORKDIR/runs/$sweep/$run_id"
    mkdir -p "$rd"
    local meta="$rd/meta.json"
    local stdout="$rd/stdout.log"
    local found="$rd/found.txt"
    local started_iso; started_iso="$(date -u +%FT%TZ)"
    local started_epoch=$SECONDS

    local primorial_json="$KT_PRIMORIAL"
    [[ -n "$primorial_json" ]] || primorial_json=null
    cat > "$meta" <<EOF
{"run_id":"$run_id","sweep":"$sweep","k":$k,"pattern":"$pattern","bits":$bits,"duration_sec":$DURATION_SEC,"chunk_tiles":$CHUNK_TILES,"gpu_streams":$GPU_STREAMS,"gpu_batch_size":$GPU_BATCH_SIZE,"primorial":$primorial_json,"wheel_expr":"$KT_WHEEL_EXPR","binary":"$(basename "$BIN")","started":"$started_iso","host":"$(hostname)"}
EOF

    echo "[runner] === $run_id  (k=$k pattern=$pattern bits=$bits dur=${DURATION_SEC}s) ==="

    # Run kt_filter; tolerate non-zero exit (we want to keep matrix going)
    set +e
    cd "$WORKDIR/src"
    extra_args=(--gpu-batch-size "$GPU_BATCH_SIZE" --gpu-streams "$GPU_STREAMS")
    [[ -n "$GPU_ID" ]] && extra_args+=(--gpu-device "$GPU_ID")
    if [[ -n "$KT_WHEEL_EXPR" ]]; then
        extra_args+=(--wheel-expr "$KT_WHEEL_EXPR")
    elif [[ -n "$KT_PRIMORIAL" ]]; then
        extra_args+=(--primorial "$KT_PRIMORIAL")
    fi
    # Always enable F22 reservoir: zero kernel-path cost when no candidate
    # reaches Fermat-2 (the steady state at k=19 high-bits), captures up to
    # 1000 post-Fermat-2 survivors with full payload when any do reach it.
    # Output goes to bench/reservoir_kt_filter_v8_<pid>.jsonl in cwd.
    extra_args+=(--enable-f22-reservoir)
    KT_NOVEL_JSONL="$NOVEL_JSONL" \
    KT_RUNNER_CELL_ID="$run_id" \
        timeout --foreground --kill-after=20 $((DURATION_SEC + 60)) \
        "$BIN" --pattern "$pattern" --bits "$bits" --random \
               --chunk-tiles "$CHUNK_TILES" \
               "${extra_args[@]}" \
               --max-time "$DURATION_SEC" \
               --output "$found" \
               > "$stdout" 2>&1
    local rc=$?
    set -e

    local ended_iso; ended_iso="$(date -u +%FT%TZ)"
    local elapsed=$(( SECONDS - started_epoch ))

    # Pull last "RATE" / throughput / candidates lines from stdout for status
    local tail_excerpt
    tail_excerpt="$(tail -30 "$stdout" | tr '\n' '\f' | sed 's/"/\\"/g' || true)"
    local found_lines; found_lines=$(wc -l < "$found" 2>/dev/null || echo 0)

    printf '{"sweep":"%s","run_id":"%s","k":%d,"pattern":"%s","bits":%d,"primorial":%s,"wheel_expr":"%s","started":"%s","ended":"%s","elapsed_sec":%d,"rc":%d,"found_lines":%s,"stdout_tail":"%s"}\n' \
        "$sweep" "$run_id" "$k" "$pattern" "$bits" "$primorial_json" "$KT_WHEEL_EXPR" "$started_iso" "$ended_iso" \
        "$elapsed" "$rc" "$found_lines" "$tail_excerpt" \
        >> "$WORKDIR/runs/$sweep/sweep_status.jsonl"

    echo "[runner] -- $run_id rc=$rc elapsed=${elapsed}s found_lines=$found_lines"
}

run_sweep() {
    local sweep="sweep_$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$WORKDIR/runs/$sweep"
    : > "$WORKDIR/runs/$sweep/sweep_status.jsonl"
    ln -sfn "$sweep/sweep_status.jsonl" "$WORKDIR/runs/matrix_status.jsonl"
    echo "[runner] >>> sweep $sweep starting"

    # Loop order: k → bits → pattern. Each band level visits every pattern
    # before climbing to the next bit count (band-outer, pattern-inner).
    for k in $K_FILTER_DEFAULT; do
        for bits in $(bands_for_k "$k"); do
            for pattern in ${PATTERNS[$k]}; do
                run_cell "$sweep" "$k" "$pattern" "$bits" || true
            done
        done
    done

    echo "[runner] <<< sweep $sweep complete"
}

# Main loop: keep sweeping until told to stop.
echo "[runner] starting matrix loop at $(date -u +%FT%TZ)"
while :; do
    run_sweep
    echo "[runner] sweep finished, looping again in 30s"
    sleep 30
done
