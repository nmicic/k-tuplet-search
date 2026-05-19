#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# run_lowbits.sh — exhaustive low-bit sweep for one (pattern, GPU) on the
# longevity GPU server. Walks bits sequentially from BITS_FLOOR up through
# BITS_HIGH, runs kt_filter_v8 with --exhaustive (which emits "PREFIX
# EXHAUSTED" on natural completion), then bumps the ceiling by BITS_BAND_STEP
# and restarts on the next band.
#
# Per-GPU layout (mirrors run_matrix.sh):
#   $WORKDIR/src/kt_filter_v8                shared binary (symlink in)
#   $WORKDIR/runs/<sweep>/<run_id>/{stdout.log,found.txt,meta.json}
#   $WORKDIR/runs/<sweep>/sweep_status.jsonl one line per completed cell
#   $WORKDIR/runs/matrix_status.jsonl        symlink to current sweep
#   $WORKDIR/novel_records_gpu${GPU_ID}.jsonl aggregator sink (engine fsync's)
#   $WORKDIR/.lowbits_state                  current ceiling, persisted
#   $WORKDIR/runner.log                      this script's stderr
#
# Env (required):
#   WORKDIR         per-GPU workdir (e.g. /root/kt/gpu0)
#   PATTERN         e.g. KT22_P3
#   GPU_ID          0..N-1
# Env (optional):
#   KT_PRIMORIAL          default 14 (47# wheel)
#   KT_WHEEL_EXPR         optional; overrides KT_PRIMORIAL, e.g. 47#/31
#   BITS_FLOOR            default 60 (47# wheel period ≈ 2^59 — below this the bit range
#                         contains <1 wheel period and the search is empty)
#   BITS_INITIAL_CEIL     default 127 (effectively infinite — the runner walks bits
#                         monotonically up; we will never reach 127 in practice, but
#                         setting a real number lets the band loop terminate cleanly
#                         per pass instead of walking with an unbounded ceiling)
#   BITS_BAND_STEP        default 4  (raise ceiling by this each pass — irrelevant
#                         when BITS_INITIAL_CEIL is far above achievable bits)
#   PER_CELL_MAX_SEC      default 0 (no cap — exhaustive cells run to PREFIX EXHAUSTED
#                         naturally, which is the whole point of sequential mode; the
#                         old 7200 s default truncated cells just before they finished
#                         at b80+ and produced "exhausted=0" rows that contributed no
#                         coverage. A value > 0 is honoured as both --max-time on the
#                         engine and the bash `timeout` wrapper. Random mode would
#                         use a positive value here as a session size, but exhaustive
#                         mode wants 0.)
#   GPU_BATCH_SIZE        default 2097152 (2^21, v8 anchor)
#   GPU_STREAMS           default 3
set -euo pipefail

WORKDIR="${WORKDIR:?need WORKDIR}"
PATTERN="${PATTERN:?need PATTERN}"
GPU_ID="${GPU_ID:?need GPU_ID}"
KT_PRIMORIAL="${KT_PRIMORIAL:-14}"
KT_WHEEL_EXPR="${KT_WHEEL_EXPR:-}"
BITS_FLOOR="${BITS_FLOOR:-60}"
BITS_INITIAL_CEIL="${BITS_INITIAL_CEIL:-127}"
BITS_BAND_STEP="${BITS_BAND_STEP:-4}"
PER_CELL_MAX_SEC="${PER_CELL_MAX_SEC:-0}"
GPU_BATCH_SIZE="${GPU_BATCH_SIZE:-2097152}"
GPU_STREAMS="${GPU_STREAMS:-3}"
BIN="${BIN:-$WORKDIR/src/kt_filter_v8}"
NOVEL_JSONL="${KT_NOVEL_JSONL:-$WORKDIR/novel_records_gpu${GPU_ID}.jsonl}"

mkdir -p "$WORKDIR/runs" "$WORKDIR/logs"
exec > >(tee -a "$WORKDIR/runner.log") 2>&1

if [[ ! -x "$BIN" ]]; then
    echo "[runner] FATAL: $BIN not found / not executable. Run build_remote.sh first."
    exit 2
fi

