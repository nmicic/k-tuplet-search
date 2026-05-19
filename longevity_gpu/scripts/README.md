# Longevity GPU Sweep — operator notes

These scripts are **new files** that wrap the existing GPU `kt_filter`
binary for an open-ended longevity test on a remote GPU server (RTX 5090,
sm_120, CUDA 13.2). They do **not** modify any existing repo source.

**Current target:** `kt_filter_v8`.
Bench config: `--gpu-batch-size 2097152 --gpu-streams 3` — TTR-driven.
Do not copy historical throughput numbers between machines; regenerate local
anchors with `tools/kpi_run.py` or the benchmark helpers described in
`../../TESTING.md`.
Phase 9 (campaign descent) added CC-parity flags `--prefix-mode {sequential|random}`,
`--prefix-lanes`/`--prefix-lane-id`, `--exhaustive`, and active checkpoint+resume.

To pin a different binary set `BIN=/root/kt_longevity/src/kt_filter_vN`
in the env before launching `run_matrix.sh`. To rebuild a different
target: `TARGET=kt_filter_vN bash longevity_gpu/scripts/build_remote.sh`.

## Layout

```
longevity_gpu/
├── scripts/
│   ├── bootstrap_vm.sh   # runs ON the VM: apt upgrade + driver swap + cuda-nvcc + workspace
│   ├── build_remote.sh   # operator-side: upload src/cuda + src/common → GPU box, build kt_filter
│   ├── run_matrix.sh     # runs on GPU box; loops k × pattern × bit-band forever
│   ├── checkin.sh        # operator-side: rsync logs + novel records, summary
│   ├── README.md
│   └── runs/             # local mirror of remote progress (created on first checkin)
│       ├── last_checkin.txt
│       ├── health.json
│       ├── novel_records.jsonl
│       ├── runner.log
│       ├── gpu_samples.jsonl
│       └── sweeps/<sweep>/sweep_status.jsonl
```

## Bootstrap a fresh VM (`bootstrap_vm.sh`)

Replaces the manual ritual on a fresh any Ubuntu GPU **VM**:

```text
apt update; apt upgrade; apt purge '*nvidia*'
apt install ubuntu-drivers-common
ubuntu-drivers autoinstall (twice)
apt install keyutils nvtop joe cuda-nvcc-13-2
reboot
... reconnect ...
apt install libgmp-dev build-essential tmux secure-delete
mkdir /root/kt/{src,runs,logs}
echo 'alias nvcc=/usr/local/cuda-13.2/bin/nvcc' >> "$HOME/.bashrc"
```

The script automates all of that, with `NEEDRESTART_MODE=a` and
`DEBIAN_FRONTEND=noninteractive` so dpkg/needrestart never block waiting
for an ncurses prompt. State persists across the reboot in
`/var/lib/kt-bootstrap/phase`, so re-running on either side is safe.

**This script is for VMs only.** It refuses to run inside a container
(checks `/.dockerenv` and container cgroups) — there the kernel driver
lives on the host and `apt purge nvidia*` does nothing useful. For container
offers, use an image with a working CUDA runtime and skip driver installation.

### Recipe (operator side)

