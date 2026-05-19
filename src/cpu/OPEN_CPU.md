# OPEN_CPU.md — open issues in `src/cpu/kt_gmp_v1.c`

Single-source inventory of CPU-side items still on the table at the moment we pivot to Phase 3 GPU baseline.

CPU is positioned as the **reference / lab implementation**; GPU is production. CPU optimizations that don't measurably win at current workloads are kept as opt-in flags, not deleted. Reasoning: future workload shifts (higher bits, looser sieves, different patterns) may activate them, and the GPU port cherry-picks tested CPU building blocks.

---

## A. Known code-correctness items

These were flagged during code review at the Phase 2 gate and survived through the Phase 4b sweep without being addressed in any of the perf commits.

| # | Severity | Item | Location | Notes |
|---|---|---|---|---|
| A1 | MAJOR | `realloc` return value unchecked → NULL deref on OOM | `kt_gmp_v1.c:994` (load_records_manifest) | one-line fix; OOM crashes via NULL deref on next `arr[count++]` |
| A2 | MAJOR | Double-free in `run_validate_known` cleanup | `kt_gmp_v1.c:1140-1154` | first loop frees [0..break_j-1], breaks; second loop re-frees the same range. Latent today (matches almost always at j=0) but the post-Phase-4 wider survivor windows make this more reachable. Fix: drop the inner `free`; let the second loop own cleanup |
| A3 | MINOR | `strdup` return unchecked | `record_found_tuplet` | OOM → NULL deref / lost record |
| A4 | MINOR | `g_search_complete` non-volatile (data race in theory) | global | safe on x86 in practice; pedantically a race. Mark `volatile sig_atomic_t` to match `shutdown_requested` |
| A5 | MINOR | T49 `_old_checkpoint_magic_recognized` never calls `load_checkpoint` | tests | exit-on-bad-version path is technically uncovered; test name is misleading |
| A6 | MINOR | `printf("%.1fs", elapsed)` rounds true 0.02s hits to 0.0s | banner / per-record log | bump to `%.2fs` so an instant lookup is distinguishable from real sieve work |
| A7 | MINOR | `make test` does not include smoke + validate-known | Makefile | sieve regression slips past `make test`. Add `make check-all` covering `--test` + `--smoke` + `--validate-known` |

**Recommended action:** A1-A4 + A7 in a single fix pass. A5 and A6 are cosmetic — defer.

---

## B. Optional optimizations skipped (deferred to GPU)

After the user's observation that L2 + ext-L2 (primes 37-97) kill ~99.9996%+ of candidates on production patterns, the remaining Phase 4b items hit diminishing returns on CPU. Their concepts fold directly into the GPU port.

