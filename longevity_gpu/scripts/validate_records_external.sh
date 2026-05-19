#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# validate_records_external.sh — external (production-path) validation of
# known records, using ONLY --pattern + --bits + --prefix.
#
# Why this exists:
#   The internal `--validate-known` and `--test` harnesses can take a
#   different code path than production search. A bug that affects
#   --prefix/--bits but not --validate-known would silently pass internal
#   gates while making the production sweep miss real hits. (Operator
#   reported exactly this failure mode in cunningham-chain-search.)
#
# What this does:
#   For each known record under a chosen bit ceiling, derive a prefix that
#   pins enough high bits to leave a small (~30-bit) search window, then
#   run the production binary with that prefix and verify the FOUND banner
#   names the expected base.
#
# Pass criterion: every tested record produces a "*** FOUND k=K bits=B
# pattern=P base=<expected> ***" line. Any miss = production-path bug.
set -uo pipefail

SSH_HOST="${SSH_HOST:?set SSH_HOST=root@<ip>}"
SSH_PORT="${SSH_PORT:?set SSH_PORT=<port>}"
REMOTE_DIR="${REMOTE_DIR:-/root/kt}"
GPU_ID="${GPU_ID:-3}"               # which GPU to use; default last (least valuable for hunt)
MAX_BITS="${MAX_BITS:-75}"          # only validate records up to this size
PREFIX_HEAD="${PREFIX_HEAD:-30}"    # leave this many low bits as the search window
                                    # (smaller = faster cell, but must be wide enough that the
                                    # cursor actually traverses to the record's offset within
                                    # the cell wall-time)
PER_TEST_SEC="${PER_TEST_SEC:-90}"  # per-record max-time
PRIMORIAL="${PRIMORIAL:-12}"        # 41# wheel — same as production campaign
# KT_BIN override: lets perf-review forks (kt_filter_v8_c1 etc.) reuse this
# validator without source edits.  Resolves to a remote absolute path so the
# `cd $WORK/src && ./kt_filter_v8 …` pattern can be expressed as
# `cd $WORK/src && $KT_BIN …`.  Default keeps the legacy `./kt_filter_v8`
# (relative, resolved against $WORK/src which symlinks to $REMOTE_DIR/src).
KT_BIN="${KT_BIN:-./kt_filter_v8}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST_LOCAL="${MANIFEST_LOCAL:-$REPO_ROOT/tools/records_manifest.tsv}"