# Per-GPU sampler (one-minute cadence, single GPU only — multi-GPU samplers
# from sister sessions won't fight over a shared file because each writes its
# own gpu_samples.jsonl in its own WORKDIR).
sampler_loop() {
    local out="$WORKDIR/gpu_samples.jsonl"
    while :; do
        local ts util tempC pwr mem_used
        IFS=, read -r util tempC pwr mem_used < <(
            nvidia-smi -i "$GPU_ID" --query-gpu=utilization.gpu,temperature.gpu,power.draw,memory.used \
                       --format=csv,noheader,nounits 2>/dev/null | head -1
        ) || true
        ts="$(date -u +%FT%TZ)"
        printf '{"ts":"%s","gpu":"%s","util_pct":%s,"temp_c":%s,"power_w":%s,"mem_used_mib":%s}\n' \
            "$ts" "$GPU_ID" "${util// /}" "${tempC// /}" "${pwr// /}" "${mem_used// /}" >> "$out"
        sleep 60
    done
}
if ! pgrep -f "sampler_loop.*GPU_ID=$GPU_ID" >/dev/null 2>&1; then
    ( sampler_loop ) &
    echo "[runner] sampler PID=$! (gpu=$GPU_ID)"
fi

run_cell() {
    local sweep="$1" pattern="$2" bits="$3"
    local started_iso; started_iso="$(date -u +%FT%TZ)"
    local started_epoch=$SECONDS
    local run_id="${pattern}_b${bits}_$(date -u +%Y%m%dT%H%M%SZ)"
    local rd="$WORKDIR/runs/$sweep/$run_id"
    mkdir -p "$rd"
    local stdout="$rd/stdout.log"
    local found="$rd/found.txt"

    local primorial_json="$KT_PRIMORIAL"
    [[ -n "$primorial_json" ]] || primorial_json=null
    cat > "$rd/meta.json" <<EOF
{"run_id":"$run_id","sweep":"$sweep","pattern":"$pattern","bits":$bits,"primorial":$primorial_json,"wheel_expr":"$KT_WHEEL_EXPR","mode":"exhaustive","binary":"$(basename "$BIN")","started":"$started_iso","host":"$(hostname)","gpu":$GPU_ID,"per_cell_max_sec":$PER_CELL_MAX_SEC,"novel_jsonl":"$NOVEL_JSONL"}
EOF

    echo "[runner] === $run_id (gpu=$GPU_ID pattern=$pattern bits=$bits MODE=exhaustive cap=${PER_CELL_MAX_SEC}s) ==="

    set +e
    cd "$WORKDIR/src"
    # Build engine + wrapper invocation. PER_CELL_MAX_SEC=0 (default for
    # exhaustive) means: no --max-time on engine, no `timeout` wrapper —
    # the cell runs until PREFIX EXHAUSTED. A positive value applies both
    # as --max-time and as a bash timeout (with +60 s grace for the engine
    # to drain). Use a positive value only when running in --random mode
    # or when you genuinely need a session-size cap.
    # Diagnostic instrumentation. We are still in experimentation phase, so
    # enable as many of the optional observability flags as are cheap to keep
    # on. Each writes its own bench/ JSONL on engine shutdown:
    #   --enable-f18-yield     per-(line_prime,residue) kill-rate counters
    #   --enable-f22-reservoir 1000-slot post-Fermat reservoir w/ payload
    #   --enable-f23-texture   128-slot texture reservoir (cross-check vs f22)
    # f24 (cascade kill-rate) is host-only stderr and clutters runner.log
    # without persisting, intentionally OFF.
    #
    # Phase 9 T1.2 checkpoint/resume (verified working as of e3eb988 via
    # drain-boundary invariant added W18-B). Stable checkpoint
    # path per (pattern, bits) so a graceful-shutdown mid-cell — by tmux
    # kill on rebuild, by clean SIGTERM/SIGINT, by VM-reboot drain — resumes
    # from the most recent ckpt-interval save instead of restarting the
    # bit's full search from scratch. SIGKILL mid-flight is safe in the
    # sense that the saved (cursor, totals) tuple is internally consistent
    # (W18-B drain-boundary), so resume re-launches the in-flight batches
    # without skipping work — but it may re-emit hits found in those
    # batches (downstream log dedupes). The engine validates (bits,
    # target_k, pattern, prefix, lanes, lane_id) on resume and soft-fails
    # to fresh-start on mismatch, so a stale checkpoint from a different
    # cell can't corrupt this run.
    #
    # Pass --resume only when the checkpoint exists and is non-empty. Pass
    # --checkpoint always so even fresh starts emit periodic saves.
    # Cleanup: after PREFIX EXHAUSTED, delete the checkpoint — the cell is
    # done, and a stale "exhausted=1" checkpoint would cause the next
    # invocation at the same (pattern, bits) to early-exit without doing
    # work (operator-confusing if .lowbits_state ever gets reset).
    local ckpt_dir="$WORKDIR/checkpoints"
    mkdir -p "$ckpt_dir"
    # W18-C + wheel-expr: include wheel identity in the ckpt filename so
    # re-runs that change KT_PRIMORIAL or KT_WHEEL_EXPR don't reuse the
    # previous wheel's checkpoint and trigger the resume soft-fail every time.
    local wheel_tag
    if [[ -n "$KT_WHEEL_EXPR" ]]; then
        # Non-alphanumeric chars are mapped one-by-one, so 47#/31 becomes
        # w47__31. This is intentional and collision-free for valid grammar.
        wheel_tag="w$(printf '%s' "$KT_WHEEL_EXPR" | tr -c 'A-Za-z0-9' '_')"
    else
        wheel_tag="p${KT_PRIMORIAL}"
    fi
    local ckpt_file="$ckpt_dir/${pattern}_${wheel_tag}_b${bits}.ckpt"

    local engine_args=(
        --pattern "$pattern" --bits "$bits" --exhaustive
        --gpu-device "$GPU_ID"
        --gpu-batch-size "$GPU_BATCH_SIZE" --gpu-streams "$GPU_STREAMS"
        --enable-f18-yield
        --enable-f22-reservoir
        --enable-f23-texture
        --checkpoint "$ckpt_file"
        --ckpt-interval 60
        --output "$found"
    )
    if [[ -n "$KT_WHEEL_EXPR" ]]; then
        engine_args+=(--wheel-expr "$KT_WHEEL_EXPR")
    else
        engine_args+=(--primorial "$KT_PRIMORIAL")
    fi
    if [[ -s "$ckpt_file" ]]; then
        engine_args+=(--resume "$ckpt_file")
        echo "[runner] resuming bits=$bits from checkpoint $(basename "$ckpt_file") ($(stat -c %s "$ckpt_file") bytes)"
    fi
    if [[ "$PER_CELL_MAX_SEC" -gt 0 ]]; then
        engine_args+=(--max-time "$PER_CELL_MAX_SEC")
        KT_NOVEL_JSONL="$NOVEL_JSONL" \
        KT_RUNNER_CELL_ID="$run_id" \
            timeout --foreground --kill-after=20 $((PER_CELL_MAX_SEC + 60)) \
            "$BIN" "${engine_args[@]}" > "$stdout" 2>&1
    else
        KT_NOVEL_JSONL="$NOVEL_JSONL" \
        KT_RUNNER_CELL_ID="$run_id" \
            "$BIN" "${engine_args[@]}" > "$stdout" 2>&1
    fi
    local rc=$?
    set -e

    local ended_iso; ended_iso="$(date -u +%FT%TZ)"
    local elapsed=$(( SECONDS - started_epoch ))
    local exhausted=0
    # Engine prints "[exhaustive] PREFIX <value> EXHAUSTED at <ts>..." where
    # <value> is the prefix (or "n/a" when --prefix is not given). Match the
    # whole pattern so the no-prefix case (our default) is detected.
    grep -qE 'PREFIX [^ ]+ EXHAUSTED at' "$stdout" 2>/dev/null && exhausted=1
    # Cleanup: cell genuinely complete, drop the checkpoint so a hypothetical
    # future invocation at the same (pattern, bits) starts fresh instead of
    # short-circuiting via the persisted exhausted=1 flag.
    if [[ "$exhausted" -eq 1 && -f "$ckpt_file" ]]; then
        rm -f "$ckpt_file"
    fi
    local found_lines; found_lines=$(wc -l < "$found" 2>/dev/null || echo 0)
    local tail_excerpt
    tail_excerpt="$(tail -10 "$stdout" | tr '\n' '\f' | sed 's/"/\\"/g' || true)"

    printf '{"sweep":"%s","run_id":"%s","pattern":"%s","bits":%d,"primorial":%s,"wheel_expr":"%s","started":"%s","ended":"%s","elapsed_sec":%d,"rc":%d,"exhausted":%d,"found_lines":%s,"stdout_tail":"%s"}\n' \
        "$sweep" "$run_id" "$pattern" "$bits" "$primorial_json" "$KT_WHEEL_EXPR" \
        "$started_iso" "$ended_iso" "$elapsed" "$rc" "$exhausted" "$found_lines" "$tail_excerpt" \
        >> "$WORKDIR/runs/$sweep/sweep_status.jsonl"

    echo "[runner] -- $run_id rc=$rc elapsed=${elapsed}s exhausted=$exhausted found_lines=$found_lines"
}

