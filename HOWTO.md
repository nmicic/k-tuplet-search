# HOWTO — GPU k-Tuplet Search (kt_filter_v8)

`kt_filter_v8` is the production GPU engine for searching large prime k-tuplets.
It uses a staged CUDA filter cascade (wheel → L2/ext-L2 → line-sieve → Fermat-2)
followed by host-side BPSW proving. The practical record-search examples focus
on k ∈ {19, 20, 21}; k ≥ 22 is exploratory frontier search.

`kt_filter_v5` is the oracle engine used for cross-checking correctness.
Both are built from `src/cuda/`.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| NVIDIA GPU | Tested on RTX 5090 (sm_120). Override arch for other cards — see below. |
| CUDA toolkit | CUDA 13.x for `sm_120`; CUDA 11.8+ for `sm_89`; set `NVCC_ARCH` for the target GPU |
| libgmp-dev | `sudo apt install libgmp-dev` |
| gcc / g++ | Standard C11/C++17 build tools |

---

## Build

```bash
git clone https://github.com/nmicic/k-tuplet-search.git
cd k-tuplet-search/src/cuda

make kt_filter_v8          # production engine
make kt_filter_v5          # oracle / correctness reference
make clean
```

**Override GPU architecture** (default is sm_120 for RTX 5090 / Blackwell):

```bash
make kt_filter_v8 NVCC_ARCH=sm_89   # RTX 4090 (Ada Lovelace)
make kt_filter_v8 NVCC_ARCH=sm_86   # RTX 3090 (Ampere)
make kt_filter_v8 NVCC_ARCH=sm_80   # A100 (Ampere)
```

If `nvcc` reports `Value 'sm_120' is not defined`, the toolkit is too old for
Blackwell. Use CUDA 13.x for RTX 5090, or override `NVCC_ARCH` for the GPU you
actually have. For RTX 4090 / `sm_89`, use CUDA 11.8 or newer.

Both binaries land in `src/cuda/`.

---

## Verify the build

```bash
# Print version + build SHA
./kt_filter_v8 -V

# Run embedded test suite
./kt_filter_v8 --test

# List all supported admissible patterns
./kt_filter_v8 --list-patterns
```

`--list-patterns` prints the pattern names accepted by `--pattern`, plus each
pattern's `k`, diameter, and offsets. For the long-form option reference, see
[`docs/CUDA_CLI_REFERENCE.md`](docs/CUDA_CLI_REFERENCE.md).

Release validation snapshot, 2026-05-18: the production `sm_120` build was
checked on an RTX 5090 host with CUDA 13.2. `./kt_filter_v8 --test` completed
with `All 52 tests passed`, including known-record replay, wheel parity,
47# wheel oracle checks, checkpoint/resume, and pattern-list coverage.

---

## Primorial reference

The `--primorial N` flag selects the sieve wheel upper-prime (0-indexed):

| Flag | Wheel | Notes |
|---|---|---|
| (default / `--primorial 11`) | 37# | Default; works for K ≤ 19 at low bits |
| `--primorial 13` | 43# | Recommended for K=19 and K=21_P1 |
| `--primorial 14` | 47# | Recommended for K=20 and K=21_P0/K=22+ |

