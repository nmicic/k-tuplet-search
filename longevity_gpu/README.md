# longevity_gpu/ - remote GPU longevity harness

This directory contains operator scripts and notes for long-running GPU search
or stability campaigns. These scripts are useful for reproducing campaign-style
runs, but they are not required for basic local builds or tests.

## Contents

| Path | Purpose |
|---|---|
| `scripts/README.md` | Main operator guide for bootstrapping, building, launching, and checking in |
| `../TESTING.md` | Test discipline, benchmarks, and operational validation notes |
| `scripts/bootstrap_vm.sh` | Prepares a fresh Ubuntu GPU VM |
| `scripts/build_remote.sh` | Uploads source and builds on a remote GPU host |
| `scripts/run_matrix.sh` | Runs repeated pattern/bit-band campaign cells |
| `scripts/checkin*.sh` | Pulls logs and novel-record JSONL back to the local machine |
| `scripts/validate_records_external.sh` | Remote known-record validation helper |
| `testing_benchmark_plan.md` | Historical benchmark/test plan |
| `lowbits_timing_2026-05-10.md` | Historical low-bit timing notes |

## Usage Model

Set connection details explicitly:

```bash
SSH_HOST=root@<gpu-host> SSH_PORT=<port> \
  bash longevity_gpu/scripts/build_remote.sh
```

The scripts intentionally avoid hard-coded public host defaults. Long-running
campaign output should stay in ignored run directories or external storage.

## Release Scope

Longevity runs are stability and random-sampling evidence. They are not an
exhaustive record-search proof and should not be described as covering a full
100-bit range.
