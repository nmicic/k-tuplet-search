#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# bootstrap_vm.sh — one-shot VM-side bootstrap for kt-filter GPU work.
# Run as root on a fresh Ubuntu GPU VM:
#
#   curl -fsSL <raw-url-to-this>/bootstrap_vm.sh | bash
#   # ...VM reboots once...
#   curl -fsSL ... | bash       # second run picks up post-reboot phase
#
# What it does:
#   Phase 1 (init):
#     - Refuses to run inside a container (driver-purge is meaningless there).
#     - apt update + apt upgrade (system current, may pull new kernel).
#     - apt install $CUDA_NVCC_PKG (default: cuda-nvcc-13-2, matches Makefile).
#     - If loaded driver < $MIN_DRIVER, apt-purges all nvidia* packages and
#       runs `ubuntu-drivers autoinstall` (handles 580 -> 590+ on Vast).
#     - Reboots if EITHER the driver was reinstalled OR
#       /var/run/reboot-required was touched by the upgrade.
#   Phase 2 (post-reboot):
#     - Verifies nvidia-smi works + driver major >= MIN_DRIVER.
#     - Installs libgmp-dev, build-essential, tmux, secure-delete, curl.
#     - Creates /root/kt/{src,runs,logs} workspace skeleton.
#     - Prints the next step (operator-side: bash build_remote.sh).
#
# Idempotent: state lives in $PHASE_FILE so re-running on either side of
# the reboot is safe.
#
# Knobs (env):
#   MIN_DRIVER       minimum acceptable driver major version (default: 590)
#   CUDA_NVCC_PKG    apt package name for the nvcc toolkit version we want
#                    (default: cuda-nvcc-13-2 — pairs with Makefile's
#                    /usr/local/cuda-13.2/bin/nvcc default). Set to empty
#                    string to skip cuda-nvcc install (e.g. if you'll use
#                    /usr/local/cuda/bin/nvcc that the driver bundle ships).
#   PHASE_FILE       state file location (default: /var/lib/kt-bootstrap/phase)
#   AUTO_REBOOT      "1" to call `reboot` automatically when needed
#                    (default), "0" to print instructions and stop.
#   WORKSPACE_DIR    where /kt is built (default: /root/kt)

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "[bootstrap] run as root (or via sudo)"; exit 1; }

# Refuse to run inside a container — the driver lives in the host kernel
# there, and apt-purge does nothing useful (the actual libs are bind-mounts).
if [[ -e /.dockerenv ]] || grep -qa 'docker\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
    echo "[bootstrap] ERROR: container detected. This script needs a real VM"
    echo "                  with kernel-module load capability."
    echo "                  /.dockerenv or container cgroups present."
    exit 2
fi

MIN_DRIVER="${MIN_DRIVER:-590}"
CUDA_NVCC_PKG="${CUDA_NVCC_PKG-cuda-nvcc-13-2}"   # `-` not `:-` so empty stays empty
PHASE_FILE="${PHASE_FILE:-/var/lib/kt-bootstrap/phase}"
AUTO_REBOOT="${AUTO_REBOOT:-1}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/root/kt}"

# apt invariants: keep existing config files on package upgrades, no prompts
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive
# Suppress needrestart's ncurses "Which services should be restarted?" dialog
# that `-y` alone does NOT silence. `a` = auto-restart, `l` = list only.
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

mkdir -p "$(dirname "$PHASE_FILE")"
phase() { cat "$PHASE_FILE" 2>/dev/null || echo "init"; }
set_phase() { echo "$1" > "$PHASE_FILE"; echo "[bootstrap] phase -> $1"; }

driver_major() {
    # Returns the major version of the running driver (e.g. 580, 595), or
    # 0 if nvidia-smi cannot talk to the kernel module (NVML mismatch
    # post-apt-upgrade, missing driver, container without device, ...).
    #
    # Guardrails (all matter under `set -euo pipefail`):
    #   - `2>/dev/null` swallows the stderr "NVML library version: ..." line.
    #   - `|| true` after the pipe catches nvidia-smi exiting non-zero
    #     (it returns 9 on NVML mismatch).
    #   - The numeric regex check at the end catches the case where
    #     nvidia-smi prints "Failed to initialize NVML: ..." to STDOUT
    #     (newer nvidia-smi does that with --format=csv,noheader). Without
    #     this, the caller's `(( DRV >= MIN_DRIVER ))` arithmetic context
    #     would split those words and trip set -u on `$Failed`.
    local v
    v="$( (nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
            | head -1) || true )"
    v="${v%%.*}"  # strip ".142" off "580.142", or no-op on garbage
    if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; else echo 0; fi
}