Higher primorial = fewer candidates reach the Fermat stage = faster per-candidate work
after a longer one-time wheel init (~2–3 min for 47#).

`--wheel-expr` supports non-plain-primorial wheels:

```bash
./kt_filter_v8 --pattern KT19_P0 --bits 100 --wheel-expr '47#/31/17' --random
./kt_filter_v8 --pattern KT20_P1 --bits 102 --wheel-expr '47#/31' --random
./kt_filter_v8 --pattern KT19_P0 --bits 100 --wheel-expr '43#' --random
```

`X#/Y/Z` means "all primes through `X`, except `Y` and `Z`". Dropped primes
must be smaller than `X`; use `43#`, not `47#/47`, for the lower plain wheel.
The engine normalizes drop order in logs and checkpoints, so `47#/31/17` is
recorded as `47#/17/31`, and resume works with either order. This is a
wheel-shape campaign feature, not the full CC-style fingerprint-pool engine.

Operational notes:

- `--wheel-expr` overrides `--primorial`; do not pass both expecting a pool.
- `X` and each dropped `Y` must be primes in the built-in wheel table through
  `47`; duplicate drops, drops outside `X#`, and dropping `X` itself are
  rejected.
- Dropped primes are not pre-rejected by Stage-0. Dropped primes that also
  appear in the L2 sieve are still caught there; with the current `47#` ceiling
  that means `41` or `43`. Dropped primes `<=37` bypass the GPU sieve stages and
  are rejected only by Fermat-2 and/or host GMP/BPSW proving, which is correct
  but more expensive.
- Dropping small primes such as `5`, `17`, or `31` can therefore create a
  throughput cliff even though correctness is preserved.
- Startup memory and time are proportional to the actual admissible residue
  count, not just the textual wheel size. Measure new combinations with
  `--smoke --max-batches 1` before launching long runs.

Example release-candidate measurements on RTX 5090, CUDA 13.2, `sm_120`:

| Pattern / wheel | Stage-0 admissible residues | Predicted wheel alloc |
|---|---:|---:|
| `KT19_P0 @ 43#/31` | `10,036,224` | `79.8 MiB` |
| `KT19_P0 @ 47#/31` | `281,014,272` | `2220.5 MiB` |
| `KT19_P0 @ 47#/29` | `357,654,528` | `2826.1 MiB` |
| `KT20_P1 @ 47#/31` | `123,941,664` | `980.6 MiB` |
| `KT20_P1 @ 47#/29` | `146,476,512` | `1158.9 MiB` |
| `KT20_P1 @ 47#/23` | `268,540,272` | `2124.7 MiB` |

The `/23` variant is valid, but can be heavier than `/29` or `/31` for these
patterns. Choose wheel-expression cells from measured admissible counts, not
from the dropped prime value alone.

---

## Validate known records (correctness gate)

Replays records from the corpus by narrowing search to the known prefix.
Use this after any engine change to confirm correctness is preserved.

```bash
# K=16 — 5 records, ~10s total (37# default)
./kt_filter_v8 --validate-known 16

# K=17 — 5 records, ~30s total (37# default)
./kt_filter_v8 --validate-known 17

# K=18 — 5 records (37# default)
./kt_filter_v8 --validate-known 18

# K=19 — 5 records, ~2 min total (must specify 43#)
./kt_filter_v8 --validate-known 19 --primorial 13

# K=20 — 5 records (~2 min total; 47# wheel init takes 2–3 min before first check)
./kt_filter_v8 --validate-known 20 --primorial 14 --validate-per-record-budget 90
```

Exit code 0 = `gate=PASS`. Non-zero = one or more records were not reproduced
within the configured per-record budget.

The K=16–19 gates are the fastest correctness check. K=20/21 records are larger
and can need a higher `--validate-per-record-budget`, especially with 47# wheel
initialization.

---

## Search — K=19 (KT19_P0, 43#)

K=19 is an active frontier. Known records sit at ~89–102 bits.
`KT19_P0` is the best-characterized pattern; `KT19_P1`/`KT19_P2`/`KT19_P3` also have records.

```bash
# Sequential search — 30-minute cell at 100 bits
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 --max-time 1800

# Random search (recommended for distributed/long runs — each instance picks
# a random starting point from /dev/urandom, no coordination needed)
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 --random --max-time 1800

# Save found records to a file
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 --random \
    --max-time 1800 --output found_kt19.txt

# Quiet mode (suppress progress lines)
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 --random \
    --max-time 1800 --full-quiet
```

Progress reporter output format:
```
[reporter] t=10.03s batches=8356 cand=6.20e+16 surv=0 hits=0 cand/s=6.01e+15
[reporter] kills: stage0=216082944 L2=204535799 ext=9887215 linesieve=1659020 fermat2=910
```

A healthy kill funnel satisfies: `stage0 > L2 > ext > linesieve > fermat2`.
Any inversion signals a wheel-alignment regression.

---

## Search — K=20 (KT20_P1, 47#)

K=20 is also an active frontier. Known records are at ~93–100 bits.
The 47# wheel-CRT join takes ~2–3 minutes before the first batch; this is normal.

```bash
# Random search — 30-minute cell at 102 bits
./kt_filter_v8 --pattern KT20_P1 --primorial 14 --bits 102 --random --max-time 1800

# KT20_P0 is equally valid
./kt_filter_v8 --pattern KT20_P0 --primorial 14 --bits 102 --random --max-time 1800
```

---

## Search — K=21 (sub-tuple of K=19 / K=20)

KT21_P1 ⊃ KT19_P0 (extends by offsets +82, +84).
KT21_P0 ⊃ KT20_P1 (extends by offset +84).
Any K=21 find is simultaneously a K=19 or K=20 find.

```bash
# KT21_P1 — use 43# (inherits from KT19_P0)
./kt_filter_v8 --pattern KT21_P1 --primorial 13 --bits 102 --random --max-time 1800

# KT21_P0 — use 47# (inherits from KT20_P1)
./kt_filter_v8 --pattern KT21_P0 --primorial 14 --bits 104 --random --max-time 1800
```

---

## Search — K=22+ (frontier / exploratory)

Luhn's record pages currently maintain large known examples through k=21; k≥22
searches here are exploratory. Use `--smoke` to verify the engine accepts a
pattern before a long run.

```bash
# Sanity smoke (a few seconds, GPU at 100% = engine accepts the pattern)
./kt_filter_v8 --pattern KT22_P0 --primorial 14 --bits 104 \
    --max-batches 200 --smoke

# Production run
./kt_filter_v8 --pattern KT22_P0 --primorial 14 --bits 104 --random --max-time 1800
./kt_filter_v8 --pattern KT22_P1 --primorial 14 --bits 104 --random --max-time 1800
./kt_filter_v8 --pattern KT22_P2 --primorial 14 --bits 104 --random --max-time 1800
./kt_filter_v8 --pattern KT22_P3 --primorial 14 --bits 104 --random --max-time 1800
```

The engine catalog extends through `KT28_P9`; inspect the full list with
`./kt_filter_v8 --list-patterns`.

---

## Multi-GPU search

Each GPU runs an independent instance. Use `--gpu-device N` to pin each instance
to a specific GPU. In `--random` mode each instance draws from `/dev/urandom`
independently — no explicit sharding needed.

```bash
# 4-GPU launch (run in separate terminals or tmux panes)
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 --random \
    --max-time 1800 --gpu-device 0 &
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 101 --random \
    --max-time 1800 --gpu-device 1 &
./kt_filter_v8 --pattern KT20_P1 --primorial 14 --bits 102 --random \
    --max-time 1800 --gpu-device 2 &
./kt_filter_v8 --pattern KT20_P1 --primorial 14 --bits 103 --random \
    --max-time 1800 --gpu-device 3 &
```

Wheel-expression campaign example:

```bash
./kt_filter_v8 --pattern KT19_P0 --bits 99  --wheel-expr '47#/31' --random \
    --max-time 43200 --gpu-device 0 --gpu-batch-size 2097152 --gpu-streams 3 &
./kt_filter_v8 --pattern KT19_P0 --bits 99  --wheel-expr '47#/29' --random \
    --max-time 43200 --gpu-device 1 --gpu-batch-size 2097152 --gpu-streams 3 &
./kt_filter_v8 --pattern KT20_P1 --bits 100 --wheel-expr '47#/29' --random \
    --max-time 43200 --gpu-device 2 --gpu-batch-size 2097152 --gpu-streams 3 &
./kt_filter_v8 --pattern KT20_P1 --bits 100 --wheel-expr '47#/23' --random \
    --max-time 43200 --gpu-device 3 --gpu-batch-size 2097152 --gpu-streams 3 &
```

For exhaustive sequential coverage across GPUs, use prefix-lane sharding:

```bash
# Divide [2^100, 2^101) into 4 lanes
for id in 0 1 2 3; do
  ./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 \
      --prefix-lanes 4 --prefix-lane-id $id --gpu-device $id \
      --exhaustive --max-time 86400 &
done
```

---

## Checkpoint / resume

```bash
# Run with checkpoint (saved every 60s by default)
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 --random \
    --max-time 3600 --checkpoint /tmp/kt19_ckpt.json

# Resume from checkpoint
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 --random \
    --max-time 3600 --checkpoint /tmp/kt19_ckpt.json --resume

# Adjust checkpoint interval (default 60s)
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 \
    --checkpoint /tmp/ckpt.json --ckpt-interval 300
```

Checkpoints include the normalized wheel expression. A checkpoint from
`--wheel-expr '47#/31'` is not compatible with a plain `--primorial 14` run, and
pre-`--wheel-expr` checkpoints are intentionally not resumed under
`--wheel-expr`.

---

## Output — found records

When a k-tuplet survives all stages (GPU filter + host BPSW prove), the binary:

1. Prints `*** FOUND k=N ... ***` to stdout
2. Appends a JSON line to `novel_records_gpu{N}.jsonl` in the working directory
   (where N is the GPU device index)
3. If `--output FILE` is given, also appends to that file

```bash
# Inspect any finds (multi-GPU run, from each process working directory)
cat novel_records_gpu0.jsonl
cat novel_records_gpu1.jsonl
```

---

## Correctness oracle — v5 vs v8

`kt_filter_v5` is the reference implementation. Running the same search on both
engines and comparing kill-funnel ratios is a quick sanity check after large v8
changes. Treat throughput as configuration-dependent; compare correctness
signals first (`surv`, kill ratios, and found-record replay).

```bash
# Build v5
make kt_filter_v5

# Run both on the same small bit range for a few seconds
./kt_filter_v5 --pattern KT19_P0 --primorial 13 --bits 98 \
    --max-time 30 2>&1 | grep 'kills:\|surv='

./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 98 \
    --max-time 30 2>&1 | grep 'kills:\|surv='
```

Compare the `L2/(stage0)` and `ext/L2` kill ratios between the two runs.
Any divergence > 1% in these ratios is a correctness signal worth investigating.

v5 also supports random oracle runs for sampling-path comparisons:

```bash
./kt_filter_v5 --pattern KT19_P0 --bits 98 --random \
    --random-seed 0x1234 --chunk-tiles 1 --max-time 30
```

Unlike v8, v5 samples raw consecutive candidate batches with `stride=1`; the
v8 primorial-alignment bug class does not apply to v5 random cursors.

---

## Performance reference (RTX 5090, sm_120)

Throughput depends strongly on pattern, wheel, bit range, batch size, stream
count, GPU clocks, and whether you are reading raw coverage or useful
wheel-admissible candidate rate. The public tree does not ship historical
benchmark histories; run a local 30-second anchor on the target machine:

```bash
./kt_filter_v8 --pattern KT19_P0 --primorial 13 --bits 100 \
    --max-time 30 --full-quiet
```

Note: cand/s numbers include all wheel-admissible candidates before the filter
cascade. Higher is not strictly better — use kill-funnel ratios as the
correctness signal.

Benchmark helpers write generated JSONL under ignored `bench/` paths. See
[`TESTING.md`](TESTING.md) for the validation and benchmark workflow.

---

## Known issues

No public-release blocking correctness issue is documented here.

---

## CPU engine

The CPU engine (`kt_gmp_v1`) lives in `src/cpu/` with its own
[`HOWTO_RUN.md`](src/cpu/HOWTO_RUN.md). It is slower but requires no GPU
and serves as an independent correctness reference.
