# Testing

This project has three validation layers: local deterministic checks, known-record
replay, and optional remote GPU soak/benchmark runs. Historical benchmark
histories are not shipped in the public tree; benchmark scripts regenerate
JSON/JSONL under ignored `bench/` paths.

## Local Checks

Run these from the repository root after documentation, pattern, or engine
changes:

```bash
python3 -m json.tool known/records.json >/dev/null
python3 -m json.tool tools/patterns/name_locks.json >/dev/null
python3 tools/patterns/validate_pattern.py --self-test
python3 tools/patterns/test_pattern_tools.py --quiet
gp -q gp/kt_lib_v1.gp
make -C src/cpu test
```

CUDA builds require `nvcc`, GMP, and a compatible NVIDIA stack:

```bash
cd src/cuda
make
make test
```

The CUDA self-tests include known-record replay, parser checks, and fixture
checks such as `tests/wheel_parity_KT19_P0_37.txt`.

Release validation snapshot, 2026-05-18:

```text
Host: RTX 5090, CUDA 13.2, target arch sm_120
Command: cd src/cuda && ./kt_filter_v8 --test
Result: All 52 tests passed
```

That suite includes known-record replay, wheel parity, 47# wheel oracle checks,
checkpoint/resume, prefix-lane alignment, generated pattern-list coverage, and
observability-output schema checks.

## Known-Record Replay

CPU replay is the easiest correctness smoke test:

```bash
make -C src/cpu
src/cpu/kt_search --validate-known --k 17
```

GPU replay uses the generated manifest in `tools/records_manifest.tsv`:

```bash
cd src/cuda
make kt_filter_v8
./kt_filter_v8 --validate-known --k 19 --max-time 60
```

After GPU engine changes, also exercise the production path on a real GPU
server. This covers `--prefix-mode sequential` and `--prefix-mode random`,
which can differ from the internal `--test` and `--validate-known` paths:

```bash
SSH_HOST=root@<gpu-host> SSH_PORT=<port> \
  bash longevity_gpu/scripts/validate_records_external.sh
```

Any selected known record that fails to print the expected `FOUND` base is a
correctness regression.

## Remote Soak Tests

Remote scripts require explicit connection details; there are no public default
hosts or ports.

```bash
SSH_HOST=root@<gpu-host> SSH_PORT=<port> \
  bash longevity_gpu/scripts/build_remote.sh

SSH_HOST=root@<gpu-host> SSH_PORT=<port> \
  bash tests/test_e2e_runner_soak.sh
```

Runtime output belongs in ignored paths:

```text
tests/soak_artifacts/
scripts/longevity_gpu/runs/
bench/
tmp/
```

Do not commit soak logs, copied remote journals, benchmark histories, or local
engine binaries.

## Benchmarks

Use benchmarks as local regression signals, not portable performance claims.
Throughput depends on pattern, wheel, bit range, GPU model, clocks, batch size,
stream count, and host load.

```bash
python3 tools/bench_record.py
python3 tools/bench_gpu_record.py --remote-host <gpu-host> --remote-port <port> \
  --pattern KT19_P0 --bits 100 --max-time 30
python3 tools/bench_compare.py --leaderboard
```

Gate convention:

```text
cand/s drop >= 20%   REGRESSION
cand/s drop 10-20%   WARN
cand/s rise >= 10%   IMPROVED
otherwise            OK
```

For GPU comparisons, only compare saturated rows (`gpu_util_pct_min >= 95`).
For production-style comparisons, prefer Time-To-Record via `tools/kpi_run.py`;
the current KPI suite is a sparse known-record replay suite, not a proof of
record-search coverage in 100-bit-plus ranges.
