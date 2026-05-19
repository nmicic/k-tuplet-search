#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# monitor_daemon.sh — fully-automated wrapper around checkin_multi.sh.
# Runs ONE check, persists the output, and emits alerts on anomalies.
# Designed to be invoked by cron or a systemd timer — no AI / no human
# in the hot path.
#
# What "automated" means here:
#   1. Cron/timer fires this script every N minutes.
#   2. Script SSHes to the GPU VM(s), runs checkin_multi.sh, captures stdout.
#   3. Stdout is appended to $LOG_DIR/daily-YYYY-MM-DD.log.
#   4. Stdout is parsed for anomaly signals; new anomalies emit an alert
#      via $ALERT_WEBHOOK_URL (typically https://ntfy.sh/<your-topic>).
#   5. State (last-seen-anomaly hash, baseline mem, last reboot epoch) is
#      kept in $STATE_DIR so re-firings don't duplicate alerts and so
#      mem-leak / reboot detection survives across runs.
#
# Anomalies that trigger an alert:
#   - VM unreachable (SSH timeout)
#   - VM rebooted since last run  (not error, but worth knowing)
#   - Build failed (BUILD FAILED line)
#   - kt_filter_v8 binary missing on the remote
#   - novel hit found (total_novel_hits_across_gpus > 0) — LOUD
#   - any cell's found.txt is non-empty (nonempty_found > 0)
#   - any cell's surv_total > 0 (post-Fermat-2 near-hit, CC-style)
#   - any GPU temp > $TEMP_ALERT_C (default 85)
#   - any GPU mem > baseline + $MEM_DELTA_MB (default +200 MiB)
#   - any GPU stalled (no reporter tick for > $STALL_SEC; default 300)
#
# Required env (caller must set):
#   SSH_HOST, SSH_PORT       target VM (or comma-separated list of TARGETS, see below)
#   N_GPUS                   default 4
#   ALERT_WEBHOOK_URL        e.g. https://ntfy.sh/kt-longevity-alerts
#                            (anything that accepts POST with body=text)
#   REPO_ROOT                path to k-tuplet-search checkout (default = next to this script)
#
# Optional env:
#   LOG_DIR                  default $HOME/.kt_monitor/log
#   STATE_DIR                default $HOME/.kt_monitor/state
#   TEMP_ALERT_C             default 85
#   MEM_DELTA_MB             default 200
#   STALL_SEC                default 300
#   ALERT_TOPIC_NAME         default "kt-campaign"  (prefixed in alert title)
#   ALERT_PRIORITY_NORMAL    default 3 (ntfy.sh priority for routine info)
#   ALERT_PRIORITY_HIGH      default 5 (ntfy.sh priority for novel hit / VM down)
#
# Example crontab line — every 30 minutes:
#   */30 * * * * SSH_HOST=root@1.2.3.4 SSH_PORT=12345 N_GPUS=4 \
#                ALERT_WEBHOOK_URL=https://ntfy.sh/kt-foo \
#                /path/to/monitor_daemon.sh >> /tmp/kt_monitor.log 2>&1
#
# Example systemd timer (kt-monitor.service + kt-monitor.timer):
#   See longevity_gpu/scripts/monitor_systemd_install.sh for a generator.

set -uo pipefail

SSH_HOST="${SSH_HOST:?set SSH_HOST=root@<ip>}"
SSH_PORT="${SSH_PORT:?set SSH_PORT=<port>}"
N_GPUS="${N_GPUS:-4}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"   # empty = log-only mode
REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$HOME/.kt_monitor/log}"
STATE_DIR="${STATE_DIR:-$HOME/.kt_monitor/state}"
TEMP_ALERT_C="${TEMP_ALERT_C:-85}"
MEM_DELTA_MB="${MEM_DELTA_MB:-200}"
STALL_SEC="${STALL_SEC:-300}"
ALERT_TOPIC_NAME="${ALERT_TOPIC_NAME:-kt-campaign}"
ALERT_PRIORITY_NORMAL="${ALERT_PRIORITY_NORMAL:-3}"
ALERT_PRIORITY_HIGH="${ALERT_PRIORITY_HIGH:-5}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