```bash
# 0. ssh into the fresh VM once to get to a known-good shell.
ssh -p <port> root@<vm-ip>

# 1. Push the script:
scp -P <port> longevity_gpu/scripts/bootstrap_vm.sh root@<vm-ip>:/root/

# 2. Run it. Detaches itself; survives the SSH disconnect at reboot.
ssh -p <port> root@<vm-ip> \
  'rm -f /var/lib/kt-bootstrap/phase /var/log/bootstrap_vm.log; \
   nohup bash /root/bootstrap_vm.sh > /var/log/bootstrap_vm.log 2>&1 < /dev/null & disown; \
   echo spawned'

# 3. Wait for the VM to reboot (5-10 min depending on driver download).
#    SSH will refuse connections during the few seconds the kernel is
#    actually rebooting.
until ssh -p <port> -o ConnectTimeout=5 -o BatchMode=yes root@<vm-ip> \
        'nvidia-smi --query-gpu=driver_version --format=csv,noheader' 2>/dev/null; do
    sleep 15
done

# 4. Reconnect and finish phase 2 (deps + workspace + nvcc alias).
#    Same script — phase file routes it to the right branch.
ssh -p <port> root@<vm-ip> 'bash /root/bootstrap_vm.sh'

# 5. From operator side, build kt_filter:
SSH_HOST=root@<vm-ip> SSH_PORT=<port> \
  bash longevity_gpu/scripts/build_remote.sh

# 6. (Optional) Drop the fluent-bit worker. On a real VM, install-worker.sh
#    works as-is — systemd is present, no docker patching needed.
scp -P <port> install-worker.sh root@<vm-ip>:/tmp/
ssh -p <port> root@<vm-ip> \
  'LOG_PATH="/root/kt/runner.log,/root/kt/runs/*/*/stdout.log,/root/kt/novel_records*.jsonl" bash /tmp/install-worker.sh'

# Why include novel_records*.jsonl: those are the canonical fsync'd records of
# every certified hit. Including them in LOG_PATH ships each JSON line to <your-log-server>
# as soon as it's written, so a GPU server VM wipe (or any other host loss) cannot
# lose a real record — fluent-bit becomes the off-host backup of last resort.

# 7. Launch the matrix:
ssh -p <port> root@<vm-ip> \
  'tmux new-session -d -s ktlong "bash /root/kt/run_matrix.sh"'
```

Optional wheel-expression cells can be launched through the same runners:

```bash
ssh -p <port> root@<vm-ip> \
  'tmux new-session -d -s ktlong "KT_WHEEL_EXPR='\''47#/31'\'' bash /root/kt/run_matrix.sh"'
```

`KT_WHEEL_EXPR` overrides `KT_PRIMORIAL`. Use one runner process per expression;
for a pool such as `47#/31`, `47#/29`, and `47#/23`, launch separate
GPU-pinned sessions.

### Inspect / debug while it's running

The script writes its own log:

```bash
ssh -p <port> root@<vm-ip> 'tail -f /var/log/bootstrap_vm.log'
ssh -p <port> root@<vm-ip> 'cat /var/lib/kt-bootstrap/phase'
```

Phases the file goes through, in order:

| Phase value | Meaning |
|---|---|
| (file absent) | first run not yet past `apt upgrade` |
| `reboot_required` | apt upgrade or driver swap landed; reboot pending |
| `driver_ok` | post-reboot, nvidia-smi works at >= MIN_DRIVER |
| `tools_installed` | libgmp-dev + build-essential + tmux + secure-delete + curl gpg ca-certificates installed |
| `ready` | workspace dirs created, nvcc alias added, all done |

### Knobs (env)

| Var | Default | Effect |
|---|---|---|
| `MIN_DRIVER` | `590` | Skip nvidia purge+autoinstall if loaded driver major already >= this. Bump to 595 etc. if you want a specific minimum. |
| `CUDA_NVCC_PKG` | `cuda-nvcc-13-2` | apt package for the nvcc toolkit. Pairs with the Makefile's `/usr/local/cuda-13.2/bin/nvcc` default. Set empty (`CUDA_NVCC_PKG=`) to skip if the image already has a usable nvcc. |
| `AUTO_REBOOT` | `1` | When `1`, calls `reboot` automatically when needed. Set `0` to print "reboot manually then re-run" and stop. |
| `WORKSPACE_DIR` | `/root/kt` | Where the kt source / runs / logs tree gets created. |
| `PHASE_FILE` | `/var/lib/kt-bootstrap/phase` | State file. Wipe to force a re-bootstrap. |

Examples:

```bash
# Force minimum driver 595, skip cuda-nvcc install (image has it):
ssh ... 'MIN_DRIVER=595 CUDA_NVCC_PKG= bash /root/bootstrap_vm.sh'

# Re-bootstrap (e.g. host image rolled forward):
ssh ... 'rm /var/lib/kt-bootstrap/phase && bash /root/bootstrap_vm.sh'
```

