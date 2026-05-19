#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# Upload src/cuda + src/common to remote GPU box and build kt_filter.
# Usage: bash longevity_gpu/scripts/build_remote.sh
# Reads: SSH_HOST, SSH_PORT, REMOTE_DIR, TARGET (defaults below).
#
# Exit-code contract:
#   0 = upload + build succeeded, $TARGET binary present and freshly built
#   non-zero = something failed; $TARGET on the remote MAY still be the
#              previous good binary (we no longer 'make clean' before build)
#
# Design decisions worth keeping:
#   1. Ship ALL .cu/.c/.h via shell globs, not a hardcoded list. New headers
#      added by future commits (like kt_filter_v5_f1_baked.h, which broke
#      the previous incarnation of this script) get picked up automatically.
#   2. NO 'make clean'. Incremental build means a failed compile leaves the
#      existing $TARGET binary intact — campaign keeps running on the old
#      binary until the next successful build.
#   3. pipefail enabled in the remote shell so 'make ... | tail' propagates
#      make's exit code instead of swallowing it (the silent-failure root
#      cause of the 2026-05-09 incident).
set -euo pipefail

SSH_HOST="${SSH_HOST:?set SSH_HOST=root@<gpu-host>}"
SSH_PORT="${SSH_PORT:?set SSH_PORT=<ssh-port>}"
REMOTE_DIR="${REMOTE_DIR:-/root/kt_longevity}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

TARGET="${TARGET:-kt_filter_v8}"   # v8 default (phase-v8-Sobs); flip via env for older builds
echo "[build_remote] repo=$REPO_ROOT  host=$SSH_HOST:$SSH_PORT  remote=$REMOTE_DIR  target=$TARGET"

ssh -p "$SSH_PORT" "$SSH_HOST" "mkdir -p $REMOTE_DIR/src $REMOTE_DIR/logs $REMOTE_DIR/runs $REMOTE_DIR/src/tools"

# Ship every source the build might want, by glob. New files in src/cuda/ or
# src/common/ are picked up automatically. The exclude list is only for
# obviously-not-source artefacts (object files, the binaries themselves).
SRC_FILES=()
shopt -s nullglob
for f in "$REPO_ROOT"/src/cuda/*.cu \
         "$REPO_ROOT"/src/cuda/*.h \
         "$REPO_ROOT"/src/cuda/*.c \
         "$REPO_ROOT"/src/cuda/Makefile \
         "$REPO_ROOT"/src/cuda/experiments/*.cu \
         "$REPO_ROOT"/src/cuda/experiments/*.h \
         "$REPO_ROOT"/src/cuda/experiments_v5/*.cu \
         "$REPO_ROOT"/src/cuda/experiments_v5/*.h \
         "$REPO_ROOT"/src/cuda/experiments_v8/*.cu \
         "$REPO_ROOT"/src/cuda/experiments_v8/*.h \
         "$REPO_ROOT"/src/common/*.c \
         "$REPO_ROOT"/src/common/*.h; do
    SRC_FILES+=("$f")
done
shopt -u nullglob

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
    echo "[build_remote] FATAL: no source files matched the globs under $REPO_ROOT/src/"
    exit 2
fi

echo "[build_remote] uploading ${#SRC_FILES[@]} source files"
scp -P "$SSH_PORT" -q "${SRC_FILES[@]}" "$SSH_HOST:$REMOTE_DIR/src/"

# Ship records.json + records_manifest.tsv so --test/--validate-known pass on remote
scp -P "$SSH_PORT" -q "$REPO_ROOT/known/records.json" "$SSH_HOST:$REMOTE_DIR/src/records.json"
scp -P "$SSH_PORT" -q "$REPO_ROOT/tools/records_manifest.tsv" "$SSH_HOST:$REMOTE_DIR/src/tools/records_manifest.tsv"

# Local commit short-sha → KT_BUILD_SHA (preserve traceability since remote isn't a git repo)
SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Build only the requested TARGET. KEY DESIGN POINTS:
#   - 'set -e -o pipefail' in the remote shell so 'make | tail' propagates
#     make's nonzero exit instead of swallowing it.
#   - NO 'make clean': incremental build keeps the existing binary intact
#     if the new one fails to compile.
#   - The final 'ls -la $TARGET' acts as a post-build sanity check; if make
#     succeeded but the binary is missing, ls fails and the script exits non-zero.
ssh -p "$SSH_PORT" "$SSH_HOST" bash <<EOF
set -e -o pipefail
cd $REMOTE_DIR/src
export PATH=/usr/local/cuda-13.2/bin:\$PATH
echo "[remote-build] building $TARGET (incremental; previous binary preserved on failure)"
make $TARGET KT_BUILD_SHA=$SHA 2>&1 | tail -25
ls -la $TARGET
echo "--- nvcc version ---"; nvcc --version | tail -2
echo "--- gpu ---"; nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
EOF

echo "[build_remote] done (target=$TARGET, SHA=$SHA)"
