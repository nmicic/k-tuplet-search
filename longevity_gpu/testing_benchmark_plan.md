# Testing benchmark plan — engine-version comparison via exhaustive sweep

**Status:** draft for review — captures the proposal we sketched on 2026-05-10 after the lowbits campaign produced clean per-bit timings.
**Goal:** a single-number, apples-to-apples wall-time benchmark for comparing engine versions (v5 vs v8 vs future) on identical workloads.

---

## Why an exhaustive cell is the right benchmark

A `kt_filter_vN --exhaustive --bits B --primorial P --pattern X` invocation is:

- **Deterministic** — no `/dev/urandom` seed variation between runs (random mode does seed each cell, exhaustive walks `[2^(B-1), 2^B)` linearly).
- **Self-terminating** — engine emits `PREFIX EXHAUSTED at <ts> bits=B admissibles_tested=N walltime_s=W` when the prefix is fully walked, so the wall-time number is well-defined.
- **End-to-end** — exercises the whole filter cascade: Stage 0 wheel admissibility → L2 (6 primes) → ext-L2 (7 primes) → line-sieve (125 primes) → Fermat-2 → host BPSW. A regression in any stage shows up.
- **Coverage-checked** — the engine prints `coverage_ratio=1.0000 unique_tiles_visited=expected_unique_tiles_for_seed`, so we can sanity-check that the run actually completed all expected work, not just exited early.

Synthetic micro-benchmarks (just the kernel, just one filter stage) miss inter-stage hand-off costs and host-prove handoff. Exhaustive cell wall-time is the realistic number.

## Tier structure

Three cells of escalating weight. Run all three on the same hardware, same pattern, same wheel; record the wall time of each.

### Tier 1 — quick smoke (sub-minute)
```sh
./kt_filter_vN --exhaustive --pattern KT22_P3 --bits 64 --primorial 14 \
               --gpu-device 0 --gpu-batch-size 2097152 --gpu-streams 3
```

- **Purpose:** "is this version even in the right ballpark?" — catches order-of-magnitude regressions immediately.
- **Why these flags:** matches the production lowbits campaign so the result is directly comparable to historical timings in `lowbits_timing_2026-05-10.md`.
- **Why bits=64 rather than 60:** at b60 the search is one wheel period, finishing in ~30 ms — the wall time is dominated by 47# wheel allocation (~45 s for KT22_P3) and tells you nothing about the search itself. b64 has 16 wheel rotations, so the search portion is ~70 ms — still dominated by setup, but high enough that small kernel-level regressions are detectable as a 5-10 % shift in wall time.
- **Expected wall time on RTX 5090 + v8:** ~46 s for KT22_P3 (per captured table). Of that, ~45 s is wheel allocation and ~1 s is actual exhaust.
- **What it cannot tell you:** anything about the filter cascade, since the search portion is too short. Use as a presence/absence check, not as a quality metric.

### Tier 2 — primary metric (minutes)
```sh
./kt_filter_vN --exhaustive --pattern KT22_P3 --bits 76 --primorial 14 \
               --gpu-device 0 --gpu-batch-size 2097152 --gpu-streams 3
```

- **Purpose:** the real number. Long enough that wheel-setup overhead is < 5 % of total, short enough to iterate during development (median **21 min on v8 RTX 5090**).
- **Why bits=76:** at b76 we are firmly inside the doubling regime — every bit beyond it is exactly 2× the previous (per captured `lowbits_timing_2026-05-10.md` doubling table), so b76 wall time is a clean throughput proxy for any bit ≥ b75.
- **What it tells you:** filter-cascade throughput. A regression in L2/ext-L2/line sieve, in the survivor-count drain, in Fermat-2, or in host BPSW handoff will all show up here.
- **Expected wall time on RTX 5090 + v8:** ~414 s ≈ 7 min for KT24_P3 (lightest pattern), ~1270 s ≈ 21 min for KT22_P3 (heaviest). Use the same pattern for every comparison run; KT22_P3 is recommended because it is the heaviest and most discriminating.

### Tier 3 — soak / projected only (do not actually run for benchmark)
```
bits=80   # ~11 h on KT22_P3 v8, ~106 min on KT24_P3 v8
```

- **Do not run b80 as a benchmark.** It costs too much GPU time per iteration. Instead, **extrapolate** from Tier 2 using the doubling rule: `T(80) ≈ 16 × T(76)`. The captured data shows the doubling factor stays within 1 % of 2.00× from b76 onward, so the extrapolation is trustworthy.
- Run b80 only as a **soak test before a release** — confirms the doubling extrapolation actually holds (large workload, more chance for memory leaks, kernel correctness drift, etc.) and produces an end-to-end "GPU-day" cost number.

## Comparison protocol

For each engine version under test:

