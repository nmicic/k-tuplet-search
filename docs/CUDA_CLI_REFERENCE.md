# CUDA CLI Reference

This is the long-form reference for `src/cuda/kt_filter_v8`, the production GPU
engine. The built-in `--help` output is intentionally compact; this file
explains the operational meaning of each public option.

Build first:

```bash
cd src/cuda
make kt_filter_v8
```

Then run commands from `src/cuda/` unless the example says otherwise.

## Discovery Commands

| Option | Meaning |
|---|---|
| `--help`, `-h` | Print compact CLI help and exit. |
| `--version`, `-V` | Print binary name, build SHA, and compile date. |
| `--list-patterns` | Print the compiled admissible-pattern catalog and exit. |
| `--test` | Run the embedded CUDA self-test suite. |
| `--smoke` | Run a short one-batch sanity check and exit when counters prove the kernel ran. |

### `--list-patterns`

Use this to discover legal `--pattern` names:

```bash
./kt_filter_v8 --list-patterns
```

Output columns are:

| Column | Meaning |
|---|---|
| pattern name | Name passed to `--pattern`, for example `KT19_P0`. |
| `k` | Tuple length. |
| diameter | Last offset in the pattern. |
| offsets | Additive shifts `{b_i}`; a hit proves all `n + b_i` prime. |

The list is sorted by pattern name and currently contains 97 CUDA-engine
patterns across `k=3..28`. The catalog is generated from
`tools/patterns/catalog/*.json`; use Norman Luhn's
<https://pzktupel.de/ktpatt_hl.php> page as the mathematical reference before
making external claims.

## Search Identity

| Option | Meaning |
|---|---|
| `--pattern NAME` | Select an exact compiled pattern, e.g. `KT19_P0`. Prefer this for real searches. |
| `--k N`, `--target N` | Select tuple length. If no pattern is given, the engine chooses the first matching pattern for that `k`; this is mainly a compatibility path. |
| `--bits N` | Search bases in the bit band `[2^(N-1), 2^N)`. Required for normal search. |
| `--primorial N` | Select the wheel by upper-prime index in the built-in prime table. Default is `11`, meaning `37#`. |
| `--wheel-expr X#[/Y...]` | Select a structural wheel expression. Examples: `47#`, `47#/31`, `47#/17/31`. Overrides `--primorial`. |
| `--threads N` | Parsed for CPU-CLI compatibility. The current GPU survivor-prove path is effectively serial; do not use this as a performance knob. |

Useful primorial values:

| Flag | Wheel | Typical use |
|---|---|---|
| `--primorial 11` | `37#` | Default; fast wheel build, useful for replay and lower-memory checks. |
| `--primorial 12` | `41#` | Intermediate wheel for experiments. |
| `--primorial 13` | `43#` | Recommended for `KT19_P0` and related `k=19/21` examples. |
| `--primorial 14` | `47#` | Recommended for `k=20`, `k=21_P0`, and exploratory `k>=22` examples. |

Values below the implementation floor or above `14` are clamped with a warning.
Larger wheels reduce candidate density but take more startup time and memory.

Wheel expressions use the built-in prime catalog up to `47`. `X#` means all
primes up to `X`; `/Y` drops a smaller prime from that wheel. For example,
`47#/17/31` builds the Stage-0 wheel from all primes up to `47`, except
`17` and `31`. Use `43#`, not `47#/47`, for the lower plain wheel.

Dropped primes are not lost as correctness checks: they are simply no longer
part of Stage-0. Dropped primes that also appear in the L2 sieve are still
caught there; with the current `47#` ceiling that means `41` or `43`. Dropped
primes `<=37` bypass the GPU sieve stages and are rejected only by Fermat-2
and/or host GMP/BPSW proving, which is correct but more expensive. This is
useful for non-plain-primorial campaign cells and future wheel-pool runners,
but small-prime drops can cause a throughput cliff.

Grammar and validation:

| Form | Meaning |
|---|---|
| `X#` | Plain primorial wheel through prime `X`; equivalent to the matching `--primorial` index. |
| `X#/Y` | Wheel through `X`, with prime `Y` omitted from Stage-0. |
| `X#/Y/Z/...` | Wheel through `X`, with multiple distinct primes omitted from Stage-0. |