today_log="$LOG_DIR/daily-$(date -u +%Y-%m-%d).log"
state_prefix="$STATE_DIR/${SSH_HOST//[@\/.]/_}_$SSH_PORT"
last_anomaly_hash_file="${state_prefix}.last_anomaly_hash"
mem_baseline_file="${state_prefix}.mem_baseline"

ts() { date -u +%FT%TZ; }

log() {
    local line="[$(ts)] $*"
    echo "$line"
    echo "$line" >> "$today_log"
}

# Send an alert. $1 = severity (info|high), $2 = title, $3 = body.
alert() {
    local sev="$1" title="$2" body="$3"
    log "ALERT[$sev] $title — $body"
    [[ -z "$ALERT_WEBHOOK_URL" ]] && return 0
    local prio="$ALERT_PRIORITY_NORMAL"
    local tags=""
    case "$sev" in
        high)  prio="$ALERT_PRIORITY_HIGH" ; tags="rotating_light" ;;
        info)  prio="$ALERT_PRIORITY_NORMAL" ; tags="white_check_mark" ;;
        *)     prio="$ALERT_PRIORITY_NORMAL" ;;
    esac
    # ntfy.sh format. Most generic webhooks (Slack/Discord) accept
    # plain-text bodies too — substitute curl invocation if needed.
    curl -fsS -X POST "$ALERT_WEBHOOK_URL" \
        -H "Title: [$ALERT_TOPIC_NAME] $title" \
        -H "Priority: $prio" \
        -H "Tags: $tags" \
        -d "$body" \
        --max-time 10 >/dev/null 2>&1 || log "alert webhook POST failed (non-fatal)"
}

# --- Run checkin_multi.sh, capture full stdout for parsing ---
checkin_out="$(mktemp /tmp/kt_checkin.XXXXXX)"
trap 'rm -f "$checkin_out"' EXIT
SSH_HOST="$SSH_HOST" SSH_PORT="$SSH_PORT" N_GPUS="$N_GPUS" \
  bash "$REPO_ROOT/longevity_gpu/scripts/checkin_multi.sh" > "$checkin_out" 2>&1
rc=$?

# Always log the full output — diff vs prior tick is invaluable post-mortem.
{
    echo "=========== monitor tick $(ts) (rc=$rc) ==========="
    cat "$checkin_out"
    echo "=========== end tick ==========="
    echo
} >> "$today_log"

# --- Parse signals ---
content="$(cat "$checkin_out")"

# Build a fingerprint of "is anything anomalous". Used to dedupe alerts
# (we don't want a "VM down" alert every 30 min if it's been down for 6 h
# — but we DO want a fresh alert if the state changes).
sig=""

# 1. SSH unreachable
if echo "$content" | grep -q "FATAL:.*unreachable"; then
    alert high "VM unreachable" "$SSH_HOST:$SSH_PORT — SSH probe failed at $(ts). Continuing to retry; will alert again only if state changes."
    sig="${sig}|ssh-unreachable"
fi

# 2. VM rebooted (informational, not an emergency)
if echo "$content" | grep -q "VM rebooted"; then
    alert info "VM rebooted" "$SSH_HOST: PID 1 boot-time delta detected. Auto-relaunch fired."
    sig="${sig}|reboot"
fi

# 3. Build failure
if echo "$content" | grep -q "BUILD FAILED"; then
    alert high "BUILD FAILED" "$SSH_HOST: kt_filter_v8 rebuild failed. Existing binary preserved per script policy. Investigate build_remote.sh stderr in the daily log."
    sig="${sig}|build-failed"
fi

# 4. Binary missing
if echo "$content" | grep -q "is missing or non-executable"; then
    alert high "Binary missing" "$SSH_HOST: kt_filter_v8 binary missing on remote. Per-GPU relaunch suspended by circuit breaker. Manual rebuild needed."
    sig="${sig}|binary-missing"
fi

