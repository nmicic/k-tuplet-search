#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# tests/test_features_actually_run.sh
#
# Tier-0 test hardening — bundles feature-flag, no-op detection, and
# observability checks into a single external smoke harness.
#
# Each smoke asserts an *observable* engine behaviour that would have caught a
# real production miss during the 2026-05-09→10 longevity campaign. The
# T-H7 "no-op detector" is implemented as a global grep over every captured log
# at the end of the run; a flag accepted-but-not-implemented (the engine prints
# "[accepted, no-op") fails CI.
#
# Per-smoke wall-time budgets are documented inline; aggregate budget < 30 s.
# If any smoke exceeds its budget the engine has regressed — STOP, surface as
# a new bug per W15 stop policy; do not relax timeouts.
#
# Usage:
#   make -C src/cuda kt_filter_v8
#   bash tests/test_features_actually_run.sh
#   # or, with explicit binary:
#   KT_BIN=/abs/path/to/kt_filter_v8 bash tests/test_features_actually_run.sh
#
# The --prefix smoke (T-H8 row 5) is delegated to
# longevity_gpu/scripts/validate_records_external.sh, which requires a remote
# GPU box. With no SSH_HOST set, this harness *attests* the script is wired
# without actually invoking it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KT_BIN="${KT_BIN:-$REPO_ROOT/src/cuda/kt_filter_v8}"
ARTIFACTS="${ARTIFACTS:-$REPO_ROOT/tmp/test_features_artifacts}"
mkdir -p "$ARTIFACTS"
rm -f "$ARTIFACTS"/*.log "$ARTIFACTS"/*.ckpt 2>/dev/null || true

n_pass=0
n_fail=0
fails=()

t_start_total=$SECONDS

# ----- T-H7 (no-op detector) helper -----
# After all smokes complete, scan every captured log for the half-landing
# self-disclosure string. Any match is a hard FAIL.
th7_global_check() {
    local hits
    hits=$(grep -lF "[accepted, no-op" "$ARTIFACTS"/*.log 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        echo "  [T-H7 FAIL] '[accepted, no-op' string detected in:"
        for f in $hits; do echo "      $f"; done
        return 1
    fi
    echo "  [T-H7 PASS] no '[accepted, no-op' strings in $(ls "$ARTIFACTS"/*.log 2>/dev/null | wc -l) captured logs"
    return 0
}

# ----- T-H8 row 1: --exhaustive smoke -----
# bits=40, primorial=11 (37#) → sub-primorial cell, exhausts in one tile.
# Assertion: walltime < 10 s AND stdout matches "PREFIX [^ ]+ EXHAUSTED at".
test_th8_exhaustive() {
    local label=th8_exhaustive
    local logf="$ARTIFACTS/${label}.log"
    local t0=$SECONDS
    timeout 12 "$KT_BIN" \
        --pattern KT19_P0 --bits 40 --primorial 11 \
        --exhaustive --max-time 8 \
        > "$logf" 2>&1
    local rc=$?
    local elapsed=$((SECONDS - t0))
    if [[ $elapsed -ge 10 ]]; then
        echo "  [FAIL] $label: walltime=${elapsed}s exceeds 10s budget (rc=$rc)"; return 1
    fi
    if ! grep -qE "PREFIX [^ ]+ EXHAUSTED at" "$logf"; then
        echo "  [FAIL] $label: missing 'PREFIX … EXHAUSTED at' banner (walltime=${elapsed}s rc=$rc)"
        echo "         tail: $(tail -3 "$logf" | tr '\n' ' ')"
        return 1
    fi
    echo "  [PASS] $label  walltime=${elapsed}s"
    return 0
}

# ----- T-H8 row 2: --checkpoint smoke -----
# Run with --ckpt-interval 2 --max-time 4 → after exit, file is non-empty.
test_th8_checkpoint() {
    local label=th8_checkpoint
    local ckpt="$ARTIFACTS/${label}.ckpt"
    local logf="$ARTIFACTS/${label}.log"
    rm -f "$ckpt"
    local t0=$SECONDS
    timeout 8 "$KT_BIN" \
        --pattern KT19_P0 --bits 50 --primorial 11 \
        --checkpoint "$ckpt" --ckpt-interval 2 --max-time 4 \
        > "$logf" 2>&1
    local rc=$?
    local elapsed=$((SECONDS - t0))
    if [[ ! -s "$ckpt" ]]; then
        echo "  [FAIL] $label: checkpoint file '$ckpt' missing or empty after exit (rc=$rc walltime=${elapsed}s)"; return 1
    fi
    echo "  [PASS] $label  ckpt=$(stat -c %s "$ckpt")B walltime=${elapsed}s"
    return 0
}

# ----- T-H8 row 3: --resume smoke -----
# Reuse the checkpoint from test_th8_checkpoint. Engine logs include [RESUME]
# banner AND no "starting fresh" stderr.
test_th8_resume() {
    local label=th8_resume
    local ckpt="$ARTIFACTS/th8_checkpoint.ckpt"
    local logf="$ARTIFACTS/${label}.log"
    if [[ ! -s "$ckpt" ]]; then
        echo "  [SKIP] $label: prior checkpoint '$ckpt' missing"
        return 0
    fi
    local t0=$SECONDS
    timeout 8 "$KT_BIN" \
        --pattern KT19_P0 --bits 50 --primorial 11 \
        --resume "$ckpt" --max-time 3 \
        > "$logf" 2>&1
    local rc=$?
    local elapsed=$((SECONDS - t0))
    if grep -qE "starting fresh" "$logf"; then
        echo "  [FAIL] $label: stderr says 'starting fresh' — checkpoint not loaded (rc=$rc walltime=${elapsed}s)"; return 1
    fi
    if ! grep -qE "\[RESUME\]" "$logf"; then
        echo "  [FAIL] $label: no [RESUME] banner (rc=$rc walltime=${elapsed}s)"
        echo "         tail: $(tail -3 "$logf" | tr '\n' ' ')"
        return 1
    fi
    echo "  [PASS] $label  walltime=${elapsed}s"
    return 0
}

# ----- T-H1 / T-H8 row 4: --random anchor diversity -----
# N=10 fresh runs at bits=72 primorial=12 → distinct anchor count >= 8/10.
# This is exactly the assertion that would have caught Fix B's deterministic
# random-mode regression before operator eyeball.
test_th1_random_anchors() {
    local label=th1_random_anchors
    local N=10
    local anchors=()
    local i a logf
    local t0=$SECONDS
    for i in $(seq 1 $N); do
        logf="$ARTIFACTS/${label}.run${i}.log"
        timeout 15 "$KT_BIN" \
            --pattern KT19_P0 --bits 72 --primorial 12 --random \
            --max-time 1 --max-batches 1 \
            > "$logf" 2>&1 || true
        # Banner format: "[search] anchor=0xHHHH...HHHH (decimal=...)"
        a=$(grep -m1 -oE 'anchor=0x[0-9a-fA-F]+' "$logf" | head -1)
        anchors+=("${a:-MISSING_run${i}}")
    done
    local distinct
    distinct=$(printf '%s\n' "${anchors[@]}" | grep -v '^MISSING' | sort -u | wc -l)
    local elapsed=$((SECONDS - t0))
    if [[ $distinct -lt 8 ]]; then
        echo "  [FAIL] $label: distinct=$distinct/$N anchors (expected >=8); walltime=${elapsed}s"
        echo "         anchors: ${anchors[*]}"
        return 1
    fi
    echo "  [PASS] $label  distinct=$distinct/$N walltime=${elapsed}s"
    return 0
}

# ----- T-H8 row 5: --prefix smoke (delegated) -----
# longevity_gpu/scripts/validate_records_external.sh shipped 2026-05-10; it
# tests --prefix on the production code path against records.json. It requires
# a remote GPU (SSH_HOST/SSH_PORT). In a CI without remote credentials we
# attest the script is wired and skip execution.
test_th8_prefix_validate() {
    local label=th8_prefix_validate
    local script="$REPO_ROOT/longevity_gpu/scripts/validate_records_external.sh"
    local logf="$ARTIFACTS/${label}.log"
    if [[ ! -x "$script" ]]; then
        echo "  [FAIL] $label: $script absent or not executable"
        echo "  [FAIL] $label: --prefix path coverage missing" > "$logf"
        return 1
    fi
    if [[ -z "${SSH_HOST:-}" || -z "${SSH_PORT:-}" ]]; then
        echo "  [PRESENT] $label: $script wired (set SSH_HOST/SSH_PORT to actually run)"
        echo "[skip] no remote GPU credentials in env" > "$logf"
        return 0
    fi
    if bash "$script" > "$logf" 2>&1; then
        echo "  [PASS] $label  remote validation passed"
        return 0
    fi
    echo "  [FAIL] $label: validate_records_external.sh non-zero exit"
    echo "         tail: $(tail -3 "$logf" | tr '\n' ' ')"
    return 1
}

# ----- Sanity: binary exists & is executable -----
if [[ ! -x "$KT_BIN" ]]; then
    cat <<EOF >&2
FATAL: $KT_BIN not built.
       Run: make -C src/cuda kt_filter_v8
       Or set:   KT_BIN=/path/to/kt_filter_v8 bash tests/test_features_actually_run.sh
EOF
    exit 2
fi

echo "[harness] KT_BIN=$KT_BIN"
echo "[harness] ARTIFACTS=$ARTIFACTS"
echo

for t in test_th8_exhaustive \
         test_th8_checkpoint \
         test_th8_resume \
         test_th1_random_anchors \
         test_th8_prefix_validate; do
    echo "[run] $t"
    if "$t"; then
        n_pass=$((n_pass + 1))
    else
        n_fail=$((n_fail + 1))
        fails+=("$t")
    fi
done

echo
echo "[run] T-H7 global no-op detector"
if th7_global_check; then
    n_pass=$((n_pass + 1))
else
    n_fail=$((n_fail + 1))
    fails+=("th7_global_check")
fi

elapsed_total=$((SECONDS - t_start_total))
echo
echo "[summary] pass=$n_pass fail=$n_fail wall=${elapsed_total}s"
if [[ $n_fail -gt 0 ]]; then
    echo "[summary] failed: ${fails[*]}"
    exit 1
fi
exit 0