1. **Build clean.** Same `nvcc` flags, same arch, same `kt_filter_vN.cu` source, no debug instrumentation.
2. **Same hardware.** Run the comparison series back-to-back on the same physical GPU. Don't compare a v5 number from a 4090 box to a v8 number from a 5090 box — too many variables. The 4× RTX 5090 box is the canonical bench rig.
3. **Same pattern.** KT22_P3 / 47# is the recommended fixed point: heaviest active pattern in the lowbits catalog, and we have ground-truth historical data for it. (Use a different pattern only if the goal is specifically pattern-sensitive analysis.)
4. **Run each tier 3 times.** Report median wall time. The variance on b76 is ~1 % across the 4 captured cells in the campaign data — anything outside ~5 % across runs is a problem with the box, not the engine.
5. **Capture two numbers per run, not one.**
   - `walltime_s` from the `[exhaustive] PREFIX EXHAUSTED` banner — this is the search-only number, no setup.
   - `elapsed_sec` from the runner JSONL row — this is wall-clock from process start, includes wheel setup.
   - Compare both. A version that's faster on `walltime_s` but slower on `elapsed_sec` has regressed wheel allocation; one slower on `walltime_s` but unchanged on setup has regressed the cascade.
6. **Verify coverage.** Each run must show `coverage_ratio=1.0000` in the final-stats line. If coverage_ratio < 1.0, the run was truncated and the wall time is meaningless.

## What to record in `bench/benchmark_<version>.jsonl`

One line per run:

```json
{
  "version": "v8",
  "build_sha": "4f936d3",
  "host": "gpu-server-1",
  "gpu": "RTX 5090",
  "pattern": "KT22_P3",
  "bits": 76,
  "primorial": 14,
  "tier": 2,
  "walltime_s": 754.0,
  "elapsed_sec": 798,
  "coverage_ratio": 1.0,
  "admissibles_tested": 740520000,
  "started": "2026-05-10T...",
  "ended":   "2026-05-10T..."
}
```

The runner already records most of this (see `run_lowbits.sh` JSONL emission). A bench harness would parse `--exhaustive` stdout for the `walltime_s` figure on the `PREFIX EXHAUSTED` banner and write the row.

## Why "scan 64 bits in full" is *not* a good benchmark for v5 vs v8

We discussed this — it sounds clean ("full coverage of 64-bit space") but the numbers come out misleading because:

- At b64 with 47#, the search portion is ~1 s; everything else (45 s) is wheel setup. Two engine versions running back-to-back tests would show ~50 s vs ~50 s with the *real* difference (search throughput) hidden in the noise of wheel allocation.
- Use b76 instead: same code path, same coverage proof, but search is 99 % of wall time.

If 64 bits is required (e.g. for parity with CC's "scan up to 64 in a day on 16 GPUs"), use a smaller wheel (e.g. 37# = `--primorial 11`) so the search portion is meaningful — but then comparison with the historical 47# numbers is no longer apples-to-apples.

## Forward projection (the question this benchmark answers)

With Tier 2 (b76) wall time as the anchor and the doubling rule, anyone can compute "how long to scan up to b N":

```
Time to fully exhaust bit N = T(76) × 2^(N-76)
```

Pre-filled for the v8-on-5090 numbers we already have:

| bits target | KT24_P3 (lightest) | KT22_P3 (heaviest) |
|------|---------------------|---------------------|
| 80   | ~106 min            | ~11 h               |
| 85   | ~56 h               | ~14 days            |
| 90   | ~75 days            | ~470 days           |
| 95   | ~6.5 years          | ~40 years           |
| 100  | ~200 years          | ~1300 years         |

**Decision boundary:** b90 is the practical ceiling for exhaustive at this pipeline weight. Beyond b90, switch to random sampling at higher wheel/primorial — that's the K=19 / b89..b119 territory the previous campaign covered.

## Open questions for the operator

1. **v5 already-known numbers?** Operator mentioned ~130 G/s for v5 vs ~80 G/s aggregate for v8. If v5 has a Tier 2 number from a previous run, we should ingest it for the comparison baseline. If not, the first action under this plan is to run the three tiers on v5 and v8 back-to-back on the same GPU.

2. **Pattern coverage for the bench fixed point.** KT22_P3 is the heaviest in the lowbits catalog. If the goal is to optimize for the *lightest* common case (e.g. low-k high-d patterns), pick a different fixed point. The principle is the same.

3. **Bench harness location.** A natural home is `tools/bench/benchmark_engine.sh` — driven by the same SSH config as the campaign, writing to `bench/benchmark_<sha>.jsonl`. Wire-up is small (~50 lines) once the plan is approved.

4. **Cadence.** Run the bench (a) on every engine release tag, (b) on every PR that touches `src/cuda/kt_filter_v8.cu` (or its v5/v6/v7 ancestors), (c) before any campaign-config change. Pre-merge gates on Tier 2 wall-time deltas would catch regressions before they cost real GPU days.
