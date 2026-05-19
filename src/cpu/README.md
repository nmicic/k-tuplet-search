> **Status:** Initial CPU implementation from the early stages of this project.
> This engine has not been extensively tested — development focus shifted to
> `src/cuda/kt_filter_v8.cu` which carries all production features (checkpoint/resume,
> exhaustive mode, extended wheel, GPU-scale throughput). The CPU engine may have
> latent bugs. Use it as a reference for the filter math or for low-volume
> verification on machines without a CUDA-capable GPU.

# kt_gmp_v1 — k-Tuplet CPU Search Engine

Port of `cunningham-chain-search/src/cpu/cc_gmp_v34_bit-vector_10.c` retargeted
from Cunningham chains to prime k-tuplets. Filter equivalence makes this a port,
not a rewrite — the v34 sieve discipline is preserved; the math is swapped.

## Build

```bash
cd src/cpu
make            # builds ./kt_search
make test       # runs the 50-test unit suite
make smoke      # runs --smoke for KT22_P0 / KT23_P0 / KT24_P0
```

GCC ≥ 10 with `__builtin_ctzll`, GMP, pthreads. `-O3 -march=native -flto`.

## Math

For pattern `B = {b_0, ..., b_{k-1}}` and prime `q`, candidate `n` is killed by
`q` iff some `n + b_i` is divisible by `q`, i.e. `n ≡ -b_i (mod q)`. So
forbidden residues are

```
forbidden_r[i] = (q - (b_i mod q)) mod q     for i = 0..k-1, then dedup
```

No modular inverse, no `2^i` ladder, no chain-length parameter. The depth
dimension that v34 indexed by chain position collapses entirely. Cross-check:
`visualizations/k-tuplet-analyzer/index.html:441` uses
`((-o) % p + p) % p` — mathematically identical. `gp/kt_lib_v1.gp`
`kt_pattern_forbidden(pat, q)` is the ground-truth reference.

## Wheel

The wheel modulus is a primorial p_n# (default `--primorial 5` → 11# = 2310).
The wheel is the set of residues r in `[0, primorial)` admissible for the
chosen pattern (i.e. `r mod q` is not forbidden for any prime q dividing the
primorial). Wheel construction is in `build_wheel()`; size matches the GP
reference `kt_admissible_count_mod`.

For high-k patterns (k ≥ 22) the wheel mod 2310 is tiny — typically 1 — because
forbidden sets nearly cover small primes. Higher primorials shrink survival
similarly per period; the engine handles either.

## Filter stages

Filter primes are partitioned by storage class, automatically excluding any
prime absorbed into the chosen primorial:

| Stage          | Range            | Storage                           |
| -------------- | ---------------- | --------------------------------- |
| L2 bitmask     | (max_pri, 64)    | `u64` per prime                   |
| ext-L2 byte    | (64, 128)        | 128-byte LUT per prime            |
| line-sieve     | (128, 863]       | packed `u64[14]` bitset per prime |

For each filter prime `q`, the per-(tile, wheel) residue is

    n mod q = (T_mod_q · primorial_mod_q + r_mod_q) mod q

Per-tile baseline is computed once and updated incrementally between tiles
(each tick: `+= primorial_mod_q`, conditional subtract `q`).

## Verification