`X` and every dropped prime must be present in the built-in wheel catalog
through `47`. Drops must be distinct and strictly smaller than `X`; drops
outside `X#` and dropping `X` itself are rejected. Expressions that would leave
an empty wheel or overflow the implementation modulus are rejected before search
starts. The parser normalizes drop order in logs and checkpoints; for example
`47#/31/17` is stored as `47#/17/31`, so resume works with either input order.

Only one wheel expression is active in a process. To cover a pool such as
`47#/31`, `47#/29`, and `47#/23`, run separate processes, typically pinned to
separate GPUs with `--gpu-device`.

Memory and startup time depend on the pattern-specific admissible residue count.
For a new expression, run a bounded smoke first:

```bash
./kt_filter_v8 --pattern KT19_P0 --bits 99 --wheel-expr '47#/31' \
    --smoke --max-batches 1 --gpu-device 0
```

The startup log prints the predicted peak allocation and final Stage-0 count:

```text
[wheel] KT19_P0 @ 47#/31 streaming: predicted peak alloc = 2220.539 MiB
Stage 0: 47#/31 wheel admissibility, n_primes=14, n_admissible=281014272
```

## Search Modes

| Option | Meaning |
|---|---|
| `--sequential` | Compatibility flag for the default sequential search mode. |
| `--random` | Alias for `--prefix-mode random`; randomizes chunk anchors for broad sampling. |
| `--prefix 0bXXX` | Restrict search to bases whose high bits match the binary prefix. |
| `--prefix-mode sequential` | Walk the selected range deterministically. |
| `--prefix-mode random` | Draw deterministic or random chunk anchors inside the selected range. |
| `--random-seed HEX`, `--seed HEX` | Set the random-mode seed explicitly. Use this for reproducible runs. |
| `--chunk-tiles N` | Number of tiles per random anchor interval/chunk. Default is `500` in random mode. |
| `--prefix-lanes N` | Split one prefix/range into `N` non-overlapping lanes for multi-GPU coverage. |
| `--prefix-lane-id ID` | Select this process's lane, from `0` to `N-1`. |
| `--exhaustive` | Sequentially walk the selected range and print a `PREFIX EXHAUSTED` banner when the lane completes. |

Use `--random` for open-ended sampling. Use `--exhaustive` only when the range
is intentionally small enough to finish or when you are running a controlled
prefix-lane coverage job.

## Run Limits and Resume

| Option | Meaning |
|---|---|
| `--max-time SEC` | Stop after this wall-clock budget. |
| `--max-batches N` | Stop after this many GPU batches. Useful for smoke tests. |
| `--checkpoint FILE` | Periodically write an atomic checkpoint with cursor, counters, identity, and seed. |
| `--resume [FILE]` | Resume from a checkpoint. If no file follows `--resume`, the engine uses `--checkpoint FILE`. |
| `--ckpt-interval N` | Checkpoint interval in seconds. Default is `60`; minimum is clamped to `1`. |

Checkpoint identity must match the current command's important search identity
fields: pattern, bits, prefix, lane count, lane id, normalized wheel expression,
and compatible mode/seed. Mismatches print a clear message and start fresh
rather than silently resuming the wrong search.

## Output and Reporting

| Option | Meaning |
|---|---|
| `--output FILE` | Append human-readable found-record lines to `FILE`. |
| `--log-file FILE` | Alias for `--output`. |
| `--quiet` | Reduce nonessential output. |
| `--full-quiet` | Suppress progress reporter output; useful for scripts. |
| `--report N` | Set progress report interval in seconds. |
| `--report-interval-sec N` | Same as `--report`; `0` disables periodic reports. |
| `--bench-jsonl FILE` | In `--validate-known`, emit one JSON row per replay record. |

Confirmed finds are always printed to stdout and persisted as
`novel_records_gpu<N>.jsonl` in the working directory, where `N` is the CUDA
device index. Novel-record JSONL includes `wheel_expr` and `primorial_n` so a
find can be attributed to the exact wheel campaign without cross-referencing
stdout. Files under `bench/` are generated runtime artifacts and are ignored by
Git.

