# tests/ - shell and parser regression tests

This directory contains integration and regression tests around the CUDA runner,
checkpoint/resume behavior, feature smoke tests, and telemetry parsing.

## Files

| File | Purpose |
|---|---|
| `test_features_actually_run.sh` | External smoke tests for CUDA feature flags |
| `test_ckpt_identity_mismatch.sh` | Checkpoint identity mismatch behavior |
| `test_sigkill_resume_idempotent.sh` | SIGKILL/resume idempotence regression |
| `test_misalignment_regression.sh` | Remote GPU misalignment regression cases |
| `test_e2e_runner_soak.sh` | Remote end-to-end soak harness |
| `parse_runner_telemetry.py` | Parses runner logs into structured telemetry |
| `select_records_by_bit_bucket.py` | Selects records for benchmark/test buckets |
| `wheel_parity_KT19_P0_37.txt` | Canonical wheel-offset fixture used by CUDA tests |

## Running Tests

Most local coverage is reached through engine targets:

```bash
make -C src/cpu test
cd src/cuda && make test
```

Remote GPU tests require explicit `SSH_HOST`, `SSH_PORT`, and related
environment variables. They are intended for operator use, not for default CI.

## Runtime Artifacts

`tests/soak_artifacts/` is ignored and should contain only local run output.
Do not commit new soak logs or remote host captures.
