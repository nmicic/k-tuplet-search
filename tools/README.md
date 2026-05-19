# tools/ - generators, importers, and benchmarks

This directory contains support tooling for the k-tuplet search engine. Most
scripts are intended to be run from the repository root.

## Common Workflows

```bash
# Refresh the known-record corpus from pzktupel.de
python3 tools/fetch_records.py

# Rebuild generated record consumers
python3 tools/parse_records_json.py
python3 tools/records_to_gp.py

# Rebuild the C engine pattern catalog from tools/patterns/catalog/*.json
python3 tools/gen_pattern_header.py

# Run CPU benchmark regression gate
python3 tools/bench_record.py
```

## Tool Groups

| Path | Purpose |
|---|---|
| `fetch_records.py` | Fetches Luhn k-tuplet history pages into `known/records.json` |
| `parse_records_json.py` | Generates `tools/records_manifest.tsv` for `--validate-known` |
| `records_to_gp.py` | Generates `gp/records.gp` from `known/records.json` |
| `gen_pattern_header.py` | Generates `src/common/ktuplet_pattern.{h,c}` |
| `patterns/` | Pattern validation, enumeration, ranking, and catalog checks |
| `bench_record.py` | CPU regression benchmark harness |
| `bench_gpu_record.py` | Remote GPU benchmark harness |
| `bench_compare.py` | Query and compare CPU/GPU benchmark history |
| `kpi_*.py` | Time-to-record KPI calibration and promotion-gate tools |
| `dump_*.gp` | PARI/GP helper scripts for wheel/hash fixtures |

## Generated Data

| File | Producer | Consumer |
|---|---|---|
| `records_manifest.tsv` | `parse_records_json.py` | CPU/GPU `--validate-known` |
| `kpi_suite_v1.tsv` | KPI calibration workflow | `kpi_run.py` and benchmark reports |
| `kpi_fixtures/*.json` | KPI fixture builder | `test_kpi_promotion_gate.py` |

Benchmark and observability scripts generate JSON/JSONL under ignored `bench/`
paths. The public release does not ship historical benchmark histories.

## Pattern Tools

Pattern-specific tooling has its own guide:
[`tools/patterns/README.md`](patterns/README.md).

Norman Luhn's
[patterns and Hardy-Littlewood constants page](https://pzktupel.de/ktpatt_hl.php)
is the authoritative reference. Local pattern tools are convenience code for
machine-readable engine input.