banner() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

CURRENT_PHASE=$(phase)
banner "kt VM bootstrap — phase=$CURRENT_PHASE  min_driver=$MIN_DRIVER"

# --------------------------------------------------------------------------
# Phase 1 — system update + driver swap + cuda-nvcc + extras
#
# Order matters (matches the operator's known-good Vast workflow):
#   1. apt update + apt upgrade (kernel etc. current)
#   2. If driver too old: purge '*nvidia*', install ubuntu-drivers-common,
#      run `ubuntu-drivers autoinstall` TWICE (defensive — sometimes the
#      first pass leaves a candidate un-applied).
#   3. apt update (fresh metadata after driver swap)
#   4. Install extras: keyutils nvtop joe (operator-favourite tooling).
#   5. Install $CUDA_NVCC_PKG (default cuda-nvcc-13-2). After the driver
#      swap so dependency resolution isn't fighting a half-purged tree.
#   6. Single reboot at the end if EITHER apt upgrade flagged
#      /var/run/reboot-required OR a driver swap happened.
# --------------------------------------------------------------------------
if [[ "$CURRENT_PHASE" == "init" ]]; then
    REBOOT_NEEDED=0

    echo "[bootstrap] apt update + upgrade (system current; needrestart silenced)"
    apt-get update -qq
    apt-get "${APT_OPTS[@]}" upgrade
    [[ -f /var/run/reboot-required ]] && {
        echo "[bootstrap] /var/run/reboot-required set by upgrade (likely new kernel)"
        REBOOT_NEEDED=1
    }

    DRV="$(driver_major)"
    if [[ -n "$DRV" ]] && (( DRV >= MIN_DRIVER )); then
        echo "[bootstrap] driver major=$DRV >= $MIN_DRIVER; skipping nvidia purge"
    else
        echo "[bootstrap] driver major=${DRV:-missing} < $MIN_DRIVER; purging + autoinstall"
        # `'*nvidia*'` is a single argument so apt does the glob, not the shell.
        # `|| true` because purge fails if no matches.
        apt-get purge -y '*nvidia*' || true
        apt-get "${APT_OPTS[@]}" install ubuntu-drivers-common
        # Twice — empirically, a single pass sometimes leaves a candidate
        # un-applied on certain Vast images. Cheap to re-run.
        ubuntu-drivers autoinstall
        ubuntu-drivers autoinstall
        REBOOT_NEEDED=1
    fi

    echo "[bootstrap] apt update (post-driver metadata refresh)"
    apt-get update -qq

    echo "[bootstrap] apt install operator extras: keyutils nvtop joe"
    apt-get "${APT_OPTS[@]}" install keyutils nvtop joe || \
        echo "[bootstrap] WARN: extras install partial; continuing"

    if [[ -n "$CUDA_NVCC_PKG" ]]; then
        echo "[bootstrap] apt install $CUDA_NVCC_PKG"
        if ! apt-get "${APT_OPTS[@]}" install "$CUDA_NVCC_PKG"; then
            echo "[bootstrap] WARN: $CUDA_NVCC_PKG install failed."
            echo "            (cuda apt repo may not be configured on this image.)"
            echo "            Continuing — falling back to whatever nvcc is on disk."
        fi
    fi

    if (( REBOOT_NEEDED )); then
        set_phase "reboot_required"
        if [[ "$AUTO_REBOOT" == "1" ]]; then
            banner "System upgraded / driver swapped. Rebooting in 5 sec."
            echo "             After reboot, re-run this script to continue."
            sleep 5
            reboot
            exit 0   # in case reboot is async
        else
            banner "Reboot needed. AUTO_REBOOT=0 — reboot manually then re-run."
            exit 0
        fi
    else
        # Nothing material changed (or all changes were userspace-only)
        set_phase "driver_ok"
        CURRENT_PHASE="driver_ok"
    fi
fi