Survivors of the full filter cascade are verified by testing primality of every
`n + b_i` via `mpz_probab_prime_p(_, 25)` (BPSW + 25 strong-MR rounds). Native
u128 Montgomery is included (matches v34's `mont_powm` math) and used by the
unit tests, but not on the hot verification path — record bases reach 100+ bits,
which is comfortably within u128 range, but BPSW gives near-certainty cheap
enough to use unconditionally.

### Optimization: Fermat-2 prefilter (`--opt-fermat`, default ON)

A single Fermat base-2 PRP test (`2^(n-1) mod n == 1`, one `mpz_powm`) screens
each candidate's k members ahead of BPSW. The vast majority of survivors are
composite at the first member; one Fermat call rejects them at a fraction of
the cost of a full BPSW + 25 strong-MR. Only candidates whose every member
passes Fermat then go through `mpz_probab_prime_p(_, 25)` exactly as before.

Certification is unchanged: every reported tuple still has BPSW + 25 MR on
each member. Disable with `--no-opt-fermat` for A/B comparison or debugging.
Per-thread Fermat scratch (`mpz_t r, nm1`) is held in `__thread` storage so
there is no `mpz_init`/`mpz_clear` cost per call. `--bench-jsonl` rows include
`fermat_tests`, `fermat_rejects`, and `opt_fermat` fields.

### Optimization (reference / lab only): u128 Montgomery on Fermat path (`--opt-mont-fermat`, **default OFF**)

When enabled and the largest member fits in 124 bits, the Fermat-2 prefilter
calls the in-tree u128 Montgomery (`fermat_base2_mont` → `mont_powm`) instead
of `mpz_powm`. The 124-bit gate (computed once per candidate from
`n + max_offset`) leaves clear headroom against the `n < 2^127` assert in
`mont_ctx_init`; above the gate, and when this flag is OFF, the Fermat path
runs `fermat_base2_gmp` unchanged. BPSW certification is unaffected — every
survivor still goes through `mpz_probab_prime_p(_, 25)`.

**Why default OFF on this engine.** The CPU search hot path is sieve-bound at
the bit ranges where the gate fires (~13–16 M cand/s vs. 16 K verifier-entries/s
on KT5_P0 / primorial=3 / 64-bit / 1 thread), so the Fermat layer accounts for
only a small fraction of CPU. At 64 bits, GMP's `mpz_powm` hits its tuned
1-limb assembly path and is hard to beat with a generic two-limb Montgomery
that pays a `compute_r_and_r2` setup per candidate. The Phase 4b-#3 A/B at
64 bits measured Mont-Fermat at ~0.97–1.02× of GMP-Fermat — no net headroom.

The implementation is kept (and exercised by T53) as a **reference for the
upcoming GPU port**, where every device candidate is a fixed-width integer
and a Montgomery Fermat is the natural primitive — `mont_mul`/`mont_powm`
here are the canonical scalar reference. Enable on the CPU side with
`--opt-mont-fermat` for ad-hoc experiments; bench JSONL gains
`fermat_mont_tests` (count of mont-served calls) and `opt_mont_fermat`.

### Optimization: read-side prefetch in bit-vector L2 build (`--opt-prefetch`, default ON)

When the bit-vector L2 filter is active, the block loop that OR-folds kill masks
from `g_bitvec.l2_kill` and `g_bitvec.extl2_kill` issues a `__builtin_prefetch`
for the next block's data one iteration ahead. This hides the L2/L3 miss latency
for the next block's first cache line fetch. On local hardware (non-AVX-512) the
gain is ~1-2% sieve throughput; on modern AVX-512 CPUs the hardware prefetcher
already covers the sequential access pattern and the explicit hint has no net
benefit. Disable with `--no-opt-prefetch` for A/B comparison.

### Optimization: ctzll bit-scan iteration (`--opt-bitscan`, default ON)

Phase 4b-#4 port of CC v34 OPT-B. When the bit-vector L2 filter is active and
not in sieve-only mode, the per-block hot loop iterates only the alive bits via
`__builtin_ctzll(survivors); survivors &= survivors - 1` instead of testing all
64 wheel slots per u64 block. L2 / ext-L2 kills are accounted by
`__builtin_popcountll` of the kill mask. Disable with `--no-opt-bitscan`.

Filter-bound win on KT9_P0 17# / wheel=120: i7 220M/s → 492M/s (**2.23×**),
remote AVX-512 EPYC 295M/s → 522M/s (**1.77×**). At wheel=1 with `--bitvec`
forced on (KT22_P0 11#) the gain is ~1% — almost nothing because there is at
most one alive slot per block — but no regression. T56 asserts the alive-bit
sequence emitted by ctzll matches the 0..63 bit-test sequence on a deterministic
mask. The Phase 4a-fix auto-disable threshold (`wheel × l2 < 64`) was retained;
re-tuning was not needed because the fast-path win at higher wheel sizes is
clear and the wheel=1 path is unchanged.

### Optimization: lifted line-sieve cap (`--opt-line-cap N`, default 863)

Phase 4b-#5. The line-sieve set was previously fixed at primes ≤ 863 with a
static `[CAP][14]` packed-bitset table. `--opt-line-cap N` lifts the cap to any
`N` in `[863, 65535]`; the kill table is dynamically allocated as a flat u64
buffer with stride `(N + 63) / 64`. Default `N = 863` is byte-identical to the
prior layout (stride = 14). Memory: `g_line_count × stride × 8` bytes —
~13 KB at 863, ~266 KB at 4096, ~6.7 MB at 65535.

When `N > 863`, primes in `(863, N]` are enumerated via Eratosthenes at startup
and added to the line-sieve set. The forbidden-residue table is built per-pattern
exactly as for the smaller cap. T57 asserts `kill_count(4096) > kill_count(863)`
on KT22_P0 (deeper sieve adds bits, never removes).

The lift is intended for high-k regimes where the wheel widens and many
candidates per tile reach the line-sieve stage. At low wheel sizes (e.g.
KT19_P0 11#, wheel=1) the upstream L2/ext-L2 stages already eliminate
~99.9996% of candidates before line-sieve is consulted, so the additional
primes in `(863, N]` rarely catch anything new while the per-tile baseline
maintenance loop (one mod per line-prime, per tile) lengthens proportionally
to `g_line_count`. In that regime, the lift slows search and should be left at
the default. Reach for it when line-sieve sees a non-trivial fraction of
candidates — typically larger primorials or patterns with leakier early stages.

## CLI

```
--pattern NAME         pattern from catalog (KT5_P0..KT24_P2)
--k N                  alias for --target N — picks default pattern for k
--target N             picks default pattern for k
--bits N               candidate base bit-size (required for search)
--primorial N          first N primes form the primorial (default 5 → 2310)
--threads N            worker thread count
--prefix 0bXXX         binary prefix to confine search
--random               random-chunk search (mutually exclusive with --prefix)
--chunk-tiles N        tiles per chunk in --random mode (default: 500)
--sequential           sequential-only compatibility flag; currently gates checkpointing
--output FILE          append found tuplets to FILE (fflush+fsync per record)
--quiet                minimal output
--full-quiet           suppress progress output
--pin                  pin worker threads to CPUs (Linux)
--pin-base N           base CPU index for pinning
--report N             alias for --report-interval-sec
--report-interval-sec N  reporter cadence in seconds (double; 0 disables)
--bench-jsonl FILE     in --validate-known, emit one JSON row per record
--max-batches N        stop after N batches
--max-time SEC         stop after SEC seconds
--sieve-only           skip primality verification (sieve benchmark)
--no-line-sieve        disable line-sieve stage
--no-bitvec            disable Armitage bit-vector L2 filter (forced off; debug / A-B compare)
--bitvec               force-enable bit-vector even at low wheel size (overrides auto-disable)
--no-opt-fermat        disable Fermat-2 PRP prefilter ahead of BPSW (default ON)
--opt-fermat           force-enable Fermat-2 PRP prefilter (this is the default)
--no-opt-mont-fermat   disable u128 Montgomery backend for Fermat (gates at 124 bits)
--opt-mont-fermat      force-enable u128 Montgomery Fermat backend (this is the default)
--no-opt-prefetch      disable read-side __builtin_prefetch in bit-vector L2 build
--opt-prefetch         force-enable prefetch hint (this is the default)
--no-opt-bitscan       disable __builtin_ctzll survivor iteration in bit-vector hot loop
--opt-bitscan          force-enable ctzll iteration (this is the default)
--opt-line-cap N       lift line-sieve cap to N (default 863, range [863, 65535])
--checkpoint FILE      kt-v1 checkpoint format (currently `--threads 1` only)
--resume               resume tile cursor from checkpoint
--ckpt-interval N      checkpoint interval seconds
--test                 unit-test suite
--smoke                Layer-2 single-batch sieve assertion
--validate-known [k]   reproduce records.json hits (gate: k=17,18,19)
```

## Search modes

Three modes select how worker threads claim tile windows:

- **default — sequential.** Walks `[tile_min, tile_max)` in order, shared
  cursor under `g_seq_lock`. Resumable via `--checkpoint`.
- **`--prefix 0bXXX` — sequential, confined.** Same shared-cursor scan,
  but `n_min`/`n_max` are clipped to the binary prefix range. Used by
  `--validate-known` to reproduce records in seconds.
- **`--random` — random-chunk.** Each thread picks a uniformly random
  tile in `[tile_min, tile_max)` via per-thread `gmp_randstate`, walks
  `--chunk-tiles N` (default 500) tiles forward, then picks again. PRNG
  is seeded from `/dev/urandom` (32 bytes), with per-thread streams
  derived via splitmix64 — so two machines (or two threads) draw
  uncorrelated tile windows. Mutually exclusive with `--prefix` and
  `--checkpoint` (no sequential cursor to save).

The startup banner echoes the active mode and seed source.

## Checkpoint format (kt-v1)

```
kt-v1
k=<int>
pattern=<string>
primorial_n=<int>
bits=<int>
prefix_bits=<int>
prefix=<hex>
tile=<hex>
```

The first line is a strict version sentinel. Anything other than `kt-v1` is
refused with `Refusing to resume from incompatible checkpoint format <ver>`.
Old `v33` checkpoints from cc-search are rejected. `kt-v1` checkpoints are also
rejected if their saved identity `(k, pattern, primorial_n, bits, prefix_bits,
prefix)` does not match the current CLI configuration.

## --validate-known

`--validate-known` depends on `tools/records_manifest.tsv`. If that manifest is
missing or stale, regenerate it with `python3 tools/parse_records_json.py`.

For each record matching `--k`, the harness runs a 2 s warm-up on the normal
filter path with verification skipped, then chooses an estimated `prefix_bits`
budget for roughly 60 seconds of work. The full search runs single-threaded
under a strict 60 s wall-clock cap. Each record produces one structured log
line:

    [k=17 KT17_P3] base=1620... OK time=0.0s prefix_bits=46 tput=500000/s

Gate: ≥1 OK each for k=17, 18, 19.

`--bench-jsonl FILE` writes one JSON object per record (k, pattern, base, bits,
prefix_bits, elapsed_s, cand, surv, prime_tests, fermat_tests, fermat_rejects,
opt_fermat, found, hit, tput_cand_per_s) for `tools/bench_record.py` to consume.

## Operational reporter

A periodic stderr reporter is active in regular search and `--validate-known`.
The cadence is set by `--report-interval-sec N` (double; supports sub-second
values; 0 disables). Format:

    cand: <N> (X.XXM/s) | surv: <N> (X/s) | P: <N> (X/s) | KT<k>+: <N> | <T>s [ETA: ...]
    DONE  cand: <N> surv: <N> P: <N> found: <N> elapsed: Ts avg: cand X/s prime Y/s

`--quiet`, `--full-quiet`, or `--report-interval-sec 0` suppress the reporter.
ETA is shown only for ranges large enough to be meaningful (skipped on
validate-known prefix shards).

## --smoke

`--smoke --pattern KT22_P0 --bits 60 --max-batches 1` runs a single 200 000-tile
batch in sieve-only mode and asserts:

- candidates ≥ 1e5
- L2 rejection > 0
- ext-L2 rejection > 0
- line-sieve rejection > 0

In sieve-only mode the inner loop tallies each stage independently rather than
breaking on the first kill (otherwise high-k patterns where L2 dominates would
never see ext-L2 / line-sieve rejections). The bit-vector L2 filter is also
auto-disabled in sieve-only mode for the same reason — its mask is the union
of L2+ext-L2 kills and cannot attribute either category individually.

## Optimization: Armitage bit-vector L2 filter

For each tile, a u64 kill-mask per 64-wide block of wheel offsets is OR-folded
across L2 and ext-L2 primes (one LUT lookup per (block, prime) once per tile),
then in the per-candidate loop a single bit-test replaces the prior 14
mod-checks per candidate. This is the v34 "bit-vector" optimisation reduced to
the kt-tuplet single-bucket geometry: no per-base, no mod-6.

`--no-bitvec` forces the stage off. `--bitvec` forces it on regardless of wheel
size. The engine also has an **auto-disable heuristic**: if `wheel_size × l2_count < 64`
(fewer than one full 64-bit word of candidates per per-(prime, block) bucket), the
per-bucket setup cost dominates and bit-vector is automatically disabled at startup
with a banner on stderr: `bit-vector: auto-disabled (wheel=N x l2=M < 64)`. This
fires for all k≥16 workloads at primorial 11# (wheel=1). Use `--bitvec` to override
the auto-disable if you need an explicit ON/OFF A-B comparison.

Decision summary:
- Default: auto-disable when `wheel * l2_count < 64`, otherwise enabled.
- `--no-bitvec`: forced off (no heuristic check).
- `--bitvec`: forced on, ignores the threshold.

Measured speedup (5s synthetic search, --bits 80, ON vs OFF cand/s, i7-7700):

| pattern  | primorial   | wheel | local | EPYC+AVX-512 |
|----------|-------------|-------|-------|--------------|
| KT9_P0   | 17# (510510)| 120   | 3.58x | 3.10x        |
| KT9_P0   | 13#  (30030)| 15    | 2.18x | 1.80x        |
| KT7_P0   | 13#  (30030)| 24    | 1.90x | 1.74x        |
| KT7_P0   | 17# (510510)| 240   | 1.78x | 1.70x        |
| KT5_P0   | 11#   (2310)| 12    | 1.26x | 1.22x        |
| KT16_P0  | 11#   (2310)| 1     | 0.81x | 0.75x        |
| KT17_P0  | 11#   (2310)| 1     | 0.81x | 0.79x        |
| KT22_P0  | 11#   (2310)| 1     | 0.82x | 0.76x        |

The bit-vector wins when wheel_size ≥ ~12. At wheel_size=1 the LUT setup overhead
exceeds the per-prime mod-check savings (~0.78-0.82× slowdown), so the auto-disable
heuristic fires and restores the ~14M/s baseline on i7-7700.

## Crash-safety

Every found record is durable on disk before `record_found_tuplet` returns:

- **Per-discovery write + fflush + fsync** — `persist_tuplet_to_file` calls
  `fflush` (moves stdio buffer to kernel page cache) then `fsync` (flushes the
  kernel page cache to storage). The record survives a kernel panic or power
  loss; `fflush` alone would not.
- **Stderr announcement** — `crash_safe_announce` emits `\n*** FOUND ... ***\n`
  via `write(STDERR_FILENO, ...)` before touching the log file. `write(2)` is
  unbuffered and bypasses stdio entirely; it survives even if the stdio state
  is corrupt or the log path is misconfigured.
- **atexit hook** — `final_log_flush` (registered via `atexit`) flushes and
  fsyncs the log file on any exit path, including unanticipated `exit(N)` calls.
- **SIGINT/SIGTERM handler** — first signal sets `shutdown_requested`; workers
  drain in-flight tile work and return; `pthread_join` waits for all threads;
  the log is flushed and fsynced before `main` returns. A second SIGINT calls
  `_exit(130)` with no cleanup.

## Open questions

- For `--primorial N ≥ 9` (23# = 223092870 and beyond) the wheel enumeration
  iterates over `primorial` integers at startup, which becomes slow. Real
  campaigns would want a streaming enumerator (CRT join). Capped at 8 for now.
- The validate-known harness picks `prefix_bits` from a coarse warm-up; for
  very small candidate ranges it overshoots `prefix_bits` (close to `bits`).
  This still works because the search range collapses to ~1 tile, but the
  reported `tput=1/s` number is misleading. A better warm-up would run for a
  fixed wall-clock floor (e.g. 0.5 s minimum) regardless of tile exhaustion.
