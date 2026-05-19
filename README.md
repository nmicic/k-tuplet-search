# k-Tuplet Prime Search

A CUDA+GMP search engine and tooling suite for prime k-tuplets. The project is
code-first: it can replay known records, enumerate and validate admissible
patterns, and run long GPU campaigns, but this repository does **not** claim a
new k-tuplet record.

Sibling project to
[cunningham-chain-search](https://github.com/nmicic/cunningham-chain-search).
The filter architecture is a port of that search style: the Cunningham-chain
formula `2^i*n + (2^i - 1)` is replaced by additive shifts `n + b_i`.

## Architecture

The production search pipeline is:

- **Pattern catalog**: admissible offset sets in `src/common/ktuplet_pattern.c`
- **Wheel expressions**: CRT-surviving base positions for plain primorial
  wheels up to `47#` or structural quotient wheels such as `47#/31/17`
- **GPU filter**: `src/cuda/kt_filter_v8.cu` rejects candidates with a staged
  forbidden-residue cascade (`L2 -> ext-L2 -> line-sieve -> Fermat-2`)
- **Host prover**: GMP/BPSW verification of every member of surviving tuplets
- **Operational support**: `--validate-known`, random/sequential prefix modes,
  prefix lanes, checkpoint/resume, JSONL hit persistence, and benchmark tooling

## Pattern Catalog

The CUDA engine catalog contains 97 admissible narrow-diameter patterns across
`k=3..28`. It is generated from `tools/patterns/catalog/*.json` by
`tools/gen_pattern_header.py`, including reflected patterns as separate search
directions where applicable.

Norman Luhn's pattern and Hardy-Littlewood tables are the authoritative
mathematical reference. The local enumeration tools are convenience code for
engine input; cross-check them before using the output in external claims.

| k | Patterns | Diameter H(k) |
|---|----------|---------------|
| 3 | 2 | 6 |
| 4 | 1 | 8 |
| 5 | 2 | 12 |
| 6 | 1 | 16 |
| 7 | 2 | 20 |
| 8 | 3 | 26 |
| 9 | 4 | 30 |
| 10 | 2 | 32 |
| 11 | 2 | 36 |
| 12 | 2 | 42 |
| 13 | 6 | 48 |
| 14 | 2 | 50 |
| 15 | 4 | 56 |
| 16 | 2 | 60 |
| 17 | 4 | 66 |
| 18 | 2 | 70 |
| 19 | 4 | 76 |
| 20 | 2 | 80 |
| 21 | 2 | 84 |
| 22 | 4 | 90 |
| 23 | 2 | 94 |
| 24 | 4 | 100 |
| 25 | 18 | 110 |
| 26 | 2 | 114 |
| 27 | 8 | 120 |
| 28 | 10 | 126 |

The GP/PARI toolkit currently carries a smaller 25-entry planning catalog
(`k=5,7,9,16..24`) and a generated record table. Use the C catalog for the
full CUDA engine pattern list.

## Search Status

The known-record replay corpus covers `k=16..21` and is used as the main
correctness gate. Practical record-search examples in this repo focus on
`k=19`, `k=20`, and `k=21`; `k>=22` is exploratory frontier territory. Luhn's
records page states that large known examples are maintained through `k=21`,
with no known `k>21` examples except near the beginning of the prime sequence.

The included longevity infrastructure was used for stability testing and random
sampling. Treat those runs as stress tests, not as exhaustive coverage of the
100-bit search ranges.

## Quick Start

### Build the GPU Engine

Ubuntu/Debian dependencies:

```bash
sudo apt update
sudo apt install -y build-essential libgmp-dev
sudo apt install -y pari-gp          # optional: only needed for gp/ tools
```

```bash
cd src/cuda
make kt_filter_v8
```

The Makefile defaults to `/usr/local/cuda-13.2/bin/nvcc` and `sm_120`
(RTX 5090 / Blackwell). Override as needed:

```bash
make kt_filter_v8 NVCC=/path/to/nvcc NVCC_ARCH=sm_89
```

For Blackwell/`sm_120`, use a CUDA toolkit that knows that architecture
(validated with CUDA 13.2). If `nvcc` reports that `sm_120` is not defined,
install a newer CUDA toolkit or build for an older GPU with `NVCC_ARCH=sm_89`,
`sm_86`, etc.

For Ada/`sm_89` targets such as RTX 4090, use CUDA 11.8 or newer.

### Run Tests and Inspect Patterns

```bash
./kt_filter_v8 --test
./kt_filter_v8 --list-patterns
```

`--list-patterns` prints every compiled pattern name accepted by `--pattern`,
with tuple length, diameter, and offset list. See
[`docs/CUDA_CLI_REFERENCE.md`](docs/CUDA_CLI_REFERENCE.md) for all CLI options.

Release validation snapshot, 2026-05-18: `kt_filter_v8` built with CUDA 13.2
for `sm_120` on an RTX 5090 host, and `./kt_filter_v8 --test` reported
`All 52 tests passed`.

### Try a Wheel-Expression Search

Plain `--primorial N` searches use all primes through the selected wheel. For
campaign cells that intentionally vary the Stage-0 wheel shape, `--wheel-expr`
accepts quotient-style expressions:

```bash
./kt_filter_v8 --pattern KT19_P0 --bits 99 --wheel-expr '47#/31' --random --max-time 1800
./kt_filter_v8 --pattern KT20_P1 --bits 100 --wheel-expr '47#/29' --random --max-time 1800
```

`47#/31` means "use all wheel primes through 47, except 31". Dropped primes
must be smaller than the wheel ceiling; use `43#`, not `47#/47`, for the lower
plain wheel. One expression is active per process; run multiple processes or
GPUs to sample multiple wheel shapes. See [`HOWTO.md`](HOWTO.md) and
[`docs/CUDA_CLI_REFERENCE.md`](docs/CUDA_CLI_REFERENCE.md) for the grammar and
operational tradeoffs.

### Validate Known Records

```bash
./kt_filter_v8 --validate-known 19 --primorial 13
./kt_filter_v8 --validate-known 20 --primorial 14 --validate-per-record-budget 90
```

Exit code 0 and `validate-known: gate=PASS` mean the selected replay gate
reproduced at least one known record per configured tier.

## GP/PARI Library

```bash
gp -q
\r gp/kt_lib_v1.gp
```

39 self-tests run automatically. Then optionally load the generated record
table:

```gp
\r gp/records.gp
kt_check_record_table(KT_RECORDS, 5)    \\ verify 5 records per k
```

See [`gp/HOWTO_kt_lib_v1.md`](gp/HOWTO_kt_lib_v1.md) for full usage.

## Record Corpus

[`known/records.json`](known/records.json) contains 227 records across
`k=16..21`, sourced from Norman Luhn's
[k-tuplet history pages](https://pzktupel.de/KTHIST/) at
[pzktupel.de](https://pzktupel.de). Credit for maintaining those records
belongs to Norman Luhn and the original discoverers listed in the corpus.

Regeneration commands:

```bash
python3 tools/fetch_records.py          # refresh known/records.json from pzktupel.de
python3 tools/parse_records_json.py     # regenerate tools/records_manifest.tsv
python3 tools/records_to_gp.py          # regenerate gp/records.gp
python3 tools/gen_pattern_header.py     # regenerate src/common/ktuplet_pattern.{h,c}
```

## Project Layout

| Directory | Contents |
|-----------|----------|
| `src/cuda/` | Production GPU engine (`kt_filter_v8.cu`) and oracle engine (`kt_filter_v5.cu`) |
| `src/common/` | Shared pattern catalog, verification helpers, and JSON parser |
| `src/cpu/` | CPU search/prover (`kt_gmp_v1.c`) using GMP |
| `gp/` | GP/PARI toolkit and generated record table |
| `tools/` | Record importers, pattern generators, and benchmark utilities |
| `docs/` | Design notes and pattern-tool documentation |
| `known/` | Known-record corpus (`records.json`) |
| `longevity_gpu/` | Remote GPU longevity-run scripts |
| `visualizations/` | Interactive k-tuplet analyzer ([GitHub Pages](https://nmicic.github.io/k-tuplet-search/visualizations/k-tuplet-analyzer/index.html)) |

## Quick Links

| What | Where |
|------|-------|
| GPU engine (production) | [`src/cuda/kt_filter_v8.cu`](src/cuda/kt_filter_v8.cu) |
| GPU oracle | [`src/cuda/kt_filter_v5.cu`](src/cuda/kt_filter_v5.cu) |
| GPU engine guide | [`src/cuda/README.md`](src/cuda/README.md) |
| CPU engine guide | [`src/cpu/README.md`](src/cpu/README.md) |
| Pattern catalog (C) | [`src/common/ktuplet_pattern.c`](src/common/ktuplet_pattern.c) |
| Pattern header | [`src/common/ktuplet_pattern.h`](src/common/ktuplet_pattern.h) |
| Pattern tools | [`docs/PATTERN_TOOLS.md`](docs/PATTERN_TOOLS.md) |
| CUDA CLI reference | [`docs/CUDA_CLI_REFERENCE.md`](docs/CUDA_CLI_REFERENCE.md) |
| GP/PARI library | [`gp/kt_lib_v1.gp`](gp/kt_lib_v1.gp) |
| GP library guide | [`gp/HOWTO_kt_lib_v1.md`](gp/HOWTO_kt_lib_v1.md) |
| Record corpus | [`known/records.json`](known/records.json) |
| Record manifest | [`tools/records_manifest.tsv`](tools/records_manifest.tsv) |
| Interactive analyzer | [GitHub Pages](https://nmicic.github.io/k-tuplet-search/visualizations/k-tuplet-analyzer/index.html) / [`visualizations/k-tuplet-analyzer/index.html`](visualizations/k-tuplet-analyzer/index.html) |
| GPU HOWTO | [`HOWTO.md`](HOWTO.md) |
| Testing and benchmarks | [`TESTING.md`](TESTING.md) |

## AI Assistance

This project used AI-assisted development tools during implementation,
testing, and documentation review. All code and release decisions remain the
responsibility of the author.

## External Links

- [k-tuplet records (pzktupel.de)](https://www.pzktupel.de/ktuplets.php)
- [Patterns and Hardy-Littlewood constants](https://pzktupel.de/ktpatt_hl.php)
- [Cunningham chain search (sibling project)](https://github.com/nmicic/cunningham-chain-search)

## Author

Nenad Mićić <nenad@micic.be>, Belgium

## License

Apache-2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).