## Known-Record Replay and KPI Modes

| Option | Meaning |
|---|---|
| `--validate-known [k]` | Replay known records from `known/records.json` / `tools/records_manifest.tsv`. With no `k`, defaults to the fast replay scope. |
| `--validate-known --k N` | Equivalent way to select the replay tuple length. |
| `--validate-known-require-coverage` | Fail if records are skipped because the selected wheel cannot cover them under current limits. Use this when validating a production primorial. |
| `--validate-per-record-budget SEC` | Override the default 60-second per-record replay budget. Also available through `KT_VALIDATE_PER_RECORD_BUDGET_SEC`. |
| `--kpi-target-base DEC` | KPI harness mode: stop when the specified base is emitted. Mutually exclusive with `--validate-known`. |

For correctness checks, prefer `--validate-known` first. For production-path
validation after engine changes, use `longevity_gpu/scripts/validate_records_external.sh`;
that script exercises both sequential and random prefix modes against known
records.

## GPU Controls

| Option | Meaning |
|---|---|
| `--gpu-device N` | Select CUDA device. Default is `0`. |
| `--gpu-batch-size N` | Requested threads per kernel launch. Default is `524288`; RTX 5090 runs generally use larger values such as `2097152`. |
| `--gpu-streams N` | Concurrent CUDA streams. Default is `3`; maximum is `8`. |
| `--gpu-arch sm_NN` | Informational label only. Actual architecture is chosen at compile time by `NVCC_ARCH`. |

## Stage Gates

These are mostly for debugging and A/B checks. Normal searches should leave all
stages enabled.

| Option | Meaning |
|---|---|
| `--no-stage-l2` | Disable the first post-wheel forbidden-residue stage. |
| `--no-stage-ext-l2` | Disable the extended L2 forbidden-residue stage. |
| `--no-stage-line` | Disable the line-sieve stage. |
| `--no-stage-fermat` | Disable the Fermat-2 prefilter before host proving. |

The normal cascade is:

```text
wheel -> L2 -> ext-L2 -> line-sieve -> Fermat-2 -> host GMP/BPSW prove
```

## Observability and Experimental Flags

These flags are default-off instrumentation or host-side validators. They are
useful for diagnostics but should not be treated as performance improvements.

| Option | Meaning |
|---|---|
| `--enable-f18-yield` | Write per `(line_prime, residue)` yield counters to `bench/yield_counters_<bin>_<pid>.jsonl`. |
| `--enable-f22-reservoir` | Write a 1000-slot post-Fermat survivor reservoir to `bench/reservoir_<bin>_<pid>.jsonl`. |
| `--enable-f23-texture` | Write a 128-slot survivor texture reservoir to `bench/texture_<bin>_<pid>.jsonl`. |
| `--enable-f24-cascade` | Enumerate and score k-2 sub-tuplets of the active pattern at startup; host-side diagnostic. |
| `--enable-f1-validator` | Validate baked KT19_P0/37# masks against runtime-generated masks, then exit. This is a correctness check, not a hot-kernel optimization. |
| `--enable-f2-rcu` | Enable dual-bank constant-memory mirror infrastructure for RCU-style filter-table updates; currently infrastructure/diagnostic scope. |

## Compatibility and Debug Flags

The following CPU flags are accepted so wrapper scripts can share arguments
between CPU and GPU binaries. They are echoed or stored but do not change the
GPU hot path:

```text
--no-line-sieve
--no-bitvec
--bitvec
--opt-fermat
--no-opt-fermat
--opt-mont-fermat
--no-opt-mont-fermat
--opt-prefetch
--no-opt-prefetch
--opt-bitscan
--no-opt-bitscan
--opt-line-cap N
--pin
--pin-base N
--sieve-only
```

Debug-only options:

| Option | Meaning |
|---|---|
| `--verbose-rotation` | Print high-volume random-anchor rotation diagnostics. |
| `--inject-cursor-offset HEX` | Misalignment-injection regression-test hook. Do not use for normal searches. |

Unknown options are rejected with a non-zero exit code.