| # | Item | CPU expected gain | GPU plan |
|---|---|---|---|
| B1 | **Trial-division layer** between line-sieve and BPSW (CC v34 has TRIAL_PRIMES; cheap small-prime mod check before Miller-Rabin) | <1% on CPU — survivor input rate is already ~kHz | Phase 3 Stage 1: 51 odd primes (41-256) per-candidate residue mod 32-bit, broadcast-cached, DPX-accelerated on Hopper/Blackwell |
| B2 | **Smart prove-order in BPSW** (test the "hardest-fails-first" position; 4b-#7 in original queue) | <1% on CPU — few survivors means few prove calls | Phase 3 Stage 3a/3b: 17-tuple inner loop runs 64-bit Fermat first; on all-pass, outer 4 positions get 128-bit Fermat. Order is naturally optimized by the staged design |
| B3 | **`mont_ctx_init`'s 256-iter `compute_r_and_r2`** (per Phase 4b-#3 follow-up note from worker) | currently dwarfed by GMP's tuned 1-limb path; replacing with one Barrett / 64-bit `__int128` reduction would close the residual gap at 64 bits | Not relevant — GPU uses CGBN's mont_ctx, not this code path |
| B4 | **Profile-guided build** (`-fprofile-generate` / `-fprofile-use`) | 3-7% typical for sieve-style code per survey | N/A on GPU |

**Recommended action:** none on CPU. Track in this file so future-readers know we considered + rejected on cost-benefit grounds.

---

## C. Lab-kept opt-in flags (default OFF / baseline)

Optimizations that were implemented and tested but didn't measurably win on the current engine. Kept as opt-in references, not deleted.

| flag | default | when-to-enable | pairs-with |
|---|---|---|---|
| `--opt-mont-fermat` | OFF | future verifier-bound CPU workloads where GMP's 1-limb tuning no longer dominates (multi-limb regime, n > 2^64) | `--opt-fermat` (must be ON) |
| `--opt-line-cap N` (N > 863) | 863 | future patterns / higher bits / different primorials where L2+ext-L2 cascade hasn't saturated; build-phase cost ~doubles at cap=4096 | none |
| `--bitvec` (force-on at low wheel) | auto-disabled when wheel·l2 < 64 | benchmarking only; never net-positive in production at wheel=1 | always-paired with the auto-disable threshold review when ctzll lands (4b-#4 done; threshold left at 64) |

**Recommended action:** none. Each flag has a banner state and a commit message documenting why.

---

## D. Auto-disable threshold revisit (Phase 4a-fix)

The bitvec auto-disable trigger is `wheel × l2_count < 64`. After Phase 4b-#4 (ctzll bit-scan) made the bit-vector hot path materially cheaper, KT22_P0 11# wheel=1 with `--bitvec` force-on is now **+0.8% vs OFF** instead of −18%. Still slightly net-negative against the auto-disabled OFF baseline (~14M/s) but close enough that a different threshold or a different sub-condition (e.g., k_count threshold) could make it net-positive.

Worth revisiting **only if** an actual workload starts showing net-negative behavior at the current threshold. Today, no such workload — OFF/auto-disable is right.

**Recommended action:** flag for future revisit. No change today.

---

## E. Multi-thread / scaling items

| # | Item | Status |
|---|---|---|
| E1 | Multi-thread checkpointing | Intentionally unsupported; `--checkpoint --threads >1` rejected at startup. Needs a real completed-range tracker per worker; not on the critical path because production prove path uses 8 threads on the GPU box and checkpointing is single-thread-only by design |
| E2 | Manifest TSV parser | Does NOT sanitize embedded tabs/newlines in record fields. Today no record contains them; if a future record's pattern name includes a tab the load will silently truncate. Switch to JSON Lines if columns grow |
| E3 | `compute_search_range()` overshoot | Scans one extra tile beyond the tight upper bound. Range-gating keeps results correct; counts are slightly inflated. ~negligible at 100+ bits where tile count is huge |

**Recommended action:** E1 stays unsupported. E2 keep TSV until a record actually breaks it. E3 ignore.

---

## F. What's NOT a CPU issue (so we stop tracking it)

To keep this file scoped: items that have been shipped clean and are not pending.

- ✅ Phase 4-CPU bitvec port (Armitage L2 filter) — `9be6dc7`, auto-disabled at low wheel via `0ae45ca`
- ✅ Fermat-2 prefilter — `5710df6`, default ON, certification preserved
- ✅ `--opt-prefetch` read-side hint — `246e228`, default ON
- ✅ `--opt-mont-fermat` — `7785ee4`, default OFF (lab/reference per principle)
- ✅ Random-chunk search + xoshiro + /dev/urandom seeding — `001d4b3`
- ✅ fsync + atexit + crash-safe persistence — `6f3da13`
- ✅ ctzll bit-scan iteration in bitvec — `99dd13e` (2.23× on KT9 17# i7-7700; 1.77× on AVX-512 EPYC)
- ✅ `--opt-line-cap` infrastructure — `3f973b9` (default 863; opt-in to 65535)

Cumulative single-thread perf on KT9_P0 17# / wheel=120:
- Phase 2.6 baseline (i7-7700): ~17 M cand/s
- After Phase 4b-#4 (i7-7700, ctzll): **492 M/s = 29× per thread**
- Same on AVX-512 EPYC: **522 M/s = 31×**

Reference target: CC v34's 1.25 G/s/thread (16-thread aggregate 20 G/s at chain target=19). We're now ~40% of that single-thread reference. Remaining gap is workload-shape-specific; on the production prove path (low survivor rate, k-tuplet vs chain) the gap may close further or even invert.

---

## G. Deferred / explicitly-out-of-scope (for the record)

- `mi[]` modular-inverse ladder (survey #4): structurally orthogonal to current sieve geometry. Becomes relevant only if we adopt a "sieve all members directly" geometry, which is closer to a rewrite than a patch.
- Multi-primorial-offset sieving (survey #6): our wheel construction already does this dynamically.
- Streaming wheel via CRT join (survey #7): only needed if a campaign demands `--primorial >= 9` (= 223M); currently capped at 8 (= 9.7M).
- Tuple-element early exit on partial-match k_min (survey #8): records require all-k.

---

**End of OPEN_CPU.md.** Update on each Phase X-fix commit; remove items as they ship.
