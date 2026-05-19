#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
#
# run_catalog_long.sh — months-long catalog enumeration.
#
# Wraps run_catalog_extend.sh in a per-k loop so each completed k is
# committed and pushed before the next k starts. A crash, kill, or SSH
# disconnect at k=N preserves all work for k<N.
#
# Typical use on an idle server:
#   nohup ./tools/patterns/run_catalog_long.sh 36 50 \
#         > tmp/catalog_long.out 2>&1 &
#   disown
#
# Then tail to monitor:
#   tail -f tmp/catalog_long_*.log
#
# Resumable: skip-existing logic in run_catalog_extend.sh means re-running
# this script (after a crash, reboot, etc.) just picks up where it left off.
# Already-enumerated k's are no-ops; the next pending k starts fresh.
#
# Notes:
#   - Each k gets its own commit and push to origin/main.
#   - Push failures (e.g. transient network) are logged but DON'T abort the
#     loop; the next k tries again. Worst case: the catalog file is committed
#     locally but unpushed, and a future iteration will push.
#   - pattern_enum failures (rare) DO abort the current k but the loop
#     continues to the next k.

set -uo pipefail  # NOTE: no -e — we want the loop to continue on per-k errors

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXTEND="$SCRIPT_DIR/run_catalog_extend.sh"

K_FROM="${1:-}"
K_TO="${2:-}"

if [[ -z "$K_FROM" || -z "$K_TO" ]]; then
    cat <<EOF
Usage: $0 <K_FROM> <K_TO>

Loops k=K_FROM..K_TO. For each k:
  1. Calls run_catalog_extend.sh --from k --to k --commit --push
  2. Logs to tmp/catalog_long_<timestamp>.log

Examples:
  $0 36 50              # enumerate k=36..50, ~months on a 16-core box
  $0 36 36              # one k only (~1.2 days at k=36)

Run under nohup so SSH disconnection doesn't kill it:
  nohup $0 36 50 > tmp/catalog_long.out 2>&1 &
  disown
EOF
    exit 1
fi

[[ "$K_FROM" =~ ^[0-9]+$ && "$K_TO" =~ ^[0-9]+$ ]] || {
    echo "ERROR: K_FROM/K_TO must be integers" >&2; exit 2; }
(( K_FROM <= K_TO )) || { echo "ERROR: K_FROM > K_TO" >&2; exit 2; }

mkdir -p "$REPO_ROOT/tmp"
LOG="$REPO_ROOT/tmp/catalog_long_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$LOG"
}

log "long-run: k=$K_FROM..$K_TO"
log "log file: $LOG"
log "extend script: $EXTEND"

failures=0
successes=0
skipped=0

for (( k=K_FROM; k<=K_TO; k++ )); do
    log "===== starting k=$k ====="
    start=$(date +%s)

    # Run extend script per-k. --commit --push handles git-add-and-push
    # of any new catalog file produced by this invocation.
    if "$EXTEND" --from "$k" --to "$k" --commit --push 2>&1 | tee -a "$LOG"; then
        end=$(date +%s)
        elapsed=$((end - start))
        # Distinguish "actually enumerated" from "skipped because file existed"
        # by checking the log for "OK: count=" vs "SKIP:" lines from this k's run.
        # Simple heuristic: look at the most recent extend log slice.
        if grep -qE "^\[k=$k .*\] OK: count=" "$LOG" | tail -1; then
            log "  --> k=$k SUCCESS (elapsed=${elapsed}s)"
            ((successes++))
        else
            log "  --> k=$k SKIPPED (file existed)"
            ((skipped++))
        fi
    else
        end=$(date +%s)
        elapsed=$((end - start))
        log "  --> k=$k FAILED (elapsed=${elapsed}s); continuing to next k"
        ((failures++))
    fi
done

log "===== long-run done ====="
log "summary: successes=$successes skipped=$skipped failures=$failures"
log "catalog dir: $REPO_ROOT/tools/patterns/catalog/"
log "git log of catalog commits:"
git -C "$REPO_ROOT" log --oneline -n 20 -- tools/patterns/catalog/ 2>&1 | tee -a "$LOG"