### Known good behaviour (verified 2026-05-07 on RTX 5090)

- 580 → 595.58.03 swap via `ubuntu-drivers autoinstall` (×2 — defensive).
- `cuda-nvcc-13-2` lands at `/usr/local/cuda-13.2/bin/nvcc`, version 13.2.78.
- Whole-VM bootstrap takes ~6-10 min wall (most of it is driver download).
- Post-bootstrap, kt_filter_v8 compiles cleanly via `build_remote.sh` and
  hits **127.7 Gcand/s** with the Phase-4b-1 flags (inherited by v8 — see
  Sobs-C §2.2 hard-coded recipe flags) — matching
  the bare-metal baseline (and well above the 82 Gcand/s a clock-throttled
  Vast docker offer delivered).

## Test matrix

For each `k ∈ {16..24}`, every catalog pattern (`KTxx_Pn`) is run at the
bit bands listed in `BANDS` (default `"95 101 110 119"`). Lower bands are
skipped by default — territory below ~95 bits has been scanned by older
programs (Forbes/Waldvogel/Chermoni-Jaroslaw/Armitage 1997-2026), and the
operator's stated goal is novelty in unscanned high-bit territory near the
**101-bit boundary**, where no records currently exist for any k.

Bands per k = same `BANDS` list, clamped to [70, 119] (line-sieve floor /
Fermat-2 envelope). Override with env:

```bash
# focus on 101-bit only:
BANDS="101"        bash run_matrix.sh
# tighter band around 101:
BANDS="98 101 105" bash run_matrix.sh
# back to the original "above-record" mix (legacy):
BANDS="95 105 115" bash run_matrix.sh   # plus other tweaks needed
```

Cap: 119 bits (clear of the 127-bit Fermat boundary). Floor: 70 bits
(above the small-prime line-sieve caveat).

Each cell runs **30 minutes** with `--random --chunk-tiles 500
--gpu-batch-size 2097152 --gpu-streams 3`. With 22 patterns × 4 bands and
30 min/cell, one full sweep is **~44 h**. After the full matrix completes,
the runner starts a new sweep. Memory leaks, throughput regressions, or
crashes between sweeps are the longevity signal.

## Operating

On the central server (here):

```bash
# One-shot: upload sources, compile on remote
bash longevity_gpu/scripts/build_remote.sh

# Smoke-test the binary on the GPU box (a few seconds)
ssh -p <port> root@<vm-ip> \
    'cd /root/kt_longevity/src && ./kt_filter --test'

# Optional but recommended: validate-known regression replay
ssh -p <port> root@<vm-ip> \
    'cd /root/kt_longevity/src && timeout 600 ./kt_filter --validate-known'

# Launch matrix runner under nohup (survives ssh disconnect)
ssh -p <port> root@<vm-ip> \
  'mkdir -p /root/kt_longevity && nohup bash /root/kt_longevity/run_matrix.sh \
   > /root/kt_longevity/runner.out 2>&1 &'

# Periodic health pull (idempotent)
bash longevity_gpu/scripts/checkin.sh
```

## Stopping / resuming

```bash
ssh -p <port> root@<vm-ip> 'pkill -f run_matrix.sh; pkill -f kt_filter'
# Resume: just relaunch run_matrix.sh — a fresh sweep_<ts> dir is created.
```

## Novel records

`kt_filter` writes to `./novel_records.jsonl`, or to
`./novel_records_gpuN.jsonl` when `--gpu-device N` is supplied, with `fsync`.
`checkin.sh` merges those files back here on every check-in. **Any** k≥16 hit at the bit
ranges above is potentially novel — review against
`known/records.json` before celebrating.

## Knobs

Set via env when invoking `run_matrix.sh`:

| Var | Default | Meaning |
|-----|---------|---------|
| `WORKDIR` | `/root/kt_longevity` | base dir on remote |
| `DURATION_SEC` | `1800` | per-cell wall time |
| `CHUNK_TILES` | `500` | `--chunk-tiles` argument |
| `BIT_CAP` | `119` | upper limit on tested bits |