# State: persists three numbers across runner restarts —
#   floor    : lower bound of the current band
#   high     : upper bound of the current band
#   current  : NEXT bits value to scan within [floor..high]
# Format: a single line "floor=N high=N current=N" (whitespace-separated).
# Backwards-compat: a single integer (legacy format) is treated as `high`,
# with floor=$BITS_FLOOR and current=$BITS_FLOOR — the same as a fresh start
# at the bottom of the band.
#
# Why this exists: --checkpoint/--resume in kt_filter_v8 is documented but
# implemented as a no-op (`Checkpoint: ... [accepted, no-op in 3a]`), so
# engine-level resume isn't available. Without runner-level state, every
# rebuild-driven restart replays bits 60..N-1 (which are cheap individually
# but compound into hours of redundant work over a day). Tracking `current`
# means a restart picks up exactly where the previous process died.
STATE_FILE="$WORKDIR/.lowbits_state"
BITS_INITIAL_FLOOR="$BITS_FLOOR"

read_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        BITS_HIGH="$BITS_INITIAL_CEIL"
        BITS_CURRENT="$BITS_FLOOR"
        write_state
        echo "[runner] fresh state: floor=$BITS_FLOOR high=$BITS_HIGH current=$BITS_CURRENT"
        return
    fi
    local raw; raw="$(cat "$STATE_FILE")"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        BITS_HIGH="$raw"
        BITS_CURRENT="$BITS_FLOOR"
        echo "[runner] migrating legacy state file (was a bare BITS_HIGH=$BITS_HIGH; resetting current=$BITS_CURRENT)"
        write_state
        return
    fi
    local f h c
    f=$(echo "$raw" | grep -oE 'floor=[0-9]+' | sed 's/floor=//')
    h=$(echo "$raw" | grep -oE 'high=[0-9]+'  | sed 's/high=//')
    c=$(echo "$raw" | grep -oE 'current=[0-9]+' | sed 's/current=//')
    BITS_FLOOR="${f:-$BITS_FLOOR}"
    BITS_HIGH="${h:-$BITS_INITIAL_CEIL}"
    BITS_CURRENT="${c:-$BITS_FLOOR}"
    # Sanity: if BITS_CURRENT got persisted somehow above BITS_HIGH (e.g. a
    # crash mid-bump), recover by treating the band as already complete.
    if (( BITS_CURRENT > BITS_HIGH )); then
        BITS_FLOOR=$((BITS_HIGH + 1))
        BITS_HIGH=$((BITS_HIGH + BITS_BAND_STEP))
        BITS_CURRENT="$BITS_FLOOR"
        write_state
        echo "[runner] recovered from inconsistent state: bumped to floor=$BITS_FLOOR high=$BITS_HIGH current=$BITS_CURRENT"
        return
    fi
    echo "[runner] resumed state: floor=$BITS_FLOOR high=$BITS_HIGH current=$BITS_CURRENT"
}

