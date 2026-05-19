# GPU Filter Engines

Two GPU engines live here, built from the same Makefile:

## kt_filter_v8 (production)

`kt_filter_v8.cu` is the production search engine. It is decomposed into
multiple modules:

| Module | File | Role |
|--------|------|------|
| Main kernel | `kt_filter_v8.cu` | 2-D wheel-offset launch, filter cascade |
| Lanes | `kt_lanes.c` | Per-GPU prefix-lane assignment |
| Checkpoint | `kt_checkpoint.c` | Active checkpoint / resume |
| Novel record | `kt_novel_record.c` | fsync'd hit persistence |
| Records | `kt_records.c` | Record corpus loader |
| CLI | `kt_cli.c` | Argument parser |
| Signal | `kt_signal.cu` | SIGINT / SIGTERM handler |
| Reporter | `kt_reporter.cu` | Periodic progress reporter |
| Tests | `kt_tests.cu` | Embedded unit test suite |

**Key features:**
- Wheel-offset 2-D CUDA launch (one block per wheel slot × one thread per tile)
- `--wheel-expr X#[/Y...]` for non-plain-primorial Stage-0 wheels
- Barrett u128 modular reduction across L2 / ext-L2 / line-sieve stages
- Fermat-2 prefilter before host BPSW (CPU-side proving via GMP)
- `--exhaustive` mode with exact coverage tracking
- `--prefix-mode {sequential|random}` with per-GPU lane assignment
- Checkpoint / resume for multi-day campaigns
- Embedded `--test` suite and `--validate-known` gate

Build: `make kt_filter_v8`

Command-line options are documented in
[`../../docs/CUDA_CLI_REFERENCE.md`](../../docs/CUDA_CLI_REFERENCE.md).
Use `--wheel-expr` when you want one process to search a specific quotient
wheel such as `47#/31`; run multiple GPU-pinned processes for a wheel pool.
Measure unfamiliar expressions with `--smoke --max-batches 1` before long runs
because Stage-0 table size and downstream Fermat-2 load are pattern-dependent.

## kt_filter_v5 (oracle / reference)

`kt_filter_v5.cu` is the initial GPU implementation. It uses a streams-based
double-buffered launch (similar to the CC v15.cu ancestor) and a single-module
build. It achieves similar aggregate throughput to CC v15, but lacks most v8
features:

- Random sampling is supported for oracle testing. v5 random mode samples
  raw-candidate batches with `stride=1`; it does not use v8's wheel-offset
  tile geometry.
- No `--exhaustive` mode
- No checkpoint / resume
- No prefix-lane assignment
- No extended wheel (47#) support

v5 is kept as an oracle for cross-checking v8 filter correctness. It is not
used for production campaigns.

Build: `make kt_filter_v5`

## Difference summary

| Feature | v5 | v8 |
|---------|----|----|
| Launch style | streams + double-buffer | 2-D wheel-offset |
| Throughput (RTX 5090) | benchmark locally | benchmark locally |
| Random sampling | raw-batch chunks | wheel-offset chunks |
| Exhaustive mode | no | yes |
| Checkpoint / resume | no | yes |
| Prefix lanes | no | yes |
| Extended / quotient wheels | no | `47#`, `47#/Y[/Z...]` |
| Novel record persistence | shared JSONL | per-GPU JSONL |
| Embedded tests | legacy suite | current suite |
| Module decomposition | single file | 8 modules |

## Building

```bash
cd src/cuda
make kt_filter_v8          # production binary
make kt_filter_v5          # oracle binary
make test                  # build v8 + run --test + external smokes
make clean
```

Default GPU architecture: `sm_120` (RTX 5090 / Blackwell). Override with:

```bash
make kt_filter_v8 NVCC_ARCH=sm_89   # RTX 4090
```

`sm_120` requires a CUDA toolkit new enough to know Blackwell; the release
candidate was validated with CUDA 13.2 on RTX 5090. Older toolkits can still be
used for syntax/build checks against older architectures by overriding
`NVCC_ARCH`. For RTX 4090 / `sm_89`, use CUDA 11.8 or newer.