# Normalize KT_BIN once so the existence check (line 50) and the execution
# call site (~line 115) agree.  Absolute paths are honored verbatim; relative
# values resolve against $REMOTE_DIR/src (the cwd at execution time, via the
# $WORK/src symlink).  KT_BIN_EXEC is what gets run after `cd $WORK/src`;
# KT_BIN_REMOTE_PATH is what `test -x` checks on the remote.
if [[ "$KT_BIN" == /* ]]; then
    KT_BIN_EXEC="$KT_BIN"
    KT_BIN_REMOTE_PATH="$KT_BIN"
else
    KT_BIN_EXEC="$KT_BIN"
    KT_BIN_REMOTE_PATH="$REMOTE_DIR/src/${KT_BIN#./}"
fi

# -n detaches ssh from stdin so the outer 'while read' loop's here-string
# isn't consumed by ssh. Without -n, ssh swallows the record list and the
# loop exits after the first iteration.
ssh_run() { ssh -n -p "$SSH_PORT" -o ConnectTimeout=15 -o ServerAliveInterval=5 "$SSH_HOST" "$@"; }

# --- Sanity checks ---
[[ -f "$MANIFEST_LOCAL" ]] || { echo "FATAL: manifest $MANIFEST_LOCAL not found"; exit 2; }
ssh_run "test -x $KT_BIN_REMOTE_PATH" || { echo "FATAL: $KT_BIN_REMOTE_PATH not on remote"; exit 3; }

echo "[validate] target: $SSH_HOST  GPU $GPU_ID  primorial=$PRIMORIAL  max_bits=$MAX_BITS"
echo "[validate] selecting records with bits <= $MAX_BITS from $MANIFEST_LOCAL"

# Filter records: small k, small bits. Sort by bits ascending (smallest first).
records="$(awk -F'\t' -v MAX="$MAX_BITS" 'NR>1 && $1<=17 && $7+0<=MAX+0 {print $1"\t"$2"\t"$3"\t"$7}' "$MANIFEST_LOCAL" | sort -t$'\t' -k4n)"

if [[ -z "$records" ]]; then
    echo "FATAL: no records matched the filter (k<=17, bits<=$MAX_BITS)"
    exit 4
fi

n_total=$(echo "$records" | wc -l)
echo "[validate] $n_total records to test"

# --- Run each record ---
WORK=$(ssh_run "mktemp -d /tmp/kt_extval.XXXXXX")
ssh_run "ln -sfn $REMOTE_DIR/src $WORK/src"
trap 'ssh_run "rm -rf $WORK" 2>/dev/null || true' EXIT

n_pass=0
n_fail=0
fail_lines=()

while IFS=$'\t' read -r k pattern base_dec bits; do
    [[ -z "$k" ]] && continue

    # Derive prefix: top (bits - PREFIX_HEAD) bits of base, in binary.
    # Use python on the operator side for arbitrary-precision arithmetic.
    prefix_binary="$(python3 -c "
import sys
base = int('$base_dec')
bits = int('$bits')
head = int('$PREFIX_HEAD')
n_prefix_bits = bits - head
if n_prefix_bits < 4:
    print('SKIP'); sys.exit(0)
prefix = base >> head
print(bin(prefix)[2:].rjust(n_prefix_bits, '0'))
")"

    if [[ "$prefix_binary" == "SKIP" ]]; then
        echo "  [skip] k=$k $pattern bits=$bits  (record too small for chosen prefix head)"
        continue
    fi

    # W19-A-4 (multi-angle P1-10): run each record through TWO passes,
    # sequential and random.  The pre-W18-A bug class lived in random
    # mode (kt_seed_anchor_offset returning a non-primorial-aligned
    # offset, lane_start_u128 unrounded for the per-batch rotation
    # block); sequential-only validation never exercised the buggy
    # code path and would have continued to pass while production lost
    # every hit.
    for pass_mode in sequential random; do
        rd="$WORK/k${k}_${pattern}_b${bits}_${pass_mode}"
        if [[ "$pass_mode" == random ]]; then
            mode_args="--prefix-mode random --random-seed 0xDEADBEEFCAFEBABE"
        else
            mode_args="--prefix-mode sequential"
        fi
        cmd="
            mkdir -p $rd
            cd $WORK/src
            timeout --kill-after=10 $((PER_TEST_SEC + 30)) \\
            $KT_BIN_EXEC --pattern $pattern --bits $bits \\
                --prefix '0b$prefix_binary' --primorial $PRIMORIAL \\
                $mode_args \\
                --gpu-batch-size 2097152 --gpu-streams 3 --gpu-device $GPU_ID \\
                --max-time $PER_TEST_SEC \\
                --output $rd/found.txt > $rd/stdout.log 2>&1
            rc=\$?
            echo \"rc=\$rc\"
        "
        rc_line=$(ssh_run "$cmd" | tail -1)
        rc=$(echo "$rc_line" | grep -oE 'rc=-?[0-9]+' | sed 's/rc=//')
        if [[ ! "${rc:-}" =~ ^-?[0-9]+$ ]]; then
            echo "  [FAIL] k=$k $pattern bits=$bits  base=$base_dec  pass=$pass_mode  (rc=missing) — remote command did not report an exit code"
            fail_lines+=("k=$k pattern=$pattern bits=$bits base=$base_dec pass=$pass_mode rc=missing")
            n_fail=$((n_fail+1))
            continue
        fi

        expected_in_output=$(ssh_run "
            a=\$(grep -hFxc '*** FOUND k=$k bits=$bits pattern=$pattern base=$base_dec ***' $rd/stdout.log 2>/dev/null || true)
            b=\$(awk -v kk='KT$k' -v pat='$pattern' -v base='$base_dec' '\$1 == kk && \$2 == pat && \$3 == base {c++} END {print c+0}' $rd/found.txt 2>/dev/null || true)
            a=\${a:-0}
            b=\${b:-0}
            echo \$((a + b))
        ")
        if [[ ! "${expected_in_output:-}" =~ ^[0-9]+$ ]]; then
            expected_in_output=0
        fi

        if [[ "${expected_in_output:-0}" -ge 1 ]]; then
            echo "  [PASS] k=$k $pattern bits=$bits  base=$base_dec  pass=$pass_mode  (rc=$rc)"
            n_pass=$((n_pass+1))
        else
            echo "  [FAIL] k=$k $pattern bits=$bits  base=$base_dec  pass=$pass_mode  (rc=$rc) — production search did NOT recover this record"
            fail_lines+=("k=$k pattern=$pattern bits=$bits base=$base_dec pass=$pass_mode")
            n_fail=$((n_fail+1))
            echo "         prefix_binary=0b$prefix_binary  mode_args=$mode_args"
            last_reporter=$(ssh_run "grep '\\[reporter\\]' $rd/stdout.log 2>/dev/null | tail -1 | head -c 200")
            echo "         last reporter: $last_reporter"
            final=$(ssh_run "grep -m1 '=== final:' $rd/stdout.log 2>/dev/null | head -c 220")
            echo "         final: $final"
        fi
    done
done <<< "$records"

# --- Summary ---
echo
echo "[validate] === SUMMARY ==="
echo "[validate] pass: $n_pass / $((n_pass + n_fail))"
echo "[validate] fail: $n_fail"
if [[ $n_fail -gt 0 ]]; then
    echo "[validate] !! Production-path bug suspected. Failed records:"
    for f in "${fail_lines[@]}"; do echo "    $f"; done
    exit 1
fi
echo "[validate] all known records recovered through production --prefix path. No bug detected."
exit 0