write_state() {
    echo "floor=$BITS_FLOOR high=$BITS_HIGH current=$BITS_CURRENT" > "$STATE_FILE"
}

read_state

echo "[runner] starting low-bits exhaustive sweep at $(date -u +%FT%TZ): pattern=$PATTERN gpu=$GPU_ID primorial=$KT_PRIMORIAL"
echo "[runner] band rule: walk current..high inclusive, then floor=high+1, high+=$BITS_BAND_STEP, current=floor"

while :; do
    sweep="sweep_$(date -u +%Y%m%dT%H%M%SZ)_b${BITS_FLOOR}-${BITS_HIGH}"
    mkdir -p "$WORKDIR/runs/$sweep"
    : > "$WORKDIR/runs/$sweep/sweep_status.jsonl"
    ln -sfn "$sweep/sweep_status.jsonl" "$WORKDIR/runs/matrix_status.jsonl"
    echo "[runner] >>> sweep $sweep (pattern=$PATTERN bits=$BITS_CURRENT..$BITS_HIGH; band=$BITS_FLOOR..$BITS_HIGH)"

    for bits in $(seq "$BITS_CURRENT" "$BITS_HIGH"); do
        BITS_CURRENT="$bits"
        write_state
        run_cell "$sweep" "$PATTERN" "$bits" || true
    done

    echo "[runner] <<< sweep $sweep complete; raising ceiling by $BITS_BAND_STEP"
    BITS_FLOOR=$((BITS_HIGH + 1))
    BITS_HIGH=$((BITS_HIGH + BITS_BAND_STEP))
    BITS_CURRENT="$BITS_FLOOR"
    write_state
done
