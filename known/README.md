# known/ — Prime k-Tuplet Record Corpus

This directory contains the canonical record corpus used by the search engine
and toolchain.

## Files

| File | Description |
|------|-------------|
| `records.json` | 227 verified prime k-tuplet records (k=16..21), sourced from pzktupel.de |

The generated validation manifest is written to
[`../tools/records_manifest.tsv`](../tools/records_manifest.tsv), not this
directory.

## Data source and attribution

All records in `records.json` are sourced from Norman Luhn's k-tuplet history pages:

- https://pzktupel.de/KTHIST/kt016.php — prime 16-tuplets
- https://pzktupel.de/KTHIST/kt017.php — prime 17-tuplets
- https://pzktupel.de/KTHIST/kt018.php — prime 18-tuplets
- https://pzktupel.de/KTHIST/kt019.php — prime 19-tuplets
- https://pzktupel.de/KTHIST/kt020.php — prime 20-tuplets
- https://pzktupel.de/KTHIST/kt021.php — prime 21-tuplets

**All credit for maintaining these records belongs to Norman Luhn**
(pzktupel [at] pzktupel [dot] de) and the original discoverers listed in each
record entry. The records are reproduced here solely to enable offline
validation and search-engine operation.

## Regenerating records.json

```bash
python3 tools/fetch_records.py
```

This fetches the current live pages from pzktupel.de and rewrites
`known/records.json`. Run this when the live pages are updated with new
records before starting a new search campaign.

## Downstream consumers

`records.json` is read by:

| Consumer | Purpose |
|----------|---------|
| `src/cuda/kt_records.c` | GPU engine `--validate-known` and novel-hit cross-check |
| `src/cpu/kt_gmp_v1.c` | CPU engine `--validate-known` |
| `tools/records_to_gp.py` | generates `gp/records.gp` for PARI/GP verification |
| `tools/gen_pattern_header.py` | cross-checks pattern catalog against known records |
| `tools/parse_records_json.py` | generates `tools/records_manifest.tsv` |
| `tools/bench_gpu_record.py` | GPU benchmark harness |
| `tests/select_records_by_bit_bucket.py` | test record selection |

After updating `records.json`, regenerate the manifest:

```bash
python3 tools/parse_records_json.py
```