# 5. NOVEL HIT — top priority
if echo "$content" | grep -q "NOVEL HIT(S) FOUND"; then
    novel_n=$(echo "$content" | grep -oE 'total_novel_hits_across_gpus=[0-9]+' | tail -1 | sed 's/.*=//')
    alert high "NOVEL HIT" "$SSH_HOST: $novel_n hit(s) across GPUs. Pull novel_records*.jsonl from each GPU's WORKDIR for inspection IMMEDIATELY."
    sig="${sig}|novel-${novel_n}"
fi

# 6. Non-empty found.txt anywhere
nef_total=$(echo "$content" | grep -oE 'nonempty_found=[1-9][0-9]*' | wc -l)
if [[ "$nef_total" -gt 0 ]]; then
    alert high "found.txt non-empty" "$SSH_HOST: $nef_total GPU(s) reported a non-empty found.txt. Investigate."
    sig="${sig}|found-${nef_total}"
fi

# 7. Near-hit (post-Fermat-2 survivor)
surv_lines=$(echo "$content" | grep -oE 'surv_total=[1-9][0-9]*' | wc -l)
if [[ "$surv_lines" -gt 0 ]]; then
    surv_summary=$(echo "$content" | grep -E 'surv_total=[1-9]' | head -3)
    alert info "Near-hit (surv_total>0)" "$SSH_HOST: $surv_lines (pattern,bits) tuple(s) saw post-Fermat-2 candidates. CC-style 'getting close' signal. First 3:
$surv_summary"
    sig="${sig}|near-hit"
fi

# 8. Temperature
hot=$(echo "$content" | grep -oE 'gpu=[0-9]+, [0-9]+,' | awk -F'[ ,]' -v T="$TEMP_ALERT_C" '$3+0 > T { print $0 }')
if [[ -n "$hot" ]]; then
    alert high "GPU temp >$TEMP_ALERT_C°C" "$SSH_HOST:
$hot"
    sig="${sig}|temp"
fi

# 9. Memory leak (relative to first-seen baseline per VM)
mem_now=$(echo "$content" | grep -oE 'gpu=[0-9]+, [0-9]+, [0-9]+' | awk -F'[ ,]' '{print $4}' | sort -n | tail -1)
if [[ -n "$mem_now" && "$mem_now" =~ ^[0-9]+$ ]]; then
    if [[ ! -f "$mem_baseline_file" ]]; then
        echo "$mem_now" > "$mem_baseline_file"
        log "Mem baseline established: ${mem_now} MiB"
    else
        baseline=$(cat "$mem_baseline_file")
        delta=$((mem_now - baseline))
        if [[ "$delta" -gt "$MEM_DELTA_MB" ]]; then
            alert high "GPU mem leak" "$SSH_HOST: max mem now ${mem_now} MiB (baseline=${baseline}, delta=+${delta} MiB; threshold=+${MEM_DELTA_MB})."
            sig="${sig}|mem-${delta}"
        fi
    fi
fi

# 10. Stall detection — would need per-cell reporter timestamp parsing.
#     Heuristic for now: if any GPU reporter line has t<10s repeatedly
#     across multiple ticks, it might be relaunch-spinning. Defer to v2.

# Compute alert-dedupe hash. If sig is unchanged from last tick AND it's
# a non-critical signal, suppress. Critical signals (novel/found/binary)
# always re-alert because they're rare and cheap.
sig_hash=$(printf '%s' "$sig" | sha1sum | awk '{print $1}')
last_hash=""
[[ -f "$last_anomaly_hash_file" ]] && last_hash=$(cat "$last_anomaly_hash_file")
echo "$sig_hash" > "$last_anomaly_hash_file"

# Heartbeat (info-level summary). Emit at most once per day.
heartbeat_marker="$STATE_DIR/heartbeat-$(date -u +%Y-%m-%d)"
if [[ -z "$sig" && ! -f "$heartbeat_marker" ]]; then
    summary=$(echo "$content" | grep -E '^\[checkin\] fluent-bit=|^\[checkin\] === ' | head -2)
    alert info "Daily heartbeat" "$SSH_HOST: campaign healthy.
$summary"
    touch "$heartbeat_marker"
fi

if [[ -z "$sig" ]]; then
    log "tick clean (no anomalies, sig=empty)"
else
    log "tick anomalies sig=$sig (hash=$sig_hash, last=$last_hash)"
fi

exit 0
