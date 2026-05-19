# gp/ - PARI/GP toolkit

This directory contains the PARI/GP support library used for interactive
k-tuplet analysis, record verification, and search-space planning.

Install PARI/GP on Ubuntu/Debian with:

```bash
sudo apt install -y pari-gp
```

## Files

| File | Purpose |
|---|---|
| `kt_lib_v1.gp` | Main GP library; runs self-tests on load |
| `records.gp` | Generated record table from `known/records.json` |
| `HOWTO_kt_lib_v1.md` | Usage guide and function reference |

## Quick Start

```bash
gp -q
\r gp/kt_lib_v1.gp
\r gp/records.gp
kt_check_record_table(KT_RECORDS, 5)
```

Regenerate `records.gp` from the JSON corpus with:

```bash
python3 tools/records_to_gp.py
```

See [`HOWTO_kt_lib_v1.md`](HOWTO_kt_lib_v1.md) for details.
