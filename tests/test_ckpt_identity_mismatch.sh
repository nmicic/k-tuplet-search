#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# W19-B-8 (multi-angle P1-14): ckpt identity-mismatch coverage.
#
# Validates W18-C's identity validation (primorial_n, prefix_mode, seed)
# plus the W19-B-2 ck_seed_present sentinel and W19-B-3 random-mode
# refuse.  Five cases:
#
#   1. Save p=11, resume p=12 → assert primorial_n soft-fail + cand=0
#      (W18-C primorial check).
#   2. Save sequential ckpt; resume --prefix-mode random --random-seed X
#      → assert prefix_mode soft-fail (W19-B-3 fires even before W18-C's
#      generic prefix_mode-mismatch check because the saved is sequential
#      → current is random → that's a prefix_mode mismatch, not a
#      random-refuse; we accept either message as PASS).
#   3. Save with --random-seed 0xAAAA, resume with --random-seed 0xBBBB
#      → assert seed mismatch (or random-mode-refuse, since W19-B-3
#      refuses ALL random ckpts now; this case is a regression guard for
#      the seed comparison code if W19-B-3 is ever loosened).
#   4. Backward-compat: hand-craft a pre-W18-C ckpt by deleting the
#      primorial_n=/prefix_mode=/seed= lines from a valid current ckpt;
#      resume under matching config → assert SUCCESS (no soft-fail).
#   5. W19-B-2 seed sentinel: ckpt with seed=0x0000000000000000;
#      resume with --random-seed 0 → assert NO mismatch.  Then resume
#      with --random-seed 0x1 → assert mismatch.
#
# Env: same as test_sigkill_resume_idempotent.sh.
# Exit: 0 PASS, 1 FAIL.
set -uo pipefail

BIN="${KT_BIN:-/root/kt/src/kt_filter_v8}"
TMP="${KT_TMP:-/root/kt/tmp/ckpt_identity}"
GPU="${KT_GPU:-0}"

