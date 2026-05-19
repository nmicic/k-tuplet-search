# HOWTO_RUN — testing kt_gmp_v1 on another server

Quick reference for building and running the CPU engine (`kt_gmp_v1`) on any Linux box.

## What works today vs. what's coming

| Mode | Status | Flag(s) |
|------|--------|---------|
| `--test` (50→53 unit tests) | works | `--test` |
| `--smoke` (single-tile sanity) | works | `--smoke --pattern NAME --bits N --max-batches 1` |
| Sequential search | works | `--pattern NAME --bits N --max-time SEC` |
| Sequential with binary prefix | works | `--prefix 0bXXX` |
| Validate-known (replay records via prefix shards) | works | `--validate-known [--k N]` |
| Random-chunk search (`/dev/urandom` seed, xoshiro256**) | works | `--random --chunk-tiles N` |
| fsync + crash-safe log persistence | works | always-on |
| Checkpoint/resume (single-thread) | works | `--checkpoint FILE [--resume]` |
| `--bench-jsonl` per-record JSON for downstream regression tracking | works | `--bench-jsonl PATH` |
| `--report-interval-sec FLOAT` operational reporter | works | `--report-interval-sec 1.0` |

## Build (any Linux box with gcc, libgmp, pthread)

```bash
git clone https://github.com/nmicic/k-tuplet-search.git
cd k-tuplet-search
make -C src/cpu
./src/cpu/kt_search --help
./src/cpu/kt_search --test
```

Built binary lands at `./src/cpu/kt_search`.

## Validate-known: the regression replay

Reproduces records from `tools/records_manifest.tsv` via prefix sharding.
Most records run in under 60s on a moderate CPU; larger k=20/21 records can
need a higher time budget.

```bash
# All k tiers (16-21) — the canonical regression run
./src/cpu/kt_search --validate-known

# Single tier
./src/cpu/kt_search --validate-known --k 17

# Quiet, with bench JSONL capture
./src/cpu/kt_search --validate-known --k 17 --quiet --bench-jsonl /tmp/run.jsonl

# Time-bounded per-record (safety cap)
./src/cpu/kt_search --validate-known --k 17 --max-time 60
```

Pass: `OK (touched=N)` per k. Records are listed individually with `tput=...M/s` and `prefix_bits=...`.

## Sequential search with prefix (current production mode)

```bash
# Search KT19_P0 records at 89 bits, prefix top 3 bits = 101, 1 thread, max 60s
./src/cpu/kt_search --pattern KT19_P0 --bits 89 --prefix 0b101 --threads 1 --max-time 60

# Heavy: higher k, longer prefix, multi-thread
./src/cpu/kt_search --pattern KT22_P0 --bits 100 --prefix 0b1101 --threads 8 --max-time 600 --output /tmp/kt22_finds.txt

# With operational reporter (1 s cadence on stderr)
./src/cpu/kt_search --pattern KT19_P0 --bits 89 --prefix 0b1101 --threads 1 --max-time 60 --report 1.0
```

## Recommended commands per k tier — known-record replay (all <128 bits)

GPU operating envelope: **n ≤ 127 bits** at CGBN TPI=4 (CC's choice; gives 1 bit of headroom for the offset add). All known records sit comfortably below this.

| k | typical record bits | primorial | command |
|---|---|---|---|
| 16 | ~62-72 | 11# (5) | `./src/cpu/kt_search --validate-known --k 16` |
| 17 | ~71-80 | 11# (5) | `./src/cpu/kt_search --validate-known --k 17` |
| 18 | ~80-95 | 11# (5) | `./src/cpu/kt_search --validate-known --k 18` |
| 19 | ~89-102 | 11# (5) | `./src/cpu/kt_search --validate-known --k 19` |
| 20 | ~93-107 | 11# (5) | `./src/cpu/kt_search --validate-known --k 20` |
| 21 | ~99-115 | 11# (5) | `./src/cpu/kt_search --validate-known --k 21` |
| 22-24 | not yet found, hunting | 11# (5) | `./src/cpu/kt_search --pattern KT22_P0 --bits 100 --max-time 600` |

For k=22-24 there are no known records to replay. Real search = `--pattern` + `--bits N` + `--max-time` (or `--max-batches`) + optional `--prefix` to shard.

## Optimization flags (Phase 4b status)

```bash
# Default: bit-vector auto-disable at low wheel, prefetch ON, Fermat-2 prefilter ON,
# u128-Mont-Fermat OFF (reference-only).
./src/cpu/kt_search --pattern KT9_P0 --primorial 7 --bits 80 --max-time 5

# Force bit-vector ON even at low wheel
./src/cpu/kt_search --pattern KT22_P0 --primorial 5 --bits 100 --max-time 5 --bitvec

# Disable Fermat-2 prefilter
./src/cpu/kt_search --pattern KT5_P0 --primorial 3 --bits 64 --max-time 10 --no-opt-fermat

# Force u128 Montgomery on Fermat path (lab/reference; default is OFF on this engine)
./src/cpu/kt_search --pattern KT5_P0 --primorial 3 --bits 64 --max-time 10 --opt-mont-fermat

# A/B comparison harness — one record × two flags
./src/cpu/kt_search --pattern KT9_P0 --primorial 7 --bits 80 --max-time 5 --bench-jsonl /tmp/on.jsonl
./src/cpu/kt_search --pattern KT9_P0 --primorial 7 --bits 80 --max-time 5 --no-opt-prefetch --bench-jsonl /tmp/off.jsonl
```

## Bench gate

```bash
# Append a per-commit row to bench/history.jsonl. Diffs against most-recent prior row
# for the same (k, pattern, base). Exit 1 on REGRESSION (>20% cand_per_s drop).
python3 tools/bench_record.py
```

The first run on a new SHA prints BASELINE rows. Subsequent runs print OK /
IMPROVED / WARN / REGRESSION per record. Generated benchmark history lives
under ignored `bench/` paths; see [`../../TESTING.md`](../../TESTING.md).

## Notes

- Default `--threads 1` matches the production-prove-path budget (8 threads for prove on a multi-GPU box; we measure single-thread throughput as the meaningful number).
- `--full-quiet` suppresses the per-second reporter line — use when scripting; pair with `--bench-jsonl` for capture.
- `--checkpoint FILE` is single-thread only by design; multi-thread checkpoints rejected at startup. Resume via `--resume`.
- For repro, capture `git rev-parse --short HEAD` alongside any timing run.