# --------------------------------------------------------------------------
# Phase 2 — verify driver loaded after reboot
# --------------------------------------------------------------------------
if [[ "$CURRENT_PHASE" == "reboot_required" ]]; then
    if ! nvidia-smi >/dev/null 2>&1; then
        echo "[bootstrap] nvidia-smi STILL failing after reboot. Investigate:"
        echo "  dmesg | grep -i nvidia | tail -30"
        echo "  cat /var/log/nvidia-installer.log 2>/dev/null | tail -30"
        echo "  apt list --installed 2>/dev/null | grep -i nvidia"
        exit 3
    fi
    DRV="$(driver_major)"
    if (( DRV < MIN_DRIVER )); then
        echo "[bootstrap] driver still $DRV after reboot (wanted >=$MIN_DRIVER)"
        echo "            ubuntu-drivers may have picked an older candidate."
        echo "            Try: ubuntu-drivers list, then apt install nvidia-driver-XXX-server"
        exit 4
    fi
    echo "[bootstrap] driver=$(driver_major) loaded; proceeding"
    set_phase "driver_ok"
    CURRENT_PHASE="driver_ok"
fi

# --------------------------------------------------------------------------
# Phase 3 — build/runtime deps + workspace
# --------------------------------------------------------------------------
if [[ "$CURRENT_PHASE" == "driver_ok" ]]; then
    apt-get update -qq
    # build-essential gives gcc/make; tmux for the matrix runner; secure-delete
    # gives srm for the "delete sources after compile" rule; curl/gpg/ca-certs
    # for fluent-bit's apt repo bootstrap if you install the worker next.
    apt-get "${APT_OPTS[@]}" install \
        libgmp-dev build-essential tmux secure-delete curl gpg ca-certificates
    set_phase "tools_installed"
    CURRENT_PHASE="tools_installed"
fi

# --------------------------------------------------------------------------
# Phase 4 — workspace skeleton
# --------------------------------------------------------------------------
if [[ "$CURRENT_PHASE" == "tools_installed" ]]; then
    mkdir -p "$WORKSPACE_DIR"/{src,runs,logs} "$WORKSPACE_DIR/src/tools"

    # Idempotent: add nvcc alias to root's .bashrc if a cuda-13.2 binary
    # exists and we haven't already inserted the marker.
    if [[ -x /usr/local/cuda-13.2/bin/nvcc ]] && \
       ! grep -q '^# kt-bootstrap nvcc alias' /root/.bashrc 2>/dev/null; then
        cat >> /root/.bashrc <<'EOF'

# kt-bootstrap nvcc alias (cuda-13.2)
alias nvcc=/usr/local/cuda-13.2/bin/nvcc
export PATH=/usr/local/cuda-13.2/bin:$PATH
EOF
        echo "[bootstrap] nvcc alias appended to /root/.bashrc"
    fi

    set_phase "ready"
    CURRENT_PHASE="ready"
fi

# --------------------------------------------------------------------------
# Done — print summary + next steps
# --------------------------------------------------------------------------
banner "Bootstrap done. Phase=$CURRENT_PHASE"

DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo missing)"
GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo missing)"
NVCC="$(ls /usr/local/cuda*/bin/nvcc 2>/dev/null | head -1 || echo missing)"
NVCC_VER="$($NVCC --version 2>/dev/null | tail -1 || echo missing)"

cat <<EOF
 Driver:       $DRV
 GPU:          $GPU
 nvcc:         $NVCC
   $NVCC_VER
 Workspace:    $WORKSPACE_DIR/
                ├── src/
                ├── runs/
                └── logs/

Next steps (from operator side, NOT here):

 1. Build kt_filter on this VM:
      SSH_HOST=root@<vm-ip> SSH_PORT=<port> \\
      NVCC=$NVCC \\
        bash longevity_gpu/scripts/build_remote.sh

 2. Optional: ship the fluent-bit worker (uses systemd on a real VM, no
    docker patching needed):
      scp -P <port> install-worker.sh root@<vm-ip>:/tmp/
      ssh root@<vm-ip> 'LOG_PATH="$WORKSPACE_DIR/runner.log,$WORKSPACE_DIR/runs/*/*/stdout.log" bash /tmp/install-worker.sh'

 3. Launch the matrix:
      ssh root@<vm-ip> 'tmux new-session -d -s ktlong "bash $WORKSPACE_DIR/run_matrix.sh"'

 4. Periodic check-ins from operator side:
      bash longevity_gpu/scripts/checkin.sh

To re-bootstrap (e.g. after Vast image update), wipe phase and re-run:
  rm $PHASE_FILE && bash bootstrap_vm.sh
EOF