mkdir -p "$TMP"
rm -f "$TMP"/*.log "$TMP"/*.ckpt

FAIL=0

check() {
    local name="$1" expect_regex="$2" log="$3"
    if grep -qE "$expect_regex" "$log"; then
        echo "  PASS: $name"
    else
        echo "  FAIL: $name  (expected match: $expect_regex)"
        echo "  --- last 5 lines of $log ---"
        tail -5 "$log" | sed 's/^/  | /'
        FAIL=$((FAIL+1))
    fi
}

# ---------- Case 1: primorial mismatch -----------------------------------
echo "=== Case 1: save p=11, resume p=12 (expect primorial soft-fail) ==="
CK1="$TMP/case1.ckpt"
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 \
    --max-time 3 --checkpoint "$CK1" --ckpt-interval 1 --full-quiet \
    >"$TMP/case1_save.log" 2>&1
"$BIN" --pattern KT19_P0 --bits 80 --primorial 12 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 \
    --max-time 2 --resume "$CK1" --full-quiet \
    >"$TMP/case1_resume.log" 2>&1 || true
check "primorial soft-fail" \
    "\[RESUME\] primorial_n=11 != current 12 — starting fresh" \
    "$TMP/case1_resume.log"

# ---------- Case 2: prefix_mode mismatch ---------------------------------
echo "=== Case 2: save sequential, resume random (expect prefix_mode soft-fail) ==="
CK2="$TMP/case2.ckpt"
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 \
    --max-time 3 --checkpoint "$CK2" --ckpt-interval 1 --full-quiet \
    >"$TMP/case2_save.log" 2>&1
# Resume keeps the same --prefix 0b1 so the prefix-string check passes
# and the prefix_mode check is the one that fires.
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix 0b1 --prefix-mode random --random-seed 0x1234 \
    --max-time 2 --resume "$CK2" --full-quiet \
    >"$TMP/case2_resume.log" 2>&1 || true
check "prefix_mode mismatch soft-fail" \
    "\[RESUME\] prefix_mode=sequential != current random" \
    "$TMP/case2_resume.log"

# ---------- Case 3: explicit seed mismatch -------------------------------
# Note: W19-B-3 refuses random-mode ckpts UNCONDITIONALLY; this case
# therefore exercises the random-refuse path (not the seed-mismatch path).
# The seed-mismatch path is still reachable from a sequential ckpt with
# --random-seed at save time — engine accepts --random-seed on sequential
# runs to keep the kt_rng deterministic.  We accept either message.
echo "=== Case 3: save --random-seed AAAA, resume --random-seed BBBB ==="
CK3="$TMP/case3.ckpt"
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 --random-seed 0xAAAA \
    --max-time 3 --checkpoint "$CK3" --ckpt-interval 1 --full-quiet \
    >"$TMP/case3_save.log" 2>&1
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 --random-seed 0xBBBB \
    --max-time 2 --resume "$CK3" --full-quiet \
    >"$TMP/case3_resume.log" 2>&1 || true
check "explicit seed mismatch soft-fail" \
    "\[RESUME\] seed=0x000000000000aaaa != current --random-seed 0x000000000000bbbb" \
    "$TMP/case3_resume.log"

# ---------- Case 4: backward-compat (pre-W18-C ckpt) ---------------------
echo "=== Case 4: pre-W18-C ckpt (no primorial_n/prefix_mode/seed lines) resumes cleanly ==="
CK4="$TMP/case4.ckpt"
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 \
    --max-time 3 --checkpoint "$CK4" --ckpt-interval 1 --full-quiet \
    >"$TMP/case4_save.log" 2>&1
# Strip primorial_n / prefix_mode / seed lines to simulate an older ckpt.
sed -i '/^primorial_n=/d; /^prefix_mode=/d; /^seed=/d' "$CK4"
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 \
    --max-time 2 --resume "$CK4" --full-quiet \
    >"$TMP/case4_resume.log" 2>&1 || true
if grep -qE "starting fresh" "$TMP/case4_resume.log"; then
    echo "  FAIL: backward-compat (pre-W18-C ckpt) soft-failed"
    grep -E "starting fresh" "$TMP/case4_resume.log" | head -3 | sed 's/^/  | /'
    FAIL=$((FAIL+1))
else
    check "backward-compat resume loads cleanly" \
        "\[RESUME\] loaded cursor=" "$TMP/case4_resume.log"
fi

# ---------- Case 5: W19-B-2 seed sentinel --------------------------------
echo "=== Case 5a: ckpt seed=0, resume --random-seed 0 (expect MATCH) ==="
CK5="$TMP/case5.ckpt"
cp "$CK4" "$CK5"  # case4's ckpt is well-formed; we'll patch seed.
# Re-inject all three fields so this is a true W18-C-era ckpt with seed=0.
sed -i '1a primorial_n=11\nprefix_mode=sequential\nseed=0x0000000000000000' "$CK5"
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 --random-seed 0x0 \
    --max-time 2 --resume "$CK5" --full-quiet \
    >"$TMP/case5a_resume.log" 2>&1 || true
if grep -qE "seed=0x0000000000000000 != current --random-seed" "$TMP/case5a_resume.log"; then
    echo "  FAIL: seed=0 + --random-seed 0 spuriously soft-failed"
    FAIL=$((FAIL+1))
else
    check "seed=0 + --random-seed 0 resumes" \
        "\[RESUME\] loaded cursor=" "$TMP/case5a_resume.log"
fi

echo "=== Case 5b: ckpt seed=0, resume --random-seed 1 (expect mismatch) ==="
"$BIN" --pattern KT19_P0 --bits 80 --primorial 11 --gpu-device "$GPU" \
    --gpu-batch-size 1048576 --gpu-streams 3 \
    --prefix-mode sequential --prefix 0b1 --random-seed 0x1 \
    --max-time 2 --resume "$CK5" --full-quiet \
    >"$TMP/case5b_resume.log" 2>&1 || true
check "seed=0 + --random-seed 1 mismatch fires" \
    "seed=0x0000000000000000 != current --random-seed 0x0000000000000001" \
    "$TMP/case5b_resume.log"

echo
if [[ $FAIL -eq 0 ]]; then
    echo "=== W19-B-8 PASS: 5/5 ckpt identity cases ==="
    exit 0
else
    echo "=== W19-B-8 FAIL: $FAIL of 6 sub-cases failed ===" >&2
    exit 1
fi
